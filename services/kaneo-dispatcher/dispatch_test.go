package main

import (
	"errors"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"
)

func TestUnsignedPostIsRefused(t *testing.T) {
	f := newFixture(t)
	if w := f.post("/", move("t1", "to-do")); w.Code != http.StatusUnauthorized {
		t.Errorf("unsigned POST / = %d, want 401", w.Code)
	}
	f.wantNoLaunch()
}

func TestWrongSignatureIsRefused(t *testing.T) {
	f := newFixture(t)
	body := move("t1", "to-do")
	for _, tc := range []struct{ name, sig string }{
		{"OtherSecret", sign(body + "x")},
		{"NotHex", "zz"},
		{"Short", "abcd"},
	} {
		if w := f.post("/", body, "X-Kaneo-Signature", tc.sig); w.Code != http.StatusUnauthorized {
			t.Errorf("POST / with %s signature = %d, want 401", tc.name, w.Code)
		}
	}
	f.wantNoLaunch()
}

// Node handed a repeated header over as an array, and Buffer.from(array)
// threw - a valid delivery answered 500. Go's Header.Get takes the first
// value, so the case cannot recur; this pins that.
func TestDuplicateSignatureHeaderStillVerifies(t *testing.T) {
	f := newFixture(t)
	body := move("t1", "backlog")
	w := f.post("/", body, "X-Kaneo-Signature", sign(body), "X-Kaneo-Signature", sign(body))
	if w.Code != http.StatusAccepted {
		t.Errorf("duplicated header = %d, want 202", w.Code)
	}
}

func TestBodyOverOneMiBIsRefused(t *testing.T) {
	f := newFixture(t)
	body := strings.Repeat("x", maxBody+1)
	if w := f.signed("/", body); w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized body = %d, want 413", w.Code)
	}
	// Exactly the cap is still read and, being unparseable, still 202.
	body = strings.Repeat("x", maxBody)
	if w := f.signed("/", body); w.Code != http.StatusAccepted {
		t.Errorf("body at the cap = %d, want 202", w.Code)
	}
}

func TestInertColumnIsLoggedNotDispatched(t *testing.T) {
	f := newFixture(t)
	if w := f.signed("/", `{"event":"task.status_changed","task":{"id":"t1","ticketId":"T-1"},"data":{"newStatus":"in-progress"}}`); w.Code != http.StatusAccepted {
		t.Fatalf("inert column = %d, want 202", w.Code)
	}
	f.wantLog(`msg=noop task=T-1 column=in-progress`)
	f.wantNoLaunch()
	if n := f.kaneo.calls(); n != 0 {
		t.Errorf("an inert column looked up labels (%d Kaneo calls)", n)
	}
}

func TestOtherEventsAreIgnored(t *testing.T) {
	f := newFixture(t)
	f.signed("/", `{"event":"task.created","task":{"id":"t1"},"data":{"newStatus":"to-do"}}`)
	f.wantLog("msg=ignore event=task.created")
	f.wantNoLaunch()
}

func TestUnparseableBodyIsAcceptedAndLogged(t *testing.T) {
	f := newFixture(t)
	if w := f.signed("/", "not json"); w.Code != http.StatusAccepted {
		t.Errorf("unparseable body = %d, want 202 (the signature was fine)", w.Code)
	}
	f.wantLog(`reason="unparseable body"`)
}

func TestDispatchingColumnLaunchesTheStageInItsPod(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"bug", "repo:testrepo"}
	if w := f.signed("/", move("t2", "to-do")); w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202", w.Code)
	}
	l := f.pods.launches()
	if len(l) != 1 {
		t.Fatalf("launches = %v, want exactly one", l)
	}
	if l[0].pod != "claude-session-0" {
		t.Errorf("launched in %s, want claude-session-0 for to-do", l[0].pod)
	}
	// The script and the raw task id arrive as positional arguments, so
	// neither is spliced into shell text.
	want := []string{"sh", "-c", launchLine, "/usr/local/bin/nightly-author", "t2"}
	if !slices.Equal(l[0].argv, want) {
		t.Errorf("argv = %q, want %q", l[0].argv, want)
	}
	f.wantLog("msg=start task=t2 repo=TestOwner/testrepo pod=claude-session-0 script=nightly-author")
	f.wantLog("msg=launched task=t2 repo=TestOwner/testrepo rc=0")
}

func TestEachColumnRoutesToItsOwnPod(t *testing.T) {
	for _, tc := range []struct {
		column, pod, script string
	}{
		{"to-do", "claude-session-0", "/usr/local/bin/nightly-author"},
		{"in-review", "claude-session-2", "/usr/local/bin/nightly-test"},
		{"mergeable", "claude-session-1", "/usr/local/bin/nightly-merge"},
	} {
		t.Run(tc.column, func(t *testing.T) {
			f := newFixture(t)
			f.d.repos = nil // every pod works every repo here
			f.kaneo.labels["t"] = []string{"repo:testrepo"}
			f.signed("/", move("t", tc.column))
			l := f.pods.launches()
			if len(l) != 1 || l[0].pod != tc.pod || l[0].argv[3] != tc.script {
				t.Errorf("%s launched %v, want %s running %s", tc.column, l, tc.pod, tc.script)
			}
		})
	}
}

func TestBusyProbeRunsInTheStagePodBeforeTheLaunch(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	calls := f.pods.all()
	if len(calls) != 2 {
		t.Fatalf("calls = %v, want the busy probe then the launch", calls)
	}
	want := []string{"sh", "-c", busyProbe}
	if calls[0].pod != "claude-session-0" || !slices.Equal(calls[0].argv, want) {
		t.Errorf("first call = %v, want %q in claude-session-0", calls[0], want)
	}
}

// The probe must lock the file the scripts lock, override included. Read
// from the script itself, so a change there fails here.
func TestBusyProbeLocksWhatTheScriptsLock(t *testing.T) {
	src, err := os.ReadFile("../../claude-pods/lib/nightly-common.sh")
	if err != nil {
		t.Fatal(err)
	}
	const lockExpr = `"${NIGHTLY_LOCK:-/tmp/nightly.lock}"`
	if !strings.Contains(string(src), lockExpr) {
		t.Fatalf("nightly-common.sh no longer locks %s; busyProbe must change with it", lockExpr)
	}
	if !strings.Contains(busyProbe, lockExpr) {
		t.Errorf("busyProbe = %q does not lock %s", busyProbe, lockExpr)
	}
}

func TestBusyPodIsNotGivenASecondRun(t *testing.T) {
	f := newFixture(t)
	f.pods.busy = true
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog("msg=busy task=t2 repo=TestOwner/testrepo pod=claude-session-0")
}

// A failed probe must not read as idle: starting a second agent on a
// live clone is the one thing the guard exists to prevent.
func TestUnansweredBusyProbeReadsAsBusy(t *testing.T) {
	f := newFixture(t)
	f.pods.fail = errors.New("the API server is away")
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog("cannot tell whether pod is busy; assuming it is")
	// The busy line follows, and its hint still holds: moving the card
	// again is the retry after an outage too, since no webhook re-fires.
	f.wantLog("msg=busy task=t2")
}

func TestPodThatDoesNotWorkTheRepoIsSkipped(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"repo:elsewhere"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog(`reason="claude-session-0 does not work TestOwner/elsewhere"`)
}

// A short label resolves under the owner once, in repoForTask, so the
// pod's list and the GitHub lookup see the same owner/name.
func TestRepoLabelResolvesToOwnerAndName(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["short"] = []string{"repo:alpha"}
	f.kaneo.labels["full"] = []string{"repo:Other/gamma"}
	for id, want := range map[string]string{"short": "TestOwner/alpha", "full": "Other/gamma"} {
		got, ok, err := f.d.repoForTask(t.Context(), id)
		if err != nil || !ok || got != want {
			t.Errorf("repoForTask(%s) = %q, %v, %v; want %q", id, got, ok, err, want)
		}
	}
}

func TestRepoListIsMatchedByFullName(t *testing.T) {
	d := &dispatcher{repos: map[string][]string{
		"0": {"TestOwner/alpha", "TestOwner/beta", "Other/gamma"},
		"1": {},
	}}
	for repo, want := range map[string]bool{
		"TestOwner/alpha": true,
		"TestOwner/beta":  true,
		"Other/gamma":     true,
		"TestOwner/delta": false,
	} {
		if got := d.podWorksRepo("claude-session-0", repo); got != want {
			t.Errorf("podWorksRepo(pod0, %q) = %v, want %v", repo, got, want)
		}
	}
	// No list for this ordinal is not a reason to refuse; an empty one is.
	if !d.podWorksRepo("claude-session-2", "TestOwner/alpha") {
		t.Error("a pod with no list refused work")
	}
	if d.podWorksRepo("claude-session-1", "TestOwner/alpha") {
		t.Error("a pod with an empty list accepted work")
	}
}

func TestReposComeFromTheEnvironmentByOrdinal(t *testing.T) {
	environ := []string{"PATH=/bin", "REPOS_POD0=a/b", "REPOS_POD2=c/d, e/f\ng/h", "REPOS=ignored", "NOEQUALS"}
	got := reposFromEnv(environ)
	want := map[string][]string{"0": {"a/b"}, "2": {"c/d", "e/f", "g/h"}}
	if !maps.EqualFunc(got, want, slices.Equal) {
		t.Errorf("reposFromEnv(%q) = %v, want %v", environ, got, want)
	}
}

func TestCardWithoutExactlyOneRepoLabelIsSkipped(t *testing.T) {
	for _, tc := range []struct {
		name   string
		labels []string
	}{
		{name: "NoLabels"},
		{name: "NoRepoLabel", labels: []string{"bug"}},
		{name: "TwoRepoLabels", labels: []string{"repo:a", "repo:b"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.kaneo.labels["t2"] = tc.labels
			f.signed("/", move("t2", "to-do"))
			f.wantNoLaunch()
			f.wantLog(`reason="card needs exactly one repo: label"`)
		})
	}
}

// A Kaneo outage must not read as a board full of unlabelled cards.
func TestLabelLookupFailureIsAnErrorNotNoLabel(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labelErr = http.StatusBadGateway
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog(`msg="cannot read labels" task=t2 column=to-do`)
	f.wantLog("502")
	if strings.Contains(f.log.String(), "exactly one repo") {
		t.Error("a failed lookup was reported as a missing label")
	}
}

// The Kaneo CLI's `{"error": ...}` with exit 0 cost three separate
// fixes. A typed decode makes the same shape from the API a parse error
// rather than an empty list.
func TestNonArrayLabelAnswerIsAnError(t *testing.T) {
	f := newFixture(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"error":"unauthorized"}`)
	}))
	t.Cleanup(srv.Close)
	f.d.kaneoURL = srv.URL
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog(`msg="cannot read labels"`)
}

func TestPayloadWithoutATaskIdIsSkipped(t *testing.T) {
	f := newFixture(t)
	f.signed("/", `{"event":"task.status_changed","task":{},"data":{"newStatus":"to-do"}}`)
	f.wantNoLaunch()
	f.wantLog(`reason="payload names no task id"`)
}

func TestWebhookAcceptsAnyPath(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	if w := f.signed("/kaneo/hook", move("t2", "to-do")); w.Code != http.StatusAccepted {
		t.Errorf("POST /kaneo/hook = %d, want 202", w.Code)
	}
	if len(f.pods.launches()) != 1 {
		t.Error("a delivery on a sub-path did not dispatch")
	}
}
