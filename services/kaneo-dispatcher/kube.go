package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	typedappsv1 "k8s.io/client-go/kubernetes/typed/apps/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	utilexec "k8s.io/client-go/util/exec"
	"k8s.io/client-go/util/retry"
)

// sessionSet is the StatefulSet the session pods belong to. Not an env
// knob like DISPATCH_NS: routes names pods by ordinal under this name,
// so a different name here would wake one workload and exec into
// another. One fact, one place.
const sessionSet = "claude-session"

// newPodClient talks to the API server directly, with the pod's own
// ServiceAccount: it execs into a session pod, and scales the set those
// pods belong to. The image is distroless and ships no kubectl, and the
// only thing a kubectl would have added is a process to parse the exit
// code of. Exec needs nothing but `create` on pods/exec: kubectl reads
// the pod first to pick a container, this names the pod and lets the API
// server pick. The wake needs `get` on the StatefulSet and `get`+`update`
// on its scale subresource; rbac.yaml grants exactly that, by name.
func newPodClient(ns string) (execer, waker, error) {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, nil, fmt.Errorf("in-cluster config: %w", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, nil, err
	}

	exec := func(ctx context.Context, pod string, argv []string) (int, error) {
		req := cs.CoreV1().RESTClient().Post().
			Resource("pods").Namespace(ns).Name(pod).SubResource("exec").
			VersionedParams(&corev1.PodExecOptions{
				Command: argv,
				Stdout:  true,
				Stderr:  true,
			}, scheme.ParameterCodec)
		ex, err := remotecommand.NewSPDYExecutor(cfg, http.MethodPost, req.URL())
		if err != nil {
			return 0, err
		}
		// Output is discarded, as kubectl's was: what matters is the exit
		// code, and a launched run redirects its own output anyway.
		err = ex.StreamWithContext(ctx, remotecommand.StreamOptions{Stdout: io.Discard, Stderr: io.Discard})
		// The interface rather than the concrete CodeExitError, so this
		// keeps matching whether the library returns it by value or by
		// pointer. A non-zero exit is an answer, not a failure to ask.
		var exit utilexec.ExitError
		if errors.As(err, &exit) {
			return exit.ExitStatus(), nil
		}
		return 0, err
	}

	wake := func(ctx context.Context) error {
		return wakeSet(ctx, cs.AppsV1().StatefulSets(ns), int32(wakeReplicas()))
	}
	return exec, wake, nil
}

const (
	// wakeTimeout bounds a wake. A cold start legitimately takes minutes
	// - three pods pulling a 1.4 GB image - but one that cannot finish
	// must become a logged failure for the card, not a goroutine held
	// forever.
	wakeTimeout = 10 * time.Minute
	// wakePoll is how often a wake re-reads the set while waiting.
	wakePoll = 5 * time.Second
)

// wakeSet is `kubectl scale` followed by `kubectl rollout status`, which
// is what the Node dispatcher ran: scale the set up to want and return
// once it has settled there, or with the reason it did not within
// wakeTimeout.
//
// The scale is a read followed by a conditional write, retried on a
// conflict: two deliveries in one poll interval both read 0 and both
// write 3, and without the retry the loser would report "cannot scale"
// and drop its card for hours over an ordinary double move. A set that
// is already big enough is not written at all, so an awake set costs one
// read per dispatch.
func wakeSet(ctx context.Context, sets typedappsv1.StatefulSetInterface, want int32) error {
	ctx, cancel := context.WithTimeout(ctx, wakeTimeout)
	defer cancel()
	start := time.Now()
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		scale, err := sets.GetScale(ctx, sessionSet, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("cannot read the scale of %s: %w", sessionSet, err)
		}
		if scale.Spec.Replicas >= want {
			return nil
		}
		scale.Spec.Replicas = want
		_, err = sets.UpdateScale(ctx, sessionSet, scale, metav1.UpdateOptions{})
		return err
	})
	if err != nil {
		return fmt.Errorf("cannot scale %s to %d: %w", sessionSet, want, err)
	}
	// The count is what a morning needs: an RBAC denial failed above with
	// its own message, so running out of time here is a pod that did not
	// start - an image pull against an unreachable ghcr, a node gone.
	// Whether the clock runs out inside the read or between two reads is
	// a timer race, so both end with this one line.
	var ready int32
	gaveUp := func() error {
		return fmt.Errorf("%s not ready after %s of waking (%d of %d ready): %w",
			sessionSet, time.Since(start).Round(time.Second), ready, want, ctx.Err())
	}
	tick := time.NewTicker(wakePoll)
	defer tick.Stop()
	for {
		s, err := sets.Get(ctx, sessionSet, metav1.GetOptions{})
		if err != nil {
			if ctx.Err() != nil {
				return gaveUp()
			}
			return fmt.Errorf("cannot read %s: %w", sessionSet, err)
		}
		if settled(s, want) {
			return nil
		}
		ready = s.Status.ReadyReplicas
		select {
		case <-ctx.Done():
			return gaveUp()
		case <-tick.C:
		}
	}
}

// settled is kubectl rollout status's test for a StatefulSet, minus the
// partition case this set does not use: the controller has seen the
// current spec, every wanted replica is ready, and they are all on the
// current revision. The last clause means a wake that lands mid-rollout
// of a new image waits for the rollout, as kubectl would.
func settled(s *appsv1.StatefulSet, want int32) bool {
	st := s.Status
	return st.ObservedGeneration != 0 &&
		st.ObservedGeneration >= s.Generation &&
		st.ReadyReplicas >= want &&
		st.UpdateRevision == st.CurrentRevision
}
