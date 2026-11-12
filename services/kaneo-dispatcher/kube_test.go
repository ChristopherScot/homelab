package main

import (
	"testing"

	appsv1 "k8s.io/api/apps/v1"
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
