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
	Checked      int
	Redispatched []string
	Skipped      []string
	Errors       []string
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

type card struct {
	ID        string `json:"id"`
	TicketID  string `json:"ticketId"`
	CreatedAt string `json:"createdAt"`
}

// reconcile is one sweep over the columns that dispatch. The error is a
// board that could not be read at all; everything per card lands in the
// sweep's Errors instead, so one bad card does not hide the rest.
func (d *dispatcher) reconcile(ctx context.Context, dryRun bool) (sweep, error) {
	var out sweep
	var b board
	if err := d.kaneo(ctx, "/task/tasks/"+url.PathEscape(d.project), &b); err != nil {
		return out, err
	}
	now := time.Now()
	for _, col := range b.Data.Columns {
		st, ok := routes[col.Slug]
		if !ok {
			continue // inert column: nothing was ever owed here
		}
		for _, c := range col.Tasks {
			out.Checked++
			d.reconcileCard(ctx, col.Slug, st, c, now, dryRun, &out)
		}
	}
	return out, nil
}

// reconcileCard decides one card: leave it, report why it was skipped, or
// start the work it is owed.
func (d *dispatcher) reconcileCard(ctx context.Context, column string, st stage, c card, now time.Time, dryRun bool, out *sweep) {
	// The raw task id drives branch lookups; the ticket id is only ever
	// for the log line, where a human reads it. The branch is built from
	// whatever the dispatcher hands the stage, and that is the task id:
	// PR #98 is on fix/d3kgbstyuu5mmygqtorppai2, not fix/CLA-13.
	// Searching for the ticket id's branch would find nothing, conclude
	// the work never happened, and re-dispatch a finished card.
	label := cardLabel(c.TicketID, c.ID)
	fail := func(err error) { out.Errors = append(out.Errors, label+": "+err.Error()) }

	since, err := d.enteredColumnAt(ctx, c.ID)
	if err != nil {
		// An error here must not read as "nothing to do". Report it and
		// leave the card alone.
		fail(err)
		return
	}
	if since.IsZero() {
		// No recorded move means the card was created straight into this
		// column and never moved, so no webhook ever fired for it. Treat
		// creation as the clock.
		since, _ = time.Parse(time.RFC3339Nano, c.CreatedAt)
	}
	if since.IsZero() || now.Sub(since) < d.stale {
		return // still within the window a real run could take
	}
	repo, err := d.repoForTask(ctx, c.ID)
	if err != nil {
		fail(err)
		return
	}
	if repo == "" {
		out.Skipped = append(out.Skipped, label+": no single repo: label")
		return
	}
	if !d.podWorksRepo(st.pod, repo) {
		out.Skipped = append(out.Skipped, fmt.Sprintf("%s: %s does not work %s", label, st.pod, repo))
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
		out.Skipped = append(out.Skipped, label+": work already exists")
		return
	}
	age := fmt.Sprintf("%s, %dh", column, int(now.Sub(since).Hours()))
	if dryRun {
		out.Redispatched = append(out.Redispatched, fmt.Sprintf("%s (%s) [dry-run]", label, age))
		return
	}
	slog.Info("reconcile: stuck card, re-dispatching", "task", label, "column", column, "since", since)
	d.runStage(ctx, repo, st, c.ID, label)
	out.Redispatched = append(out.Redispatched, fmt.Sprintf("%s (%s)", label, age))
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
		if t, err := time.Parse(time.RFC3339Nano, a.CreatedAt); err == nil && t.After(latest) {
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
	name := repo[strings.LastIndex(repo, "/")+1:]
	q := url.Values{
		"head":     {d.owner + ":" + d.branchPrefix + id},
		"state":    {"all"},
		"per_page": {"1"},
	}
	var prs []struct {
		MergedAt *string `json:"merged_at"`
		Head     struct {
			SHA string `json:"sha"`
		} `json:"head"`
	}
	if err := d.github(ctx, fmt.Sprintf("/repos/%s/%s/pulls?%s", d.owner, name, q.Encode()), &prs); err != nil {
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
		if err := d.github(ctx, fmt.Sprintf("/repos/%s/%s/commits/%s/status", d.owner, name, pr.Head.SHA), &st); err != nil {
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
	slog.Info("reconcile done", "checked", s.Checked,
		"redispatched", len(s.Redispatched), "skipped", len(s.Skipped), "errors", len(s.Errors))
	for _, line := range s.Redispatched {
		slog.Info("reconcile redispatch", "card", line)
	}
	for _, line := range s.Skipped {
		slog.Info("reconcile skip", "card", line)
	}
	for _, line := range s.Errors {
		slog.Error("reconcile error", "card", line)
	}
}
