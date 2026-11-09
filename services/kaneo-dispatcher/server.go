package main

// The HTTP surface. Specless, scaffolded by `homelabctl init --no-spec`:
// there is no openapi.yml, no generated api/ and no clients. The routes
// are hand-written below; what each one does lives in dispatch.go and
// reconcile.go.
//
// Two things here are load-bearing:
//
//   - /healthz exists because nothing else creates it; without it the
//     readinessProbe hits a pod that never becomes ready.
//   - metrics are labelled by ROUTE PATTERN, never by request path.
//     Without a generated router rejecting unrouted paths, a raw URL as
//     a label is unbounded cardinality and writes caller-controlled
//     strings into the monitoring stack.

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Requests by route, method and status.",
	}, []string{"route", "method", "status"})

	latency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "Request latency by route and method.",
		Buckets: prometheus.DefBuckets,
	}, []string{"route", "method"})
)

// statusRecorder captures the status code, which http.ResponseWriter
// does not expose after the fact.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// observe takes the route name as an argument rather than reading the
// request path, so a label can only ever be a string written in this file.
func observe(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, req)

		elapsed := time.Since(start)
		requests.WithLabelValues(route, req.Method, strconv.Itoa(rec.status)).Inc()
		latency.WithLabelValues(route, req.Method).Observe(elapsed.Seconds())

		slog.Info("request",
			"method", req.Method,
			"route", route,
			"status", rec.status,
			// Float milliseconds: elapsed.Milliseconds() truncates and a
			// handler answering from memory logs duration_ms=0.
			"duration_ms", float64(elapsed.Nanoseconds())/1e6)
	}
}

func handler() (http.Handler, error) {
	d, err := fromEnv()
	if err != nil {
		return nil, err
	}
	return d.mux(), nil
}

// mux is the route table. Separate from handler so a test can build a
// dispatcher with fakes and serve the same routes.
func (d *dispatcher) mux() http.Handler {
	mux := http.NewServeMux()

	// The manifest's readiness and liveness probes hit /healthz.
	// Deliberately NOT wrapped in observe: the kubelet probes it every
	// few seconds, which would bury real traffic.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	})

	// The deployment's scrape annotation points here.
	mux.Handle("GET /metrics", promhttp.Handler())

	// Reconcile is a POST so it cannot be triggered by a stray GET, and it
	// is behind the same HMAC as the webhook - it starts real work.
	//
	// Both spellings are registered because a bare "/reconcile/" pattern
	// would answer the exact path with a 301 to the slash form, and a
	// redirect drops a POST body - and its signature with it.
	refuse := func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "POST with a signature", http.StatusMethodNotAllowed)
	}
	mux.HandleFunc("GET /reconcile", refuse)
	mux.HandleFunc("GET /reconcile/", refuse)
	mux.HandleFunc("POST /reconcile", observe("reconcile", d.reconcileHandler))
	mux.HandleFunc("POST /reconcile/", observe("reconcile", d.reconcileHandler))

	// Every other POST is a delivery, whatever its path: Kaneo is
	// configured with the Service's root, and this is also what makes any
	// non-POST a 405 rather than a webhook.
	mux.HandleFunc("POST /", observe("webhook", d.webhook))
	return mux
}

// reconcileHandler is the sweep, not a webhook. Same signature check,
// since it starts the same work. `?dry` reports what the sweep would do
// without doing it.
func (d *dispatcher) reconcileHandler(w http.ResponseWriter, r *http.Request) {
	if _, ok := d.verifiedBody(w, r); !ok {
		return
	}
	dryRun := r.URL.Query().Has("dry")
	w.WriteHeader(http.StatusAccepted)
	// Detached from the request's cancellation, which fires when this
	// handler returns - before the sweep has made its first call.
	ctx := context.WithoutCancel(r.Context())
	d.inflight.Add(1)
	go func() {
		defer d.inflight.Done()
		d.runSweep(ctx, dryRun)
	}()
}

// maxBody bounds a delivery. A task.status_changed payload is a few KB;
// 1 MiB is generous.
const maxBody = 1 << 20

// verifiedBody reads a bounded body and verifies Kaneo's signature over
// it. It has already answered the request - 413, 400 or 401 - when ok is
// false, so a caller only ever sees bytes Kaneo signed.
//
// Bounded because this endpoint is unauthenticated until the HMAC is
// checked, and the body must be buffered whole to check it. Without a cap
// a large POST is memory growth an anonymous caller controls.
func (d *dispatcher) verifiedBody(w http.ResponseWriter, r *http.Request) (body []byte, ok bool) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			slog.Warn("reject", "reason", "body over cap", "cap", maxBody)
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			slog.Warn("reject", "reason", "unreadable body", "err", err)
			w.WriteHeader(http.StatusBadRequest)
		}
		return nil, false
	}
	// Header.Get takes the first of a repeated header; see
	// TestDuplicateSignatureHeaderStillVerifies for why that is pinned.
	if !d.verify(raw, r.Header.Get("X-Kaneo-Signature")) {
		slog.Warn("reject", "reason", "bad signature")
		w.WriteHeader(http.StatusUnauthorized)
		return nil, false
	}
	return raw, true
}

// verify checks Kaneo's HMAC-SHA256 over the exact bytes it sent.
func (d *dispatcher) verify(body []byte, sigHex string) bool {
	if sigHex == "" {
		return false
	}
	got, err := hex.DecodeString(sigHex)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, d.secret)
	_, _ = mac.Write(body) // a hash.Hash never returns an error
	// hmac.Equal is constant-time and length-safe, so a wrong-length
	// signature is simply false rather than a server error.
	return hmac.Equal(got, mac.Sum(nil))
}
