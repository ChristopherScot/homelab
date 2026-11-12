package main

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv1 "k8s.io/api/autoscaling/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

// settled is what the wake polls for. Each case is one way kubectl
// rollout status would still be waiting, and the last is done.
func TestSettledMatchesRolloutStatus(t *testing.T) {
	ready := func() *appsv1.StatefulSet {
		s := &appsv1.StatefulSet{}
		s.Generation = 4
		s.Status.ObservedGeneration = 4
		s.Status.ReadyReplicas = 3
		s.Status.CurrentRevision = "claude-session-7"
		s.Status.UpdateRevision = "claude-session-7"
		return s
	}
	for _, tc := range []struct {
		name  string
		tweak func(*appsv1.StatefulSet)
		want  bool
	}{
		{"Settled", func(*appsv1.StatefulSet) {}, true},
		{"MoreThanWanted", func(s *appsv1.StatefulSet) { s.Status.ReadyReplicas = 4 }, true},
		{"NeverObserved", func(s *appsv1.StatefulSet) { s.Status.ObservedGeneration = 0 }, false},
		{"ScaleNotYetObserved", func(s *appsv1.StatefulSet) { s.Generation = 5 }, false},
		{"PodsStillStarting", func(s *appsv1.StatefulSet) { s.Status.ReadyReplicas = 1 }, false},
		{"MidRollout", func(s *appsv1.StatefulSet) { s.Status.UpdateRevision = "claude-session-8" }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := ready()
			tc.tweak(s)
			if got := settled(s, 3); got != tc.want {
				t.Errorf("settled(%s) = %v, want %v", tc.name, got, tc.want)
			}
		})
	}
}

// The sleep cron leaves a pod younger than its age guard alone, because
// a fresh set may belong to a wake that has not taken its lock yet. That
// guard is derived from wakeTimeout, in a different file in a different
// language; this is the one place the derivation is checked.
func TestSleepCronOutwaitsTheWake(t *testing.T) {
	src, err := os.ReadFile("../../claude-pods/session-sleep-cron.yaml")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`\[ "\$age" -lt (\d+) \]`).FindSubmatch(src)
	if m == nil {
		t.Fatal(`session-sleep-cron.yaml no longer guards on [ "$age" -lt <seconds> ]; this test must change with it`)
	}
	guard, _ := strconv.Atoi(string(m[1]))
	// Strictly more: the wait plus the exec that follows it.
	if float64(guard) <= wakeTimeout.Seconds() {
		t.Errorf("the sleep cron's age guard is %ds, but a wake may take %s before its exec; a mid-wake set would be scaled away", guard, wakeTimeout)
	}
}

// The Role scopes the scale grant by name. A rename of the set here
// that missed rbac.yaml would fail at runtime as a 403, hours later via
// the sweep, so the name in the Role is held to the one in the code.
func TestRoleNamesTheSetTheWakeScales(t *testing.T) {
	src, err := os.ReadFile("rbac.yaml")
	if err != nil {
		t.Fatal(err)
	}
	names := regexp.MustCompile(`resourceNames: \["([^"]*)"\]`).FindAllSubmatch(src, -1)
	if len(names) == 0 {
		t.Fatal("rbac.yaml scopes nothing by name; the scale grant must be scoped to " + sessionSet)
	}
	for _, n := range names {
		if got := string(n[1]); got != sessionSet {
			t.Errorf("rbac.yaml scopes a grant to %q, want %q", got, sessionSet)
		}
	}
}

// fakeSet is a claude-session StatefulSet in a fake clientset, with the
// scale subresource wired up: the fake's object tracker knows nothing
// of subresources, so GetScale and UpdateScale are answered here from
// the tracked object. An UpdateScale also plays the controller, moving
// the spec and status at once so the wake's first poll sees it settled.
type fakeSet struct {
	cs        *fake.Clientset
	scaledTo  []int32
	conflicts int // UpdateScale answers 409 this many times first
}

func newFakeSet(t *testing.T, replicas, ready int32) *fakeSet {
	t.Helper()
	s := &appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: sessionSet, Namespace: "ns"}}
	s.Spec.Replicas = &replicas
	s.Generation = 1
	s.Status.ObservedGeneration = 1
	s.Status.ReadyReplicas = ready
	f := &fakeSet{cs: fake.NewSimpleClientset(s)}
	gvr := appsv1.SchemeGroupVersion.WithResource("statefulsets")
	current := func() *appsv1.StatefulSet {
		obj, err := f.cs.Tracker().Get(gvr, "ns", sessionSet)
		if err != nil {
			t.Fatal(err)
		}
		return obj.(*appsv1.StatefulSet)
	}
	f.cs.PrependReactor("get", "statefulsets", func(a k8stesting.Action) (bool, runtime.Object, error) {
		if a.GetSubresource() != "scale" {
			return false, nil, nil
		}
		return true, &autoscalingv1.Scale{Spec: autoscalingv1.ScaleSpec{Replicas: *current().Spec.Replicas}}, nil
	})
	f.cs.PrependReactor("update", "statefulsets", func(a k8stesting.Action) (bool, runtime.Object, error) {
		if a.GetSubresource() != "scale" {
			return false, nil, nil
		}
		if f.conflicts > 0 {
			f.conflicts--
			return true, nil, apierrors.NewConflict(gvr.GroupResource(), sessionSet, errors.New("the object has been modified"))
		}
		scale := a.(k8stesting.UpdateAction).GetObject().(*autoscalingv1.Scale)
		f.scaledTo = append(f.scaledTo, scale.Spec.Replicas)
		s := current().DeepCopy()
		s.Spec.Replicas = &scale.Spec.Replicas
		s.Generation++
		s.Status.ObservedGeneration = s.Generation
		s.Status.ReadyReplicas = scale.Spec.Replicas
		if err := f.cs.Tracker().Update(gvr, s, "ns"); err != nil {
			t.Fatal(err)
		}
		return true, scale, nil
	})
	return f
}

func (f *fakeSet) wake(t *testing.T, timeout time.Duration) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), timeout)
	defer cancel()
	return wakeSet(ctx, f.cs.AppsV1().StatefulSets("ns"), 3)
}

func TestWakeScalesASleepingSetAndWaitsForIt(t *testing.T) {
	f := newFakeSet(t, 0, 0)
	if err := f.wake(t, time.Minute); err != nil {
		t.Fatalf("wake: %v", err)
	}
	if len(f.scaledTo) != 1 || f.scaledTo[0] != 3 {
		t.Errorf("scaled to %v, want one scale to 3", f.scaledTo)
	}
}

func TestWakeLeavesAnAwakeSetAlone(t *testing.T) {
	f := newFakeSet(t, 3, 3)
	if err := f.wake(t, time.Minute); err != nil {
		t.Fatalf("wake: %v", err)
	}
	if len(f.scaledTo) != 0 {
		t.Errorf("an awake set was scaled: %v", f.scaledTo)
	}
}

// Two deliveries in one poll interval both read 0 and both write 3. The
// loser's write is a 409; it must re-read and go on, not drop its card.
func TestWakeRetriesAScaleConflict(t *testing.T) {
	f := newFakeSet(t, 0, 0)
	f.conflicts = 1
	if err := f.wake(t, time.Minute); err != nil {
		t.Fatalf("wake after one conflict: %v", err)
	}
	if len(f.scaledTo) != 1 {
		t.Errorf("scaled %v, want exactly one successful scale", f.scaledTo)
	}
}

// A set that scales but never becomes ready - an image that will not
// pull, a node gone - is reported with the count, inside the deadline.
func TestWakeReportsASetThatNeverComesUp(t *testing.T) {
	f := newFakeSet(t, 3, 1) // scaled already, so no reactor marks it ready
	err := f.wake(t, 50*time.Millisecond)
	if err == nil {
		t.Fatal("a set with 1 of 3 ready was reported awake")
	}
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "(1 of 3 ready)") {
		t.Errorf("err = %v, want a deadline error naming 1 of 3 ready", err)
	}
}
