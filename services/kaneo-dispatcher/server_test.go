package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func httpGet(path string) *http.Request { return httptest.NewRequest(http.MethodGet, path, nil) }

func serve(f *fixture, req *http.Request) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	f.d.mux().ServeHTTP(w, req)
	return w
}

// The probe path in config.yaml. Nothing generates this endpoint, so this
// keeps a hand-edited server.go from silently removing what the
// readinessProbe depends on.
func TestHealthzIsServedForTheProbe(t *testing.T) {
	f := newFixture(t)
	w := serve(f, httpGet("/healthz"))
	if w.Code != http.StatusOK || w.Body.String() != "ok" {
		t.Errorf("/healthz = %d %q, want 200 ok", w.Code, w.Body.String())
	}
}

func TestOnlyPostIsAWebhook(t *testing.T) {
	f := newFixture(t)
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		w := serve(f, httptest.NewRequest(method, "/", nil))
		if w.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s / = %d, want 405", method, w.Code)
		}
	}
}

func TestMetricsAreLabelledByRoute(t *testing.T) {
	f := newFixture(t)
	f.signed("/", move("t1", "backlog"))
	f.post("/secret-token-value/deadbeef", "")

	body := serve(f, httpGet("/metrics")).Body.String()
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

func TestStartupRefusesToRunWithoutAWebhookSecret(t *testing.T) {
	t.Setenv("KANEO_WEBHOOK_SECRET", "")
	if _, err := fromEnv(); err == nil || !strings.Contains(err.Error(), "KANEO_WEBHOOK_SECRET") {
		t.Errorf("fromEnv() = %v, want a refusal naming the secret", err)
	}
}
