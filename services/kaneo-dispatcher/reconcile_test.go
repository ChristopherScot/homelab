package main

import (
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

// boardWith is a board holding one card in one column, plus a very old
// card in an inert column that must never be looked at.
func boardWith(column, id, ticket, createdAt string) map[string]any {
	return map[string]any{"data": map[string]any{"columns": []map[string]any{
		{"slug": column, "tasks": []map[string]any{{"id": id, "ticketId": ticket, "createdAt": createdAt}}},
		{"slug": "needs-human-review", "tasks": []map[string]any{{"id": "waiting", "ticketId": "T-9", "createdAt": ago(99 * time.Hour)}}},
	}}}
}

// moved records that a card changed column `when` ago, among other
// activity that is not a move.
func (f *fixture) moved(id string, when time.Duration) {
	f.kaneo.activity[id] = []map[string]string{
		{"type": "comment", "createdAt": ago(1 * time.Minute)},
		{"type": "status_changed", "createdAt": ago(when)},
	}
}

// stale puts one card in a column, moved there long enough ago to be
// owed work, with a single repo label.
func (f *fixture) stale(column string) {
	f.kaneo.board = boardWith(column, "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
}

func (f *fixture) reconcile(dry bool) sweep {
	f.t.Helper()
	s, err := f.d.reconcile(f.t.Context(), dry)
	if err != nil {
		f.t.Fatalf("reconcile: %v", err)
	}
	return s
}

func openPR(sha string) []map[string]any {
	return []map[string]any{{"merged_at": nil, "head": map[string]string{"sha": sha}}}
}

func TestFreshCardIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 1*time.Hour)
	s := f.reconcile(false)
	if s.checked != 1 || len(s.redispatched)+len(s.skipped)+len(s.errors) != 0 {
		t.Errorf("sweep = %+v, want one card checked and nothing said", s)
	}
	if hits := f.github.calls(); len(hits) != 0 {
		t.Errorf("a fresh card was looked up on GitHub: %v", hits)
	}
	f.wantNoLaunch()
}

func TestInertColumnsAreNotSwept(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 1*time.Hour)
	// boardWith also plants a 99h-old card in needs-human-review.
	if s := f.reconcile(false); s.checked != 1 {
		t.Errorf("checked %d cards, want 1: needs-human-review owes nothing", s.checked)
	}
}

// The author moves a card to In Progress first and works second, so an
// author that dies in between strands it where nothing dispatches from.
// A stale card there goes back to the author - with its work-exists
// check skipped, because judging existing work is the author's job and
// it must see the card to do it. CLA-15, 2026-11-10.
func TestStrandedInProgressCardIsHandedBackToTheAuthor(t *testing.T) {
	f := newFixture(t)
	f.stale("in-progress")
	// Work exists: an open pull request. For any dispatching column that
	// would mean "skip"; here it is precisely what the author must judge.
	f.github.prs["TestOwner:fix/t1"] = openPR("abc")
	s := f.reconcile(false)
	if len(s.redispatched) != 1 || s.redispatched[0] != "T-1 (in-progress, 5h)" {
		t.Errorf("sweep = %+v, want T-1 handed back after 5h in in-progress", s)
	}
	l := f.pods.launches()
	want := []string{"sh", "-c", launchLine, "/usr/local/bin/stage-author", "t1", "TestOwner/testrepo"}
	if len(l) != 1 || l[0].pod != "claude-session-0" || !slices.Equal(l[0].argv, want) {
		t.Errorf("launches = %v, want the author stage in claude-session-0 with t1 and its repo", l)
	}
	if hits := f.github.calls(); len(hits) != 0 {
		t.Errorf("a stranded card was looked up on GitHub: %v; that judgement is the author's", hits)
	}
}

func TestFreshInProgressCardIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("in-progress", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 1*time.Hour)
	s := f.reconcile(false)
	if s.checked != 1 || len(s.redispatched)+len(s.skipped)+len(s.errors) != 0 {
		t.Errorf("sweep = %+v, want the card checked and left alone: the author may still be working it", s)
	}
	f.wantUntouched()
}

func TestStaleCardWhoseWorkExistsIsSkipped(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	// The branch is the raw id, never the ticket id.
	f.github.prs["TestOwner:fix/t1"] = openPR("abc")
	s := f.reconcile(false)
	if len(s.skipped) != 1 || s.skipped[0] != "T-1: work already exists" {
		t.Errorf("skipped = %v, want the pull request to count as the author having run", s.skipped)
	}
	f.wantNoLaunch()
}

func TestStaleCardWithNoWorkIsRedispatched(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	s := f.reconcile(false)
	if len(s.redispatched) != 1 || s.redispatched[0] != "T-1 (to-do, 5h)" {
		t.Errorf("redispatched = %v, want T-1 after 5h in to-do", s.redispatched)
	}
	l := f.pods.launches()
	if len(l) != 1 || l[0].pod != "claude-session-0" || l[0].argv[4] != "t1" {
		t.Errorf("launches = %v, want the author stage with the raw id t1", l)
	}
	f.wantLog("stuck card, re-dispatching")
}

func TestDryRunReportsWithoutLaunching(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	s := f.reconcile(true)
	if len(s.redispatched) != 1 || s.redispatched[0] != "T-1 (to-do, 5h) [dry-run]" {
		t.Errorf("redispatched = %v, want a dry-run line", s.redispatched)
	}
	if calls := f.pods.all(); len(calls) != 0 {
		t.Errorf("a dry run touched a pod: %v", calls)
	}
	// Nor woke the set: a dry run on a sleeping board must leave it
	// asleep, or the hourly sweep's dry run would be a wake-up call.
	f.wantUntouched()
}

// Created straight into the column, never moved: creation is the clock.
func TestCardWithNoMovesUsesItsCreationTime(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(6*time.Hour))
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	if s := f.reconcile(true); len(s.redispatched) != 1 {
		t.Errorf("sweep = %+v, want the 6h-old card found", s)
	}
}

// A card the sweep cannot date must be reported, not pass as fresh
// forever.
func TestCardWithoutAClockIsAnError(t *testing.T) {
	for _, tc := range []struct {
		name, createdAt string
	}{
		{name: "NoCreatedAt"},
		{name: "UnparseableCreatedAt", createdAt: "yesterday-ish"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.kaneo.board = boardWith("to-do", "t1", "T-1", tc.createdAt)
			s := f.reconcile(true)
			if len(s.errors) != 1 || len(s.redispatched)+len(s.skipped) != 0 {
				t.Errorf("sweep = %+v, want exactly one error", s)
			}
		})
	}
}

func TestUnparseableMoveTimeIsAnError(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.kaneo.activity["t1"] = []map[string]string{{"type": "status_changed", "createdAt": "not a time"}}
	if s := f.reconcile(true); len(s.errors) != 1 || len(s.redispatched) != 0 {
		t.Errorf("sweep = %+v, want one error and no redispatch", s)
	}
}

func TestInReviewNeedsTheIntegrationStatus(t *testing.T) {
	for _, tc := range []struct {
		name             string
		contexts         []string
		wantSkipped      int
		wantRedispatched int
	}{
		{name: "NoStatus", wantRedispatched: 1},
		{name: "UnrelatedStatus", contexts: []string{"ci/build"}, wantRedispatched: 1},
		{name: "IntegrationStatus", contexts: []string{"ci/build", "nightly/integration"}, wantSkipped: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.stale("in-review")
			f.github.prs["TestOwner:fix/t1"] = openPR("abc")
			f.github.statuses["abc"] = tc.contexts
			s := f.reconcile(false)
			if got := len(s.skipped); got != tc.wantSkipped {
				t.Errorf("skipped %d cards, want %d: %+v", got, tc.wantSkipped, s)
			}
			if got := len(s.redispatched); got != tc.wantRedispatched {
				t.Errorf("redispatched %d cards, want %d: %+v", got, tc.wantRedispatched, s)
			}
			if tc.wantRedispatched == 1 {
				if l := f.pods.launches(); len(l) != 1 || l[0].pod != "claude-session-2" {
					t.Errorf("launches = %v, want the test pod", l)
				}
			}
		})
	}
}

// CLA-13 was merged by hand while in In Review and carries no
// nightly/integration status; the test stage must not run against work
// that is already on main.
func TestMergedPullRequestEndsTheStoryInAnyColumn(t *testing.T) {
	for _, column := range []string{"to-do", "in-review", "mergeable"} {
		t.Run(column, func(t *testing.T) {
			f := newFixture(t)
			f.stale(column)
			f.d.repos = nil
			f.github.prs["TestOwner:fix/t1"] = []map[string]any{{"merged_at": "2026-11-01T00:00:00Z", "head": map[string]string{"sha": "abc"}}}
			s := f.reconcile(false)
			if len(s.skipped) != 1 || len(s.redispatched) != 0 {
				t.Errorf("sweep = %+v, want the merged card skipped", s)
			}
			f.wantNoLaunch()
		})
	}
}

func TestMergeableWithAnUnmergedPullRequestIsRedispatched(t *testing.T) {
	f := newFixture(t)
	f.stale("mergeable")
	f.d.repos = nil
	f.github.prs["TestOwner:fix/t1"] = openPR("abc")
	if s := f.reconcile(false); len(s.redispatched) != 1 {
		t.Errorf("sweep = %+v, want the merge stage re-run", s)
	}
	if l := f.pods.launches(); len(l) != 1 || l[0].pod != "claude-session-1" {
		t.Errorf("launches = %v, want the merge pod", l)
	}
}

// Every route must say what finished work looks like; a column that has
// no answer must not be swept as done.
func TestEveryRouteHasAWorkCheck(t *testing.T) {
	for column := range routes {
		t.Run(column, func(t *testing.T) {
			f := newFixture(t)
			f.github.prs["TestOwner:fix/t1"] = openPR("abc")
			if _, err := f.d.workExists(t.Context(), column, "TestOwner/testrepo", "t1"); err != nil {
				t.Errorf("workExists(%s) = %v", column, err)
			}
		})
	}
	f := newFixture(t)
	f.github.prs["TestOwner:fix/t1"] = openPR("abc")
	if _, err := f.d.workExists(t.Context(), "not-a-route", "TestOwner/testrepo", "t1"); err == nil {
		t.Error("an unknown column was answered instead of refused")
	}
}

// An error must not read as "nothing to do".
func TestGitHubFailureIsReportedNotTreatedAsNoWork(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	f.github.fail = http.StatusUnauthorized
	s := f.reconcile(false)
	if len(s.errors) != 1 || !strings.HasPrefix(s.errors[0], "T-1: ") || len(s.redispatched) != 0 {
		t.Errorf("sweep = %+v, want one error and no redispatch", s)
	}
	f.wantNoLaunch()
}

// The owner in the label is the owner asked on GitHub, and the pod's
// list is matched on the same name - one resolution, two readers.
func TestOwnerQualifiedLabelIsLookedUpUnderThatOwner(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	f.kaneo.labels["t1"] = []string{"repo:Other/gamma"}
	f.d.repos = map[string][]string{"0": {"Other/gamma"}}
	f.reconcile(true)
	hits := f.github.calls()
	if len(hits) != 1 || !strings.HasPrefix(hits[0], "/repos/Other/gamma/pulls?head=Other%3Afix%2Ft1") {
		t.Errorf("github hits = %v, want one pulls lookup under Other/gamma with that owner's head", hits)
	}
}

func TestSkipReasonsReadTheSameAsTheWebhookLogs(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")
	f.kaneo.labels["t1"] = []string{"repo:elsewhere"}
	s := f.reconcile(true)
	want := "T-1: claude-session-0 does not work TestOwner/elsewhere"
	if len(s.skipped) != 1 || s.skipped[0] != want {
		t.Errorf("skipped = %v, want [%q]", s.skipped, want)
	}
}

func TestUnreadableBoardIsAnError(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = `{"error":"nope"}`
	if _, err := f.d.reconcile(t.Context(), false); err == nil {
		t.Error("a board that is not a board was swept without error")
	}
}

func TestReconcileEndpoint(t *testing.T) {
	f := newFixture(t)
	f.stale("to-do")

	w := f.serve(httptest.NewRequest(http.MethodGet, "/reconcile", nil))
	if w.Code != http.StatusMethodNotAllowed || !strings.Contains(w.Body.String(), "POST with a signature") {
		t.Errorf("GET /reconcile = %d %q, want 405 saying how", w.Code, w.Body.String())
	}
	if w := f.post("/reconcile", ""); w.Code != http.StatusUnauthorized {
		t.Errorf("unsigned POST /reconcile = %d, want 401", w.Code)
	}
	if w := f.signed("/reconcile?dry", ""); w.Code != http.StatusAccepted {
		t.Errorf("signed dry POST = %d, want 202", w.Code)
	}
	f.wantLog(`card="T-1 (to-do, 5h) [dry-run]"`)
	f.wantNoLaunch()

	// Only the flag is a dry run, not any URL that happens to spell it.
	if w := f.signed("/reconcile?foundry=1", ""); w.Code != http.StatusAccepted {
		t.Errorf("signed POST = %d, want 202", w.Code)
	}
	f.wantLog(`card="T-1 (to-do, 5h)"`)
	if len(f.pods.launches()) != 1 {
		t.Error("a real sweep did not launch the stuck card's stage")
	}
}
