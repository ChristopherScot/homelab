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
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"strings"
	"time"
)

// sweep is what one reconcile pass found, as lines a human reads in the
// log. Returned rather than only logged, so the summary says what
// happened in one place.
type sweep struct {
	checked      int
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

// reconcile is one sweep over the columns that dispatch. The error is a
// board that could not be read at all; everything per card lands in the
// sweep's errors instead, so one bad card does not hide the rest.
func (d *dispatcher) reconcile(ctx context.Context, dryRun bool) (sweep, error) {
	var out sweep
	var b board
	if err := d.kaneo(ctx, "/task/tasks/"+url.PathEscape(d.project), &b); err != nil {
		return out, err
	}
	for _, col := range b.Data.Columns {
		if _, ok := routes[col.Slug]; !ok {
			continue // inert column: nothing was ever owed here
		}
		for _, c := range col.Tasks {
			out.checked++
			d.reconcileCard(ctx, col.Slug, c, dryRun, &out)
		}
	}
	return out, nil
}

// reconcileCard decides one card in a dispatching column: leave it, say
// why it was skipped, or start the work it is owed. Every uncertain
// answer lands in errors: an error here must not read as "nothing to do",
// because a card nobody can see is the failure this sweep exists for.
func (d *dispatcher) reconcileCard(ctx context.Context, column string, c card, dryRun bool, out *sweep) {
	st := routes[column]
	fail := func(err error) { out.errors = append(out.errors, c.label()+": "+err.Error()) }

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
			out.skipped = append(out.skipped, c.label()+": no move and no createdAt, so no clock")
			return
		}
		if since, err = time.Parse(time.RFC3339Nano, c.CreatedAt); err != nil {
			fail(fmt.Errorf("createdAt %q: %w", c.CreatedAt, err))
			return
		}
	}
	age := time.Since(since)
	if age < d.stale {
		return // still within the window a real run could take
	}
	repo, skip, err := d.repoFor(ctx, c.ID, st.pod)
	if err != nil {
		fail(err)
		return
	}
	if skip != "" {
		out.skipped = append(out.skipped, c.label()+": "+skip)
		return
	}
	exists, err := d.workExists(ctx, column, repo, c.ID)
	if err != nil {
		fail(err)
		return
	}
	if exists {
		// The work ran; the card is simply waiting on the next stage, or
		// on a human. Not ours to restart.
		out.skipped = append(out.skipped, c.label()+": work already exists")
		return
	}
	line := fmt.Sprintf("%s (%s, %dh)", c.label(), column, int(age.Hours()))
	if dryRun {
		out.redispatched = append(out.redispatched, line+" [dry-run]")
		return
	}
	slog.Info("reconcile: stuck card, re-dispatching", "task", c.label(), "column", column, "since", since)
	d.runStage(ctx, repo, st, c)
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
	owner, name, _ := strings.Cut(repo, "/") // always owner/name, see repoForTask
	q := url.Values{
		"head":     {owner + ":" + d.branchPrefix + id},
		"state":    {"all"},
		"per_page": {"1"},
	}
	var prs []struct {
		MergedAt *string `json:"merged_at"`
		Head     struct {
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := d.github(ctx, fmt.Sprintf("/repos/%s/%s/pulls?%s", owner, name, q.Encode()), &prs); err != nil {
		return false, err
	}
	if len(prs) == 0 {
		// to-do's author opens the pull request; in-review and mergeable
		// act on one. With none, none of them has run.
		return false, nil
	}
	pr := prs[0]
	// A merged pull request ends the card's story whatever column it is
	// sitting in. CLA-13 was merged by hand while in In Review and carries
	// no nightly/integration status, so the in-review check below would
	// have called it unfinished and re-dispatched the test stage against
	// work that is already on main.
	if pr.MergedAt != nil {
		return true, nil
	}
	switch column {
	case "to-do":
		// The author's job is to open a pull request. One exists -> it ran.
		return true, nil
	case "in-review":
		// The test pod's job is to post nightly/integration at the head.
		var st struct {
			Statuses []struct {
				Context string `json:"context"`
			} `json:"statuses"`
		}
		if err := d.github(ctx, fmt.Sprintf("/repos/%s/%s/commits/%s/status", owner, name, pr.Head.SHA), &st); err != nil {
			return false, err
		}
		for _, s := range st.Statuses {
			if s.Context == "nightly/integration" {
				return true, nil
			}
		}
		return false, nil
	case "mergeable":
		// The merge pod's job is to merge it, and it is not merged.
		return false, nil
	default:
		return true, nil
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
		"redispatched", len(s.redispatched), "skipped", len(s.skipped), "errors", len(s.errors))
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
