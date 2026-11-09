package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// boardWith is a board holding one card in one column.
func boardWith(column, id, ticket, createdAt string) map[string]any {
	return map[string]any{"data": map[string]any{"columns": []map[string]any{
		{"slug": column, "tasks": []map[string]any{{"id": id, "ticketId": ticket, "createdAt": createdAt}}},
		{"slug": "in-progress", "tasks": []map[string]any{{"id": "busy", "ticketId": "T-9", "createdAt": ago(99 * time.Hour)}}},
	}}}
}

func (f *fixture) moved(id string, when time.Duration) {
	f.kaneo.activity[id] = []map[string]string{
		{"type": "comment", "createdAt": ago(1 * time.Minute)},
		{"type": "status_changed", "createdAt": ago(when)},
	}
}

func (f *fixture) sweep(dry bool) sweep {
	f.t.Helper()
	s, err := f.d.reconcile(context.Background(), dry)
	if err != nil {
		f.t.Fatalf("reconcile: %v", err)
	}
	return s
}

func TestFreshCardIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 1*time.Hour)
	s := f.sweep(false)
	if s.Checked != 1 || len(s.Redispatched)+len(s.Skipped)+len(s.Errors) != 0 {
		t.Errorf("sweep = %+v, want one card checked and nothing said", s)
	}
	if len(f.github.hits) != 0 {
		t.Errorf("a fresh card was looked up on GitHub: %v", f.github.hits)
	}
	f.wantNoLaunch()
}

func TestInertColumnsAreNotSwept(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 1*time.Hour)
	// boardWith also plants a 99h-old card in in-progress.
	if s := f.sweep(false); s.Checked != 1 {
		t.Errorf("checked %d cards, want 1: in-progress owes nothing", s.Checked)
	}
}

func TestStaleCardWhoseWorkExistsIsSkipped(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	// The branch is the raw id, never the ticket id.
	f.github.prs["TestOwner:fix/t1"] = []map[string]any{{"merged_at": nil, "head": map[string]string{"sha": "abc"}}}
	s := f.sweep(false)
	if len(s.Skipped) != 1 || s.Skipped[0] != "T-1: work already exists" {
		t.Errorf("skipped = %v, want the pull request to count as the author having run", s.Skipped)
	}
	f.wantNoLaunch()
}

func TestStaleCardWithNoWorkIsRedispatched(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	s := f.sweep(false)
	if len(s.Redispatched) != 1 || !strings.HasPrefix(s.Redispatched[0], "T-1 (to-do, 5h)") {
		t.Errorf("redispatched = %v, want T-1 after 5h in to-do", s.Redispatched)
	}
	l := f.pods.launches()
	if len(l) != 1 || l[0].pod != "claude-session-0" || l[0].argv[4] != "t1" {
		t.Errorf("launches = %v, want the author stage with the raw id t1", l)
	}
	f.wantLog("stuck card, re-dispatching")
}

func TestDryRunReportsWithoutLaunching(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	s := f.sweep(true)
	if len(s.Redispatched) != 1 || !strings.HasSuffix(s.Redispatched[0], "[dry-run]") {
		t.Errorf("redispatched = %v, want a dry-run line", s.Redispatched)
	}
	if len(f.pods.calls) != 0 {
		t.Errorf("a dry run touched a pod: %v", f.pods.calls)
	}
}

// Created straight into the column, never moved: creation is the clock.
func TestCardWithNoMovesUsesItsCreationTime(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(6*time.Hour))
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	if s := f.sweep(true); len(s.Redispatched) != 1 {
		t.Errorf("sweep = %+v, want the 6h-old card found", s)
	}
}

func TestInReviewNeedsTheIntegrationStatus(t *testing.T) {
	for name, contexts := range map[string][]string{
		"no status":          {},
		"unrelated status":   {"ci/build"},
		"integration status": {"ci/build", "nightly/integration"},
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			f.kaneo.board = boardWith("in-review", "t1", "T-1", ago(10*time.Hour))
			f.moved("t1", 5*time.Hour)
			f.kaneo.labels["t1"] = []string{"repo:testrepo"}
			f.github.prs["TestOwner:fix/t1"] = []map[string]any{{"merged_at": nil, "head": map[string]string{"sha": "abc"}}}
			f.github.statuses["abc"] = contexts
			s := f.sweep(false)
			tested := strings.Contains(strings.Join(contexts, ","), "nightly/integration")
			if tested && len(s.Skipped) != 1 || !tested && len(s.Redispatched) != 1 {
				t.Errorf("%s: sweep = %+v", name, s)
			}
			if !tested {
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
			f.kaneo.board = boardWith(column, "t1", "T-1", ago(10*time.Hour))
			f.moved("t1", 5*time.Hour)
			f.kaneo.labels["t1"] = []string{"repo:testrepo"}
			f.d.repos = nil
			f.github.prs["TestOwner:fix/t1"] = []map[string]any{{"merged_at": "2026-11-01T00:00:00Z", "head": map[string]string{"sha": "abc"}}}
			s := f.sweep(false)
			if len(s.Skipped) != 1 || len(s.Redispatched) != 0 {
				t.Errorf("sweep = %+v, want the merged card skipped", s)
			}
			f.wantNoLaunch()
		})
	}
}

func TestMergeableWithAnUnmergedPullRequestIsRedispatched(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("mergeable", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	f.d.repos = nil
	f.github.prs["TestOwner:fix/t1"] = []map[string]any{{"merged_at": nil, "head": map[string]string{"sha": "abc"}}}
	if s := f.sweep(false); len(s.Redispatched) != 1 {
		t.Errorf("sweep = %+v, want the merge stage re-run", s)
	}
	if l := f.pods.launches(); len(l) != 1 || l[0].pod != "claude-session-1" {
		t.Errorf("launches = %v, want the merge pod", l)
	}
}

// An error must not read as "nothing to do".
func TestGitHubFailureIsReportedNotTreatedAsNoWork(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}
	f.github.fail = http.StatusUnauthorized
	s := f.sweep(false)
	if len(s.Errors) != 1 || !strings.HasPrefix(s.Errors[0], "T-1: ") || len(s.Redispatched) != 0 {
		t.Errorf("sweep = %+v, want one error and no redispatch", s)
	}
	f.wantNoLaunch()
}

func TestOwnerPrefixedLabelQueriesTheRepoUnderTheOwner(t *testing.T) {
	f := newFixture(t)
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:TestOwner/testrepo"}
	f.sweep(true)
	if len(f.github.hits) != 1 || !strings.HasPrefix(f.github.hits[0], "/repos/TestOwner/testrepo/pulls?") {
		t.Errorf("github hits = %v, want one pulls lookup under TestOwner/testrepo", f.github.hits)
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
	f.kaneo.board = boardWith("to-do", "t1", "T-1", ago(10*time.Hour))
	f.moved("t1", 5*time.Hour)
	f.kaneo.labels["t1"] = []string{"repo:testrepo"}

	req := httpGet("/reconcile")
	if w := serve(f, req); w.Code != http.StatusMethodNotAllowed || !strings.Contains(w.Body.String(), "POST with a signature") {
		t.Errorf("GET /reconcile = %d %q, want 405 saying how", w.Code, w.Body.String())
	}
	if w := f.post("/reconcile", ""); w.Code != http.StatusUnauthorized {
		t.Errorf("unsigned POST /reconcile = %d, want 401", w.Code)
	}
	if w := f.signed("/reconcile?dry=1", ""); w.Code != http.StatusAccepted {
		t.Errorf("signed dry POST = %d, want 202", w.Code)
	}
	f.wantLog(`msg="reconcile redispatch" card="T-1 (to-do, 5h) [dry-run]"`)
	f.wantNoLaunch()

	if w := f.signed("/reconcile", ""); w.Code != http.StatusAccepted {
		t.Errorf("signed POST = %d, want 202", w.Code)
	}
	f.wantLog("msg=\"reconcile done\" checked=1 redispatched=1 skipped=0 errors=0")
	if len(f.pods.launches()) != 1 {
		t.Error("a real sweep did not launch the stuck card's stage")
	}
}
