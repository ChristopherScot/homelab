package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// The probe path in config.yaml. Nothing generates this endpoint, so this
// keeps a hand-edited server.go from silently removing what the
// readinessProbe depends on.
func TestHealthzIsServedForTheProbe(t *testing.T) {
	f := newFixture(t)
	w := f.serve(httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Errorf("/healthz = %d %q, want 200 ok", w.Code, w.Body.String())
	}
}

func TestOnlyPostIsAWebhook(t *testing.T) {
	f := newFixture(t)
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		w := f.serve(httptest.NewRequest(method, "/", nil))
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s / = %d, want 405", method, w.Code)
		}
	}
}

func TestMetricsAreLabelledByRoute(t *testing.T) {
	f := newFixture(t)
	f.signed("/", move("t1", "backlog"))
	f.post("/secret-token-value/deadbeef", "")

	body := f.serve(httptest.NewRequest(http.MethodGet, "/metrics", nil)).Body.String()
	if !strings.Contains(body, `http_requests_total{method="POST",route="webhook",status="202"}`) {
		t.Errorf("no webhook counter:\n%s", body)
	}
	// Without a generated router rejecting unrouted requests, this is the
	// test holding the line: every metric label is a literal written in
	// server.go.
	if strings.Contains(body, "deadbeef") {
		t.Error("a request path reached a metric label")
	}
	if !strings.Contains(body, "go_goroutines") {
		t.Error("no runtime metrics in /metrics")
	}
}

// Both credentials are refused at startup rather than at the first
// delivery; the message names the variable, which is what a crash loop
// shows and a person then greps for.
func TestStartupRefusesToRunWithoutItsCredentials(t *testing.T) {
	for _, missing := range []string{"KANEO_WEBHOOK_SECRET", "KANEO_API_KEY"} {
		t.Run(missing, func(t *testing.T) {
			t.Setenv("KANEO_WEBHOOK_SECRET", "s")
			t.Setenv("KANEO_API_KEY", "k")
			t.Setenv(missing, "")
			_, err := fromEnv()
			if err == nil || !strings.Contains(err.Error(), missing) {
				t.Errorf("fromEnv() without %s = %v, want a refusal naming it", missing, err)
			}
		})
	}
}

// The ApplicationSet reads <name>/argocd.json at the repo root; render
// writes the same entry under deploy/. CI checks only the rendered one,
// so this is what keeps the registration from going stale.
func TestRegistrationMatchesTheRenderedEntry(t *testing.T) {
	rendered, err := os.ReadFile("deploy/kaneo-dispatcher/argocd.json")
	if err != nil {
		t.Fatal(err)
	}
	registered, err := os.ReadFile("../../kaneo-dispatcher/argocd.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(rendered) != string(registered) {
		t.Errorf("kaneo-dispatcher/argocd.json differs from the rendered deploy/kaneo-dispatcher/argocd.json:\n%s\nvs\n%s", registered, rendered)
	}
}
