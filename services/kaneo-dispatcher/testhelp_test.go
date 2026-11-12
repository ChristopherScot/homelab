package main

// Fakes for everything the dispatcher talks to: Kaneo, GitHub and the
// session pods. No cluster, no network, no node.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const testSecret = "testsecret"

func sign(body string) string {
	mac := hmac.New(sha256.New, []byte(testSecret))
	_, _ = mac.Write([]byte(body))
	return hex.EncodeToString(mac.Sum(nil))
}

// execCall is one command the dispatcher asked a pod to run.
type execCall struct {
	pod  string
	argv []string
}

// script is what `sh -c` was given.
func (c execCall) script() string {
	if len(c.argv) > 2 {
		return c.argv[2]
	}
	return ""
}

// recorder stands in for the session pods and their StatefulSet. The
// busy probe answers idle unless busy is set; every other exec exits 0;
// a wake succeeds unless wakeErr is set.
type recorder struct {
	mu      sync.Mutex
	calls   []execCall
	order   []string // "wake" and "exec", in the order they happened
	busy    bool
	fail    error // returned from every exec when set: the API is unreachable
	wakeErr error // returned from every wake when set
}

func (r *recorder) exec(_ context.Context, pod string, argv []string) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c := execCall{pod, argv}
	r.calls = append(r.calls, c)
	r.order = append(r.order, "exec")
	if r.fail != nil {
		return 0, r.fail
	}
	if r.busy && c.script() == busyProbe {
		return 1, nil
	}
	return 0, nil
}

func (r *recorder) wake(context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.order = append(r.order, "wake")
	return r.wakeErr
}

// all is every exec call so far.
func (r *recorder) all() []execCall {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]execCall(nil), r.calls...)
}

// actions is everything asked of the cluster, wakes and execs, in order.
func (r *recorder) actions() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.order...)
}

// wakes is how many times the set was woken.
func (r *recorder) wakes() int {
	n := 0
	for _, a := range r.actions() {
		if a == "wake" {
			n++
		}
	}
	return n
}

// launches are the exec calls that started a stage, as opposed to the
// busy probes before them.
func (r *recorder) launches() []execCall {
	var out []execCall
	for _, c := range r.all() {
		if c.script() == launchLine {
			out = append(out, c)
		}
	}
	return out
}

// stubKaneo answers the three API calls the dispatcher makes. Empty
// answers are encoded as [] rather than null, as the real API does.
type stubKaneo struct {
	mu       sync.Mutex
	labels   map[string][]string // task id -> label names
	labelErr int                 // non-zero: answer every label lookup with this status
	activity map[string][]map[string]string
	board    any // what /task/tasks/{project} returns
	hits     int
}

func (s *stubKaneo) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hits++
	w.Header().Set("Content-Type", "application/json")
	switch {
	case strings.HasPrefix(r.URL.Path, "/api/label/task/"):
		if s.labelErr != 0 {
			w.WriteHeader(s.labelErr)
			return
		}
		id := strings.TrimPrefix(r.URL.Path, "/api/label/task/")
		out := []map[string]string{}
		for _, name := range s.labels[id] {
			out = append(out, map[string]string{"name": name})
		}
		_ = json.NewEncoder(w).Encode(out)
	case strings.HasPrefix(r.URL.Path, "/api/activity/"):
		id := strings.TrimPrefix(r.URL.Path, "/api/activity/")
		acts := s.activity[id]
		if acts == nil {
			acts = []map[string]string{}
		}
		_ = json.NewEncoder(w).Encode(acts)
	case strings.HasPrefix(r.URL.Path, "/api/task/tasks/"):
		_ = json.NewEncoder(w).Encode(s.board)
	default:
		http.NotFound(w, r)
	}
}

func (s *stubKaneo) calls() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.hits
}

// stubGitHub answers the pull-request and commit-status lookups the
// sweep makes. prs is keyed by the `head` query parameter.
type stubGitHub struct {
	mu       sync.Mutex
	prs      map[string][]map[string]any
	statuses map[string][]string // head sha -> status contexts
	fail     int                 // non-zero: answer everything with this status
	hits     []string
}

func (s *stubGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hits = append(s.hits, r.URL.RequestURI())
	w.Header().Set("Content-Type", "application/json")
	if s.fail != 0 {
		w.WriteHeader(s.fail)
		return
	}
	switch {
	case strings.HasSuffix(r.URL.Path, "/pulls"):
		prs := s.prs[r.URL.Query().Get("head")]
		if prs == nil {
			prs = []map[string]any{}
		}
		_ = json.NewEncoder(w).Encode(prs)
	case strings.HasSuffix(r.URL.Path, "/status"):
		parts := strings.Split(r.URL.Path, "/")
		sha := parts[len(parts)-2]
		statuses := []map[string]string{}
		for _, c := range s.statuses[sha] {
			statuses = append(statuses, map[string]string{"context": c})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"statuses": statuses})
	default:
		http.NotFound(w, r)
	}
}

func (s *stubGitHub) calls() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.hits...)
}

// lockedBuffer collects log lines from the request goroutine and the
// dispatch goroutine without a data race.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// fixture is a dispatcher wired to the fakes above.
type fixture struct {
	t      *testing.T
	d      *dispatcher
	kaneo  *stubKaneo
	github *stubGitHub
	pods   *recorder
	log    *lockedBuffer
}

// newFixture builds one. Tests using it must not call t.Parallel(): the
// default logger is process-global, and two fixtures at once would read
// each other's lines.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{
		t:      t,
		kaneo:  &stubKaneo{labels: map[string][]string{}, activity: map[string][]map[string]string{}},
		github: &stubGitHub{prs: map[string][]map[string]any{}, statuses: map[string][]string{}},
		pods:   &recorder{},
		log:    &lockedBuffer{},
	}
	ks := httptest.NewServer(f.kaneo)
	gs := httptest.NewServer(f.github)
	t.Cleanup(ks.Close)
	t.Cleanup(gs.Close)

	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(f.log, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	f.d = &dispatcher{
		owner:        "TestOwner",
		branchPrefix: "fix/",
		project:      "proj",
		kaneoURL:     ks.URL,
		githubURL:    gs.URL,
		apiKey:       "testkey",
		secret:       []byte(testSecret),
		ghToken:      "ghtoken",
		repos:        map[string][]string{"0": {"TestOwner/testrepo", "TestOwner/other"}, "2": {"TestOwner/testrepo"}},
		stale:        4 * time.Hour,
		exec:         f.pods.exec,
		wake:         f.pods.wake,
		client:       &http.Client{Timeout: 5 * time.Second},
	}
	return f
}

// serve runs one request through the real route table and waits for
// whatever work it started after answering.
func (f *fixture) serve(req *http.Request) *httptest.ResponseRecorder {
	f.t.Helper()
	w := httptest.NewRecorder()
	f.d.mux().ServeHTTP(w, req)
	f.d.inflight.Wait()
	return w
}

// post delivers a body, with any headers given as name, value pairs.
func (f *fixture) post(path, body string, headers ...string) *httptest.ResponseRecorder {
	f.t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Add(headers[i], headers[i+1])
	}
	return f.serve(req)
}

// signed posts a body with a valid signature.
func (f *fixture) signed(path, body string) *httptest.ResponseRecorder {
	f.t.Helper()
	return f.post(path, body, "X-Kaneo-Signature", sign(body))
}

// move is a task.status_changed delivery for one card.
func move(id, column string) string {
	return `{"event":"task.status_changed","task":{"id":"` + id + `"},"data":{"newStatus":"` + column + `"}}`
}

func (f *fixture) wantLog(substr string) {
	f.t.Helper()
	if !strings.Contains(f.log.String(), substr) {
		f.t.Errorf("log does not contain %q:\n%s", substr, f.log.String())
	}
}

func (f *fixture) wantNoLaunch() {
	f.t.Helper()
	if l := f.pods.launches(); len(l) != 0 {
		f.t.Errorf("a stage was launched: %v", l)
	}
}

// wantUntouched is wantNoLaunch and no wake either: nothing about the
// cluster was changed.
func (f *fixture) wantUntouched() {
	f.t.Helper()
	f.wantNoLaunch()
	if n := f.pods.wakes(); n != 0 {
		f.t.Errorf("the session pods were woken %d times", n)
	}
}

func ago(d time.Duration) string { return time.Now().Add(-d).UTC().Format(time.RFC3339Nano) }
