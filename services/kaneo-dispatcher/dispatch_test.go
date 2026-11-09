package main

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUnsignedPostIsRefused(t *testing.T) {
	f := newFixture(t)
	if w := f.post("/", move("t1", "to-do")); w.Code != http.StatusUnauthorized {
		t.Errorf("unsigned POST = %d, want 401", w.Code)
	}
	f.wantNoLaunch()
}

func TestWrongSignatureIsRefused(t *testing.T) {
	f := newFixture(t)
	body := move("t1", "to-do")
	for name, sig := range map[string]string{
		"other secret": sign(body + "x"),
		"not hex":      "zz",
		"short":        "abcd",
	} {
		if w := f.post("/", body, "X-Kaneo-Signature", sig); w.Code != http.StatusUnauthorized {
			t.Errorf("%s: got %d, want 401", name, w.Code)
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
	if f.kaneo.hits != 0 {
		t.Errorf("an inert column looked up labels (%d Kaneo calls)", f.kaneo.hits)
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
	argv := l[0].argv
	if len(argv) != 5 || argv[3] != "/usr/local/bin/nightly-author" || argv[4] != "t2" {
		t.Errorf("argv = %q, want sh -c <launch> /usr/local/bin/nightly-author t2", argv)
	}
	if !strings.Contains(argv[2], "setsid nohup") || !strings.Contains(argv[2], "&") {
		t.Errorf("launch is not detached: %q", argv[2])
	}
	f.wantLog("msg=start task=t2 repo=testrepo pod=claude-session-0 script=nightly-author")
	f.wantLog("msg=launched task=t2 repo=testrepo rc=0")
}

func TestEachColumnRoutesToItsOwnPod(t *testing.T) {
	for column, want := range map[string]stage{
		"to-do":     {"claude-session-0", "/usr/local/bin/nightly-author"},
		"in-review": {"claude-session-2", "/usr/local/bin/nightly-test"},
		"mergeable": {"claude-session-1", "/usr/local/bin/nightly-merge"},
	} {
		t.Run(column, func(t *testing.T) {
			f := newFixture(t)
			f.d.repos = nil // every pod works every repo here
			f.kaneo.labels["t"] = []string{"repo:testrepo"}
			f.signed("/", move("t", column))
			l := f.pods.launches()
			if len(l) != 1 || l[0].pod != want.pod || l[0].argv[3] != want.script {
				t.Errorf("%s launched %v, want %s running %s", column, l, want.pod, want.script)
			}
		})
	}
}

func TestBusyCheckRunsBeforeTheLaunch(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	calls := f.pods.calls
	if len(calls) != 2 || !strings.Contains(calls[0].line(), "flock -n /tmp/nightly.lock true") {
		t.Fatalf("calls = %v, want the flock check then the launch", calls)
	}
	if calls[0].pod != "claude-session-0" {
		t.Errorf("busy check asked %s, want the pod the stage runs in", calls[0].pod)
	}
}

func TestBusyPodIsNotGivenASecondRun(t *testing.T) {
	f := newFixture(t)
	f.pods.busy = true
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog("msg=busy task=t2 repo=testrepo pod=claude-session-0")
}

// A failed check must not read as idle: starting a second agent on a
// live clone is the one thing the guard exists to prevent.
func TestUnansweredBusyCheckReadsAsBusy(t *testing.T) {
	f := newFixture(t)
	f.pods.fail = errors.New("the API server is away")
	f.kaneo.labels["t2"] = []string{"repo:testrepo"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog("cannot tell whether pod is busy; assuming it is")
}

func TestPodThatDoesNotWorkTheRepoIsSkipped(t *testing.T) {
	f := newFixture(t)
	f.kaneo.labels["t2"] = []string{"repo:elsewhere"}
	f.signed("/", move("t2", "to-do"))
	f.wantNoLaunch()
	f.wantLog(`reason="claude-session-0 does not work elsewhere"`)
}

func TestRepoListMatchesFullNamesAndShortLabels(t *testing.T) {
	d := &dispatcher{owner: "TestOwner", repos: map[string]string{
		"0": "TestOwner/alpha,TestOwner/beta\nOther/gamma",
	}}
	for repo, want := range map[string]bool{
		"alpha":           true,
		"TestOwner/beta":  true,
		"Other/gamma":     true,
		"gamma":           false, // short names resolve under the owner
		"TestOwner/delta": false,
	} {
		if got := d.podWorksRepo("claude-session-0", repo); got != want {
			t.Errorf("podWorksRepo(pod0, %q) = %v, want %v", repo, got, want)
		}
	}
	// No list for this ordinal is not a reason to refuse.
	if !d.podWorksRepo("claude-session-1", "anything") {
		t.Error("a pod with no list refused work")
	}
}

func TestReposComeFromTheEnvironmentByOrdinal(t *testing.T) {
	got := reposFromEnv([]string{"PATH=/bin", "REPOS_POD0=a/b", "REPOS_POD2=c/d, e/f", "REPOS=ignored"})
	if got["0"] != "a/b" || got["2"] != "c/d, e/f" || len(got) != 2 {
		t.Errorf("reposFromEnv = %v", got)
	}
}

func TestCardWithoutExactlyOneRepoLabelIsSkipped(t *testing.T) {
	for name, labels := range map[string][]string{
		"no labels":       {},
		"no repo label":   {"bug"},
		"two repo labels": {"repo:a", "repo:b"},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.kaneo.labels["t2"] = labels
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
	f.wantLog(`msg="cannot read labels" task=t2 column=to-do err="/api/label/task/t2 -> 502"`)
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
