package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// boardWith is a board holding one card in one column, plus a very old
// card in an inert column that must never be looked at.
func boardWith(column, id, ticket, createdAt string) map[string]any {
	return map[string]any{"data": map[string]any{"columns": []map[string]any{
		{"slug": column, "tasks": []map[string]any{{"id": id, "ticketId": ticket, "createdAt": createdAt}}},
		{"slug": "in-progress", "tasks": []map[string]any{{"id": "busy", "ticketId": "T-9", "createdAt": ago(99 * time.Hour)}}},
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
	s, err := f.d.reconcile(context.Background(), dry)
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
	// boardWith also plants a 99h-old card in in-progress.
	if s := f.reconcile(false); s.checked != 1 {
		t.Errorf("checked %d cards, want 1: in-progress owes nothing", s.checked)
	}
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

// A card the sweep cannot date must say so, not pass as fresh forever.
func TestCardWithoutAClockIsReportedNotIgnored(t *testing.T) {
	for _, tc := range []struct {
		name, createdAt string
		wantSkipped     int
		wantErrors      int
	}{
		{"NoCreatedAt", "", 1, 0},
		{"UnparseableCreatedAt", "yesterday-ish", 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.kaneo.board = boardWith("to-do", "t1", "T-1", tc.createdAt)
			s := f.reconcile(true)
			if len(s.skipped) != tc.wantSkipped || len(s.errors) != tc.wantErrors {
				t.Errorf("sweep = %+v, want %d skipped and %d errors", s, tc.wantSkipped, tc.wantErrors)
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
		{"NoStatus", nil, 0, 1},
		{"UnrelatedStatus", []string{"ci/build"}, 0, 1},
		{"IntegrationStatus", []string{"ci/build", "nightly/integration"}, 1, 0},
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
	f.d.repos = map[string]string{"0": "Other/gamma"}
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
	if len(s.skipped) != 1 || s.skipped[0] != "T-1: claude-session-0 does not work TestOwner/elsewhere" {
		t.Errorf("skipped = %v", s.skipped)
	}
}

func TestUnreadableBoardIsAnError(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = `{"error":"nope"}`
	if _, err := f.d.reconcile(context.Background(), false); err == nil {
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
	f.wantLog(`msg="reconcile done"`)
	f.wantLog("redispatched=1")
	if len(f.pods.launches()) != 1 {
		t.Error("a real sweep did not launch the stuck card's stage")
	}
}
