// Binary kaneo-dispatcher turns a Kaneo card move into a pod run.
//
// Kaneo POSTs here whenever a task changes column, and the column it landed
// in decides what happens. Most columns decide nothing: see routes. That
// table IS the safety property - a pod moving a card to in-progress cannot
// re-trigger the author, because in-progress triggers nothing. There is no
// actor check anywhere here and none is needed: the pipeline flows one way,
// so the only way to make a cycle is for a human to drag a card backwards,
// which is a deliberate "do it again".
//
// Work starts when a card moves rather than at 00:00, and each stage hands
// to the next by moving the card. The suspended CronJobs in
// claude-pods/nightly-cronjobs.yaml are the fallback clock; the sweep in
// reconcile.go is the safety net under the events.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"time"
	"unicode"
)

// A stage is which pod runs which script when a card lands in a column.
type stage struct {
	pod    string
	script string
}

// routes maps a column slug to its stage. Anything not here is inert.
var routes = map[string]stage{
	"to-do":     {"claude-session-0", "/usr/local/bin/nightly-author"},
	"in-review": {"claude-session-2", "/usr/local/bin/nightly-test"},
	"mergeable": {"claude-session-1", "/usr/local/bin/nightly-merge"},
}

// The two commands this service ever runs in a session pod, both through
// `sh -c`. Named so the tests assert against the same strings the pod
// receives rather than retyping them.
const (
	// busyProbe asks whether a stage is already running. The scripts take
	// a lock themselves (take_pod_lock in nightly-common.sh), so what is
	// checked is what a run actually holds: flock -n succeeds only if
	// nothing holds it, so exit 0 means idle and anything else means busy.
	// The path expression is the scripts' own, NIGHTLY_LOCK override
	// included, so the two sides cannot lock different files.
	busyProbe = `flock -n "${NIGHTLY_LOCK:-/tmp/nightly.lock}" true`

	// launchLine starts a stage and returns at once. $0 is the script and
	// $1 the task id, passed as positional arguments rather than spliced
	// into the command text.
	//
	// setsid + nohup because a plain exec ties the run's life to the
	// connection: the API server, a dispatcher restart, a rollout, or a
	// network blip kills the agent mid-ticket. An author run takes up to
	// an hour, so that window is most of the run. The first real dispatch
	// died this way within seconds of starting.
	launchLine = `setsid nohup "$0" "$1" >/dev/null 2>&1 </dev/null &`
)

// execer runs argv in a session pod and reports its exit code. An error
// means the command could not be run at all - the API server was
// unreachable, the pod is gone - which is a different thing from it
// running and exiting non-zero, and the callers treat the two
// differently.
type execer func(ctx context.Context, pod string, argv []string) (int, error)

// A dispatcher holds what one deployment of this service was configured
// with. Everything is read once at startup: the secrets arrive as
// environment variables, and the Deployment is annotated to restart when
// the Secret behind them changes, so a rotated credential reaches a
// running pod by replacing it.
type dispatcher struct {
	owner        string // GitHub owner a short repo: label resolves under
	branchPrefix string // a stage branches from the task id; the sweep looks it up
	project      string // the Kaneo project the sweep reads
	kaneoURL     string
	githubURL    string
	apiKey       string // Kaneo: reads a card's labels, and the board
	secret       []byte // the HMAC key Kaneo signs deliveries with
	ghToken      string
	repos        map[string]string // pod ordinal -> the repos it works
	stale        time.Duration     // how long a card may sit before the sweep asks why
	exec         execer
	client       *http.Client

	// inflight counts work started after a 202 was already sent, which
	// is everything that talks to Kaneo, GitHub or a pod. Tests wait on
	// it; nothing else does, because a launched run is detached in the
	// pod and outlives this process anyway.
	inflight sync.WaitGroup
}

// fromEnv is the production configuration.
func fromEnv() (*dispatcher, error) {
	// Refused at startup rather than at the first delivery: without
	// either of these the pod is healthy, answers every delivery, and
	// never runs anything - a 401 to each one without the secret, a
	// "cannot read labels" for each one without the key. A crash loop is
	// visible; that is not.
	secret := os.Getenv("KANEO_WEBHOOK_SECRET")
	if secret == "" {
		return nil, fmt.Errorf("KANEO_WEBHOOK_SECRET is not set; every delivery would be refused")
	}
	apiKey := os.Getenv("KANEO_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("KANEO_API_KEY is not set; no card's label could be read")
	}
	stale := 4 * time.Hour
	if s := os.Getenv("RECONCILE_STALE"); s != "" {
		var err error
		if stale, err = time.ParseDuration(s); err != nil {
			return nil, fmt.Errorf("RECONCILE_STALE: %w", err)
		}
	}
	exec, err := newPodExec(envOr("DISPATCH_NS", "claude-pods"))
	if err != nil {
		return nil, err
	}
	return &dispatcher{
		// Same defaults and same variables as nightly-common.sh, so a
		// short repo: label and a branch name resolve the same way here
		// as in the scripts.
		owner:        envOr("NIGHTLY_OWNER", "ChristopherScot"),
		branchPrefix: envOr("KANEO_BRANCH_PREFIX", "fix/"),
		project:      envOr("KANEO_PROJECT_ID", "pwz0urubiajnchag39tcbjkl"), // the claude-pods board; config.yaml sets it
		kaneoURL:     envOr("KANEO_API_URL", "http://kaneo.kaneo.svc.cluster.local:5173"),
		githubURL:    envOr("GITHUB_API_URL", "https://api.github.com"),
		apiKey:       apiKey,
		secret:       []byte(secret),
		// GITHUB_TOKEN is deliberately not required: only the sweep uses
		// it, and the webhook path must not depend on it. See github().
		ghToken: os.Getenv("GITHUB_TOKEN"),
		repos:   reposFromEnv(os.Environ()),
		stale:   stale,
		exec:    exec,
		client:  &http.Client{Timeout: 30 * time.Second},
	}, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// reposFromEnv reads REPOS_POD<n> into a map keyed by <n>. The variables
// come from the Vault-backed secret, one per session pod; a pod with no
// entry is not refused anything, see podWorksRepo.
func reposFromEnv(environ []string) map[string]string {
	out := map[string]string{}
	for _, kv := range environ {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if n, found := strings.CutPrefix(k, "REPOS_POD"); found {
			out[n] = v
		}
	}
	return out
}

// card is a task as both the webhook and the board describe it.
type card struct {
	// ID is the raw task id. It is what a stage is handed, so it is what
	// names the branch (fix/<ID>) and what the sweep looks up on GitHub:
	// PR #98 is on fix/d3kgbstyuu5mmygqtorppai2, not fix/CLA-13.
	ID string `json:"id"`
	// TicketID is the CLA-13 a human reads. Display only - the webhook
	// payload does not even carry it.
	TicketID string `json:"ticketId"`
	// CreatedAt is the sweep's clock for a card that was never moved.
	CreatedAt string `json:"createdAt"`
}

// label is what the log calls the card.
func (c card) label() string {
	if c.TicketID != "" {
		return c.TicketID
	}
	if c.ID != "" {
		return c.ID
	}
	return "?"
}

// delivery is the part of a Kaneo webhook payload this reads. The task
// object carries only id, number, title, status, statusName, priority and
// url - no labels, which is why repoForTask asks the API instead.
type delivery struct {
	Event string `json:"event"`
	Task  card   `json:"task"`
	Data  struct {
		NewStatus string `json:"newStatus"`
	} `json:"data"`
}

// webhook is what Kaneo posts to when a card changes column.
func (d *dispatcher) webhook(w http.ResponseWriter, r *http.Request) {
	raw, ok := d.verifiedBody(w, r)
	if !ok {
		return
	}
	// Answer before doing the work: Kaneo records delivery health, and a
	// response that waits on a pod run would read as a failed delivery.
	w.WriteHeader(http.StatusAccepted)

	var ev delivery
	if err := json.Unmarshal(raw, &ev); err != nil {
		slog.Warn("reject", "reason", "unparseable body", "err", err)
		return
	}
	if ev.Event != "task.status_changed" {
		slog.Info("ignore", "event", ev.Event)
		return
	}
	column := ev.Data.NewStatus
	st, ok := routes[column]
	if !ok {
		// Inert columns are logged, not dropped: this is the audit trail
		// of every card movement, Chris's included.
		slog.Info("noop", "task", ev.Task.label(), "column", column)
		return
	}
	if ev.Task.ID == "" {
		slog.Warn("skip", "task", ev.Task.label(), "column", column, "reason", "payload names no task id")
		return
	}
	// The 202 has gone, so from here the work is genuinely asynchronous.
	// Detached from the request's cancellation, which fires when this
	// handler returns, but not from its values.
	ctx := context.WithoutCancel(r.Context())
	d.inflight.Add(1)
	go func() {
		defer d.inflight.Done()
		d.dispatch(ctx, column, st, ev.Task)
	}()
}

// dispatch runs the stage a column implies for one card, or logs one line
// saying why not.
func (d *dispatcher) dispatch(ctx context.Context, column string, st stage, c card) {
	repo, skip, err := d.repoFor(ctx, c.ID, st.pod)
	if err != nil {
		slog.Error("cannot read labels", "task", c.label(), "column", column, "err", err)
		return
	}
	if skip != "" {
		slog.Warn("skip", "task", c.label(), "column", column, "reason", skip)
		return
	}
	d.runStage(ctx, repo, st, c)
}

// repoFor is the repo a card's stage should run against, or the one-line
// reason it should not run at all. The two reasons are the same for the
// webhook and the sweep, so they are decided here and only worded here.
//
// An error is a Kaneo lookup that failed, which must not read as "no
// label": saying so keeps a Kaneo outage from looking like a board full
// of unlabelled cards.
func (d *dispatcher) repoFor(ctx context.Context, id, pod string) (repo, skip string, err error) {
	repo, err = d.repoForTask(ctx, id)
	if err != nil {
		return "", "", err
	}
	if repo == "" {
		return "", "card needs exactly one repo: label", nil
	}
	if !d.podWorksRepo(pod, repo) {
		return "", pod + " does not work " + repo, nil
	}
	return repo, "", nil
}

// runStage launches the stage in its pod unless a run is already there.
func (d *dispatcher) runStage(ctx context.Context, repo string, st stage, c card) {
	if d.podIsBusy(ctx, st.pod) {
		// Dropped rather than queued: the card stays where it is, so
		// moving it again once the current run finishes is the retry. A
		// queue here would silently stack up work nobody asked for twice.
		slog.Warn("busy", "task", c.label(), "repo", repo, "pod", st.pod, "hint", "move the card again later")
		return
	}
	slog.Info("start", "task", c.label(), "repo", repo, "pod", st.pod, "script", path.Base(st.script))
	// Bounded like the busy check. The shell returns as soon as the run is
	// backgrounded, so a launch that takes this long is a stream that
	// hung, and cancelling it cannot reach the detached run anyway.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	rc, err := d.exec(ctx, st.pod, []string{"sh", "-c", launchLine, st.script, c.ID})
	if err != nil {
		slog.Error("launch failed", "task", c.label(), "repo", repo, "err", err)
		return
	}
	// "launched", not "finished": the run is detached and outlives this.
	// The log in the pod and the card are where the outcome lives.
	slog.Info("launched", "task", c.label(), "repo", repo, "rc", rc)
}

// podIsBusy reports whether a stage is already running in this pod, or
// whether that could not be determined - which counts as busy. Starting
// a second agent on a live clone is the one thing this guard exists to
// prevent, so an unanswered question must not read as idle.
//
// Asked of the pod, not of this process: the run is detached, so anything
// remembered here would clear the moment the launch returned, and would
// not survive a restart either. See busyProbe.
func (d *dispatcher) podIsBusy(ctx context.Context, pod string) bool {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	rc, err := d.exec(ctx, pod, []string{"sh", "-c", busyProbe})
	if err != nil {
		slog.Warn("cannot tell whether pod is busy; assuming it is", "pod", pod, "err", err)
		return true
	}
	return rc != 0
}

// podWorksRepo reports whether a pod works this repo at all.
//
// routes picks a pod by column, but which repos a pod acts on is decided
// separately, by the per-pod list the session pods themselves read.
// Dispatching a repo that is not on that list runs a full job that scans
// the wrong set and exits having done nothing - a silent no-op that reads
// as a successful run. Checking here turns that into one line saying why.
//
// A pod with no list at all is refused nothing: the scripts filter by
// repo themselves, so this check only buys the better log line, and a
// missing entry says the operator has not opted that pod in rather than
// that it works nothing. An entry that is present but empty does mean
// "works nothing", and refuses everything.
func (d *dispatcher) podWorksRepo(pod, repo string) bool {
	n := pod[strings.LastIndex(pod, "-")+1:]
	list, ok := d.repos[n]
	if !ok {
		return true
	}
	isSep := func(c rune) bool { return c == ',' || unicode.IsSpace(c) }
	for _, r := range strings.FieldsFunc(list, isSep) {
		if r == repo {
			return true
		}
	}
	return false
}

// repoForTask is the repo a card is for, as owner/name, from its
// repo:<name> label. A label without an owner resolves under the default
// one, the same way the scripts resolve it; this is the one place that
// happens, so every later comparison and lookup sees the same string.
//
// It returns "" when the card does not carry exactly one repo: label, and
// an error when the lookup itself failed.
func (d *dispatcher) repoForTask(ctx context.Context, id string) (string, error) {
	// /api/label/task/{id}, not /api/task/{id}: the task endpoint does not
	// return labels at all.
	var labels []struct {
		Name string `json:"name"`
	}
	if err := d.kaneo(ctx, "/label/task/"+url.PathEscape(id), &labels); err != nil {
		return "", err
	}
	var repos []string
	for _, l := range labels {
		if r, ok := strings.CutPrefix(l.Name, "repo:"); ok {
			if !strings.Contains(r, "/") {
				r = d.owner + "/" + r
			}
			repos = append(repos, r)
		}
	}
	if len(repos) != 1 {
		return "", nil
	}
	return repos[0], nil
}

// kaneo GETs a path under /api and decodes the JSON it returns.
func (d *dispatcher) kaneo(ctx context.Context, p string, out any) error {
	return getJSON(ctx, d.client, d.kaneoURL+"/api"+p, d.apiKey, out)
}

// getJSON fetches one JSON document with a bearer token. A non-2xx answer
// is an error; so is a body that does not decode into out - a typed
// decode is what turns `{"error": ...}` with a 200 into a parse failure
// rather than a silently empty value.
func getJSON(ctx context.Context, client *http.Client, u, bearer string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	// Drained so the connection is reusable: the sweep makes several
	// calls per card against the same two hosts.
	defer func() {
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
	}()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("GET %s: unexpected status %d", req.URL.Path, res.StatusCode)
	}
	if err := json.NewDecoder(res.Body).Decode(out); err != nil {
		return fmt.Errorf("GET %s: %w", req.URL.Path, err)
	}
	return nil
}
