package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	utilexec "k8s.io/client-go/util/exec"
)

// newPodExec execs through the API server directly, with the pod's own
// ServiceAccount. The image is distroless and ships no kubectl, and the
// only thing a kubectl would have added is a process to parse the exit
// code of.
func newPodExec(ns string) (execer, error) {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, err
	}
	return func(ctx context.Context, pod string, argv []string) (int, error) {
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
		var exit utilexec.CodeExitError
		if errors.As(err, &exit) {
			// The command ran and exited non-zero. That is an answer, not
			// a failure to ask.
			return exit.Code, nil
		}
		if err != nil {
			return 0, err
		}
		return 0, nil
	}, nil
}
