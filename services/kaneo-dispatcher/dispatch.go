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
// to the next by moving the card. The CronJobs that ran the stages on a
// clock were removed 2026-11-10; there is no fallback clock, and the sweep
// in reconcile.go is the safety net under the events.
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
	"slices"
	"strconv"
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
//
// The column set is known in three other places, and a new route has to
// reach all of them: workExists in reconcile.go says what finished work
// looks like for the column, the graph in claude-pods/lib/pod-common.sh
// says which columns the scripts may move a card to, and the README
// describes the pipeline.
var routes = map[string]stage{
	"to-do":     {"claude-session-0", "/usr/local/bin/stage-author"},
	"in-review": {"claude-session-2", "/usr/local/bin/stage-test"},
	"mergeable": {"claude-session-1", "/usr/local/bin/stage-merge"},
}

// wakeReplicas is one past the highest ordinal routes names: stages are
// pinned to pods by ordinal and a StatefulSet cannot run ordinal 2
// without 0 and 1. Derived so a fourth stage is one edit, not two.
func wakeReplicas() int {
	n := 0
	for _, st := range routes {
		n = max(n, ordinal(st.pod)+1)
	}
	return n
}

// ordinal is the <n> in claude-session-<n>, as the StatefulSet counts.
func ordinal(pod string) int {
	n, _ := strconv.Atoi(pod[strings.LastIndex(pod, "-")+1:])
	return n
}

// The two commands this service ever runs in a session pod, both through
// `sh -c`. Named so the tests assert against the same strings the pod
// receives rather than retyping them.
const (
	// busyProbe asks whether a stage is already running. The scripts take
	// a lock themselves (take_pod_lock in pod-common.sh), so what is
	// probed is what a run actually holds: flock -n succeeds only if
	// nothing holds it, so exit 0 means idle and anything else means busy.
	// The path expression is the scripts' own, NIGHTLY_LOCK override
	// included, so the two sides cannot lock different files.
	busyProbe = `flock -n "${NIGHTLY_LOCK:-/tmp/nightly.lock}" true`

	// launchLine starts a stage and returns at once. $0 is the script, $1
	// the task id and $2 the repo, passed as positional arguments rather
	// than spliced into the command text. The repo rides along so a named
	// task is workable from ANY column without the stage re-resolving
	// labels - stage-author refuses a task without it.
	//
	// setsid + nohup because a plain exec ties the run's life to the
	// connection: the API server, a dispatcher restart, a rollout, or a
	// network blip kills the agent mid-ticket. An author run takes up to
	// an hour, so that window is most of the run. The first real dispatch
	// died this way within seconds of starting.
	launchLine = `setsid nohup "$0" "$1" "$2" >/dev/null 2>&1 </dev/null &`
)

// wakeTimeout bounds a wake. A cold start legitimately takes minutes -
// three pods pulling a 1.4 GB image - but one that cannot finish must
// become a logged failure for the card, not a goroutine held forever.
const wakeTimeout = 10 * time.Minute

// execer runs argv in a session pod and reports its exit code. An error
// means the command could not be run at all - the API server was
// unreachable, the pod is gone - which is a different thing from it
// running and exiting non-zero, and the callers treat the two
// differently.
type execer func(ctx context.Context, pod string, argv []string) (int, error)

// waker scales the session StatefulSet up to wakeReplicas and returns
// once every pod is ready, or with the reason it could not.
type waker func(ctx context.Context) error

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
	repos        map[string][]string // pod ordinal -> the owner/name repos it works
	stale        time.Duration       // how long a card may sit before the sweep asks why
	exec         execer
	wake         waker
	client       *http.Client

	// inflight counts work started after a 202 was already sent, which
	// is everything that talks to Kaneo, GitHub or a pod. main drains it
	// on shutdown and the tests wait on it; a launched run is detached in
	// the pod and outlives this process either way.
	inflight sync.WaitGroup
}

// fromEnv is the production configuration.
func fromEnv() (*dispatcher, error) {
	// Refused at startup rather than at the first use: without any of
	// these the pod is healthy, answers every delivery, and never does the
	// right thing - a 401 to each one without the secret, a "cannot read
	// labels" for each one without the key, the wrong board for the sweep
	// without the project. A crash loop is visible; that is not.
	var missing []string
	need := func(key string) string {
		v := os.Getenv(key)
		if v == "" {
			missing = append(missing, key)
		}
		return v
	}
	secret := need("KANEO_WEBHOOK_SECRET")
	apiKey := need("KANEO_API_KEY")
	project := need("KANEO_PROJECT_ID")
	if len(missing) > 0 {
		return nil, fmt.Errorf("%s not set; see config.yaml", strings.Join(missing, ", "))
	}
	stale := 4 * time.Hour
	if s := os.Getenv("RECONCILE_STALE"); s != "" {
		var err error
		stale, err = time.ParseDuration(s)
		if err != nil {
			return nil, fmt.Errorf("RECONCILE_STALE: %w", err)
		}
	}
	exec, wake, err := newPodClient(envOr("DISPATCH_NS", "claude-pods"))
	if err != nil {
		return nil, err
	}
	return &dispatcher{
		// Same defaults and same variables as pod-common.sh, so a short
		// repo: label and a branch name resolve the same way here as in
		// the scripts.
		owner:        envOr("NIGHTLY_OWNER", "ChristopherScot"),
		branchPrefix: envOr("KANEO_BRANCH_PREFIX", "fix/"),
		project:      project,
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
		wake:    wake,
		client:  &http.Client{Timeout: 30 * time.Second},
	}, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// reposFromEnv reads REPOS_POD<n> into lists keyed by <n>. The variables
// come from the Vault-backed secret, one per session pod, as the same
// comma or whitespace separated owner/name list the pods themselves read.
func reposFromEnv(environ []string) map[string][]string {
	isSep := func(c rune) bool { return c == ',' || unicode.IsSpace(c) }
	out := map[string][]string{}
	for _, kv := range environ {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if n, found := strings.CutPrefix(k, "REPOS_POD"); found {
			out[n] = strings.FieldsFunc(v, isSep)
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

// name is what the log calls the card.
func (c card) name() string {
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
		slog.Info("noop", "task", ev.Task.name(), "column", column)
		return
	}
	if ev.Task.ID == "" {
		slog.Warn("skip", "task", ev.Task.name(), "column", column, "reason", "payload names no task id")
		return
	}
	d.detach(r, func(ctx context.Context) { d.dispatch(ctx, column, st, ev.Task) })
}

// detach runs work after the response has gone. The context keeps the
// request's values but not its cancellation, which fires the moment the
// handler returns - before the work has made its first call.
func (d *dispatcher) detach(r *http.Request, work func(ctx context.Context)) {
	ctx := context.WithoutCancel(r.Context())
	d.inflight.Go(func() { work(ctx) })
}

// dispatch runs the stage a column implies for one card, or logs one line
// saying why not.
func (d *dispatcher) dispatch(ctx context.Context, column string, st stage, c card) {
	repo, skip, err := d.repoFor(ctx, c.ID, st.pod)
	if err != nil {
		slog.Error("cannot read labels", "task", c.name(), "column", column, "err", err)
		return
	}
	if skip != "" {
		slog.Warn("skip", "task", c.name(), "column", column, "reason", skip)
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
	repo, ok, err := d.repoForTask(ctx, id)
	if err != nil {
		return "", "", err
	}
	if !ok {
		return "", "card needs exactly one repo: label", nil
	}
	if !d.podWorksRepo(pod, repo) {
		return "", pod + " does not work " + repo, nil
	}
	return repo, "", nil
}

// runStage wakes the session pods and launches the stage in its pod,
// unless a run is already there.
func (d *dispatcher) runStage(ctx context.Context, repo string, st stage, c card) {
	// The set sleeps at 0 replicas when idle; the session-sleep CronJob in
	// claude-pods/ puts it there and this is the matching wake. Always
	// every pod, never just the stage's: a StatefulSet cannot run ordinal
	// 2 without 0 and 1. A wake that fails is logged per card and the
	// card stays where it is; the sweep is the retry, priced honestly -
	// hourly, and only once the card is RECONCILE_STALE old - so a dropped
	// wake costs hours, not forever.
	if err := d.ensureAwake(ctx); err != nil {
		slog.Error("wake failed", "task", c.name(), "repo", repo, "err", err)
		return
	}
	if d.podIsBusy(ctx, st.pod) {
		// Dropped rather than queued: the card stays where it is, so
		// moving it again once the current run finishes is the retry. A
		// queue here would silently stack up work nobody asked for twice.
		slog.Warn("busy", "task", c.name(), "repo", repo, "pod", st.pod, "hint", "move the card again later")
		return
	}
	slog.Info("start", "task", c.name(), "repo", repo, "pod", st.pod, "script", path.Base(st.script))
	// Bounded like the busy probe. The shell returns as soon as the run is
	// backgrounded, so a launch that takes this long is a stream that
	// hung, and cancelling it cannot reach the detached run anyway.
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	rc, err := d.exec(ctx, st.pod, []string{"sh", "-c", launchLine, st.script, c.ID, repo})
	if err != nil {
		slog.Error("launch failed", "task", c.name(), "repo", repo, "err", err)
		return
	}
	// "launched", not "finished": the run is detached and outlives this.
	// The log in the pod and the card are where the outcome lives.
	slog.Info("launched", "task", c.name(), "repo", repo, "rc", rc)
}

// ensureAwake is the wake, bounded. Not held in memory between calls:
// scaling an awake set to its own size is a no-op, so asking every time
// costs one read and can never disagree with the cluster.
func (d *dispatcher) ensureAwake(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, wakeTimeout)
	defer cancel()
	return d.wake(ctx)
}

// podIsBusy reports whether a stage is already running in this pod, or
// whether that could not be determined - which counts as busy, because
// an unanswered question must not start a second agent on a live clone.
//
// Advisory: the probe and the launch are two execs, so two dispatchers
// can both see idle. The atomic refusal is take_pod_lock in the script
// itself; this buys the `busy` log line and saves starting a run that
// would exit at once. Asked of the pod, not of this process: the run is
// detached, so anything remembered here would clear the moment the
// launch returned, and would not survive a restart either.
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
	return slices.Contains(list, repo)
}

// repoForTask is the repo a card is for, as owner/name, from its
// repo:<name> label. A label without an owner resolves under the default
// one, the same way the scripts resolve it; this is the one place that
// happens, so every later comparison and lookup sees the same string.
//
// ok is false when the card does not carry exactly one repo: label. An
// error is a lookup that failed, which is a different thing.
func (d *dispatcher) repoForTask(ctx context.Context, id string) (repo string, ok bool, err error) {
	// /api/label/task/{id}, not /api/task/{id}: the task endpoint does not
	// return labels at all.
	var labels []struct {
		Name string `json:"name"`
	}
	if err := d.kaneo(ctx, "/label/task/"+url.PathEscape(id), &labels); err != nil {
		return "", false, err
	}
	var repos []string
	for _, l := range labels {
		if r, found := strings.CutPrefix(l.Name, "repo:"); found {
			if !strings.Contains(r, "/") {
				r = d.owner + "/" + r
			}
			repos = append(repos, r)
		}
	}
	if len(repos) != 1 {
		return "", false, nil
	}
	return repos[0], true, nil
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
	// calls per card against the same two hosts. Neither error can change
	// what Decode has already returned by the time this runs.
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
