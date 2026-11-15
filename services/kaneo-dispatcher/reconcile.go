package main

// The safety net under event dispatch.
//
// Event dispatch has no retry. If a webhook fires and the work cannot
// start - the cluster API is down, the dispatcher is mid-restart, the pod
// is not ready - nothing ever picks it up again, and the card is left
// looking exactly like one nobody has touched. That is not hypothetical:
// CLA-11 was moved to To Do on 3 Nov while two nodes were down, the exec
// failed, and it sat there for five days.
//
// Nothing records "this was dispatched". A dispatch log would be a second
// source of truth that disagrees with reality - and would have died that
// night too. So this compares the column against the world instead, using
// only state that survives a restart: when the card entered its column,
// and whether the work that column implies actually exists on GitHub.
//
// The kaneo-reconcile CronJob posts to /reconcile on a clock; this is what
// runs then.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// sweep is what one reconcile pass found, as lines a human reads in the
// log. Returned rather than only logged, so the summary says what
// happened in one place.
type sweep struct {
	checked      int
	completed    []string
	redispatched []string
	skipped      []string
	errors       []string
}

// board is the part of /api/task/tasks/{project} the sweep reads.
type board struct {
	Data struct {
		Columns []struct {
			Slug  string `json:"slug"`
			Tasks []card `json:"tasks"`
		} `json:"columns"`
	} `json:"data"`
}

// strandedColumn is where the author leaves a card while it works. It
// moves the card first and works second, deliberately, so a death
// mid-ticket reads as attempted - which means an author that dies in
// between leaves In Progress holding a card that no column-watcher
// retries, because nothing dispatches FROM here. CLA-15 sat there for
// hours after a four-second crash.
//
// The remedy is a hand-back, not a decision: the author's own mode logic
// is the one authoritative copy of what a card in any state is owed
// (advance an unreviewed PR, rework a declined one, resume pushed-but-
// unPRed work, or start fresh), so a stale card here goes back to the
// author and nothing is decided in this file. An earlier draft advanced
// PR-carrying cards from here and got the policy wrong for rework and
// closed-PR cards within one review.
const strandedColumn = "in-progress"

// sweeps is the stage a swept column is owed, or ok false for an inert
// one. stranded marks a hand-back to the author after ruling out a
// merged PR. The author decides how to resume unfinished work.
func sweeps(column string) (st stage, stranded, ok bool) {
	if column == strandedColumn {
		return routes[authorColumn], true, true
	}
	st, ok = routes[column]
	return st, false, ok
}

// reconcile is one sweep over the columns that dispatch, plus the one
// the author strands cards in. The error is a board that could not be
// read at all; everything per card lands in the sweep's errors instead,
// so one bad card does not hide the rest.
func (d *dispatcher) reconcile(ctx context.Context, dryRun bool) (sweep, error) {
	var out sweep
	var b board
	if err := d.kaneo(ctx, "/task/tasks/"+url.PathEscape(d.project), &b); err != nil {
		return out, err
	}
	for _, col := range b.Data.Columns {
		if _, _, ok := sweeps(col.Slug); !ok && col.Slug != "needs-human-review" {
			continue // inert column: nothing was ever owed here
		}
		for _, c := range col.Tasks {
			out.checked++
			d.reconcileCard(ctx, col.Slug, c, dryRun, &out, b)
		}
	}
	return out, nil
}

// reconcileCard decides one card in a swept column: leave it, say why it
// was skipped, or start the work it is owed. Anything the sweep could not
// find out lands in errors, never in silence: an error here must not
// read as "nothing to do", because a card nobody can see is the failure
// this sweep exists for.
func (d *dispatcher) reconcileCard(ctx context.Context, column string, c card, dryRun bool, out *sweep, b board) {
	st, stranded, _ := sweeps(column)
	fail := func(err error) { out.errors = append(out.errors, c.name()+": "+err.Error()) }

	if column == "needs-human-review" {
		st = routes[authorColumn]
	}

	repo, skip, err := d.repoFor(ctx, c.ID, st)
	if err != nil {
		fail(err)
		return
	}
	if skip != "" {
		out.skipped = append(out.skipped, c.name()+": "+skip)
		return
	}
	pr, err := d.taskPullRequest(ctx, repo, c.ID)
	if err != nil {
		fail(err)
		return
	}
	if pr != nil && pr.MergedAt != nil {
		changed, err := d.completeMergedTask(ctx, c.ID, column, b, dryRun)
		if err != nil {
			fail(err)
			return
		}
		if !changed {
			out.skipped = append(out.skipped, c.name()+": card changed since board snapshot")
			return
		}
		line := fmt.Sprintf("%s: PR #%d merged; %s -> done", c.name(), pr.Number, column)
		if dryRun {
			line += " [dry-run]"
		}
		out.completed = append(out.completed, line)
		return
	}
	if column == "needs-human-review" {
		return
	}

	since, err := d.enteredColumnAt(ctx, c.ID)
	if err != nil {
		fail(err)
		return
	}
	if since.IsZero() {
		// No recorded move means the card was created straight into this
		// column and never moved, so no webhook ever fired for it. Treat
		// creation as the clock.
		if c.CreatedAt == "" {
			fail(fmt.Errorf("no recorded move and no createdAt, so nothing dates it"))
			return
		}
		since, err = time.Parse(time.RFC3339Nano, c.CreatedAt)
		if err != nil {
			fail(fmt.Errorf("createdAt %q: %w", c.CreatedAt, err))
			return
		}
	}
	age := time.Since(since)
	if age < d.stale {
		return // still within the window a real run could take
	}
	if !stranded {
		exists, err := d.workForPR(ctx, column, repo, pr)
		if err != nil {
			fail(err)
			return
		}
		if exists {
			// The work ran; the card is simply waiting on the next
			// stage, or on a human. Not ours to restart.
			out.skipped = append(out.skipped, c.name()+": work already exists")
			return
		}
	}
	line := fmt.Sprintf("%s (%s, %dh)", c.name(), column, int(age.Hours()))
	if dryRun {
		out.redispatched = append(out.redispatched, line+" [dry-run]")
		return
	}
	slog.Info("reconcile: stuck card, re-dispatching", "task", c.name(), "column", column, "since", since)
	// A wake or launch that failed is an error, not a redispatch: the
	// summary line is what a morning reads, and "redispatched 1" over a
	// card that never started is worse than silence.
	if err := d.runStage(ctx, repo, st, c); err != nil {
		if errors.Is(err, errPodBusy) {
			out.skipped = append(out.skipped, c.name()+": "+err.Error())
			return
		}
		fail(err)
		return
	}
	out.redispatched = append(out.redispatched, line)
}

// enteredColumnAt is when the card last changed column, or zero when it
// never has. The task object's updatedAt is null in this Kaneo build, so
// the activity feed is the only record of it.
func (d *dispatcher) enteredColumnAt(ctx context.Context, id string) (time.Time, error) {
	var acts []struct {
		Type      string `json:"type"`
		CreatedAt string `json:"createdAt"`
	}
	if err := d.kaneo(ctx, "/activity/"+url.PathEscape(id), &acts); err != nil {
		return time.Time{}, err
	}
	var latest time.Time
	for _, a := range acts {
		if a.Type != "status_changed" {
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, a.CreatedAt)
		if err != nil {
			return time.Time{}, fmt.Errorf("activity of %s: createdAt %q: %w", id, a.CreatedAt, err)
		}
		if t.After(latest) {
			latest = t
		}
	}
	return latest, nil
}

// workExists asks whether the work this column implies already happened.
//
// Asked of GitHub, not of Kaneo: a branch and a commit status survive
// everything this dispatcher does, and they are what the next stage reads
// anyway. If the answer is yes, the card is mid-flight and must be left
// alone - re-dispatching would run a second agent beside a live one.
func (d *dispatcher) workExists(ctx context.Context, column, repo, id string) (bool, error) {
	pr, err := d.taskPullRequest(ctx, repo, id)
	if err != nil {
		return false, err
	}
	return d.workForPR(ctx, column, repo, pr)
}

func (d *dispatcher) workForPR(ctx context.Context, column, repo string, pr *pullRequest) (bool, error) {
	if pr == nil {
		return false, nil
	}
	if pr.MergedAt != nil {
		return true, nil
	}
	owner, name, _ := strings.Cut(repo, "/")

	switch column {
	case authorColumn:
		// The author's job is to open a pull request. One exists -> it ran.
		return true, nil
	case "in-review":
		// The test pod's job is to post nightly/integration at the head.
		var status struct {
			Statuses []struct {
				Context string `json:"context"`
			} `json:"statuses"`
		}
		if err := d.github(ctx, fmt.Sprintf("/repos/%s/%s/commits/%s/status", owner, name, pr.Head.SHA), &status); err != nil {
			return false, err
		}
		for _, s := range status.Statuses {
			if s.Context == "nightly/integration" {
				return true, nil
			}
		}
		return false, nil
	case "mergeable":
		// The merge pod's job is to merge it, and it is not merged.
		return false, nil
	default:
		// A route with no completion check here would be swept as "done"
		// forever. Loud instead: it lands in the sweep's errors.
		return false, fmt.Errorf("no work check for column %q; see routes", column)
	}
}

// github GETs a path on the REST API with the token the pods push with.
// Without a token every call fails and the sweep can only report errors,
// which is the right shape: a missing token must read as "could not
// check", never as "no work exists".
func (d *dispatcher) github(ctx context.Context, p string, out any) error {
	return getJSON(ctx, d.client, d.githubURL+p, d.ghToken, out)
}

// runSweep is reconcile plus its log lines, for the handler that runs it
// after answering.
func (d *dispatcher) runSweep(ctx context.Context, dryRun bool) {
	s, err := d.reconcile(ctx, dryRun)
	if err != nil {
		slog.Error("reconcile failed", "err", err)
		return
	}
	slog.Info("reconcile done", "checked", s.checked,
		"completed", len(s.completed), "redispatched", len(s.redispatched), "skipped", len(s.skipped), "errors", len(s.errors))
	for _, line := range s.completed {
		slog.Info("reconcile complete", "card", line)
	}
	for _, line := range s.redispatched {
		slog.Info("reconcile redispatch", "card", line)
	}
	for _, line := range s.skipped {
		slog.Info("reconcile skip", "card", line)
	}
	for _, line := range s.errors {
		slog.Error("reconcile error", "card", line)
	}
}

// Only the newest PR from this repository and exact task branch can finish
// a card. Paginate so an old merge cannot hide a newer use of the branch.
type pullRequest struct {
	Number   int     `json:"number"`
	MergedAt *string `json:"merged_at"`
	Head     struct {
		SHA  string `json:"sha"`
		Ref  string `json:"ref"`
		Repo struct {
			FullName string `json:"full_name"`
		} `json:"repo"`
	} `json:"head"`
}

func (d *dispatcher) taskPullRequest(ctx context.Context, repo, id string) (*pullRequest, error) {
	owner, _, _ := strings.Cut(repo, "/")
	branch := d.branchPrefix + id
	var newest *pullRequest
	for page := 1; ; page++ {
		q := url.Values{"head": {owner + ":" + branch}, "state": {"all"}, "per_page": {"100"}, "page": {fmt.Sprint(page)}, "sort": {"created"}, "direction": {"desc"}}
		var prs []pullRequest
		if err := d.github(ctx, "/repos/"+repo+"/pulls?"+q.Encode(), &prs); err != nil {
			return nil, err
		}
		for _, pr := range prs {
			if pr.Head.Ref == branch && strings.EqualFold(pr.Head.Repo.FullName, repo) && (newest == nil || pr.Number > newest.Number) {
				copy := pr
				newest = &copy
			}
		}
		if len(prs) < 100 {
			return newest, nil
		}
	}
}

// Kaneo requires a full task PUT. Re-read first, preserve its fields, strip
// nulls as required by the API, and verify the result. There is no conditional
// update support, so a concurrent edit between GET and PUT remains possible.
func (d *dispatcher) completeMergedTask(ctx context.Context, id, column string, b board, dry bool) (bool, error) {
	done := 0
	for _, col := range b.Data.Columns {
		if col.Slug == "done" {
			done++
		}
	}
	if done != 1 {
		return false, fmt.Errorf("project must have exactly one Done column")
	}
	p := "/task/" + url.PathEscape(id)
	var task map[string]any
	if err := d.kaneo(ctx, p, &task); err != nil {
		return false, err
	}
	if task["id"] != id || task["projectId"] != d.project || task["status"] != column {
		return false, nil
	}
	if dry {
		return true, nil
	}
	for k, v := range task {
		if v == nil {
			delete(task, k)
		}
	}
	task["status"] = "done"
	raw, err := json.Marshal(task)
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, d.kaneoURL+"/api"+p, bytes.NewReader(raw))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+d.apiKey)
	req.Header.Set("Content-Type", "application/json")
	res, err := d.client.Do(req)
	if err != nil {
		return false, err
	}
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	if res.StatusCode/100 != 2 {
		return false, fmt.Errorf("cannot move merged task to Done: HTTP %d", res.StatusCode)
	}
	var updated struct {
		ProjectID string `json:"projectId"`
		Status    string `json:"status"`
	}
	if err := d.kaneo(ctx, p, &updated); err != nil {
		return false, err
	}
	if updated.ProjectID != d.project || updated.Status != "done" {
		return false, fmt.Errorf("merged task update did not leave the card in Done")
	}
	return true, nil
}
