package main

// Turns a Kaneo card move into a pod run.
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
// claude-pods/nightly-cronjobs.yaml are the fallback clock.

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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

// execer runs argv in a session pod and reports its exit code. An error
// means the command could not be run at all - the API server was
// unreachable, the pod is gone - which is a different thing from it
// running and exiting non-zero, and the callers treat the two
// differently.
type execer func(ctx context.Context, pod string, argv []string) (int, error)

// maxBody bounds a delivery. A task.status_changed payload is a few KB;
// 1 MiB is generous.
const maxBody = 1 << 20

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

	// inflight counts work started after a 202 was already sent. Tests
	// wait on it; nothing else does, because a launched run is detached
	// in the pod and outlives this process anyway.
	inflight sync.WaitGroup
}

// fromEnv is the production configuration.
func fromEnv() (*dispatcher, error) {
	secret := os.Getenv("KANEO_WEBHOOK_SECRET")
	if secret == "" {
		// Louder than the alternative, which is a healthy pod that answers
		// 401 to every delivery and reports nothing.
		return nil, fmt.Errorf("KANEO_WEBHOOK_SECRET is not set; every delivery would be refused")
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
		// Same default and same variable as nightly-common.sh, so a short
		// repo: label resolves to the same full name here as in the scripts.
		owner:        envOr("NIGHTLY_OWNER", "ChristopherScot"),
		branchPrefix: envOr("KANEO_BRANCH_PREFIX", "fix/"),
		project:      envOr("KANEO_PROJECT_ID", "pwz0urubiajnchag39tcbjkl"),
		kaneoURL:     envOr("KANEO_API_URL", "http://kaneo.kaneo.svc.cluster.local:5173"),
		githubURL:    envOr("GITHUB_API_URL", "https://api.github.com"),
		apiKey:       os.Getenv("KANEO_API_KEY"),
		secret:       []byte(secret),
		ghToken:      os.Getenv("GITHUB_TOKEN"),
		repos:        reposFromEnv(os.Environ()),
		stale:        stale,
		exec:         exec,
		client:       &http.Client{Timeout: 30 * time.Second},
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
		if n, found := strings.CutPrefix(k, "REPOS_POD"); ok && found {
			out[n] = v
		}
	}
	return out
}

// verify checks Kaneo's HMAC-SHA256 over the exact bytes it sent.
func (d *dispatcher) verify(body []byte, sigHex string) bool {
	if len(d.secret) == 0 || sigHex == "" {
		return false
	}
	got, err := hex.DecodeString(sigHex)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, d.secret)
	mac.Write(body)
	// hmac.Equal is constant-time and length-safe, so a wrong-length
	// signature is simply false rather than a server error.
	return hmac.Equal(got, mac.Sum(nil))
}

// signed reads a bounded body and verifies the signature over it. It has
// already answered the request when ok is false.
//
// Bounded because this endpoint is unauthenticated until the HMAC is
// checked, and the body must be buffered whole to check it. Without a cap
// a large POST is memory growth an anonymous caller controls.
func (d *dispatcher) signed(w http.ResponseWriter, r *http.Request) (body []byte, ok bool) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			slog.Warn("reject", "reason", "body over cap", "cap", maxBody)
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			slog.Warn("reject", "reason", "unreadable body", "err", err)
			w.WriteHeader(http.StatusBadRequest)
		}
		return nil, false
	}
	// Header.Get returns the first value of a repeated header, so a
	// duplicated X-Kaneo-Signature is verified rather than being an array
	// that nothing can hex-decode.
	if !d.verify(raw, r.Header.Get("X-Kaneo-Signature")) {
		slog.Warn("reject", "reason", "bad signature")
		w.WriteHeader(http.StatusUnauthorized)
		return nil, false
	}
	return raw, true
}

// delivery is the part of a Kaneo webhook payload this reads. The task
// object carries only id, number, title, status, statusName, priority and
// url - no labels, which is why repoForTask asks the API instead.
type delivery struct {
	Event string `json:"event"`
	Task  struct {
		ID       string `json:"id"`
		TicketID string `json:"ticketId"`
	} `json:"task"`
	Data struct {
		NewStatus string `json:"newStatus"`
	} `json:"data"`
}

// webhook is what Kaneo posts to when a card changes column.
func (d *dispatcher) webhook(w http.ResponseWriter, r *http.Request) {
	raw, ok := d.signed(w, r)
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
	id, label := ev.Task.ID, cardLabel(ev.Task.TicketID, ev.Task.ID)
	column := ev.Data.NewStatus
	st, ok := routes[column]
	if !ok {
		// Inert columns are logged, not dropped: this is the audit trail
		// of every card movement, Chris's included.
		slog.Info("noop", "task", label, "column", column)
		return
	}
	if id == "" {
		slog.Warn("skip", "task", label, "column", column, "reason", "payload names no task id")
		return
	}
	// The label lookup, the busy check and the launch all wait on other
	// systems. The 202 has gone, so from here the work is genuinely
	// asynchronous, which is what Kaneo's delivery health needs.
	d.inflight.Add(1)
	go func() {
		defer d.inflight.Done()
		d.dispatch(context.Background(), column, st, id, label)
	}()
}

// cardLabel is what a human reads in the log: the ticket id when the
// payload carries one, else the raw id.
func cardLabel(ticketID, id string) string {
	if ticketID != "" {
		return ticketID
	}
	if id != "" {
		return id
	}
	return "?"
}

// dispatch runs the stage a column implies for one card, or logs one line
// saying why not.
func (d *dispatcher) dispatch(ctx context.Context, column string, st stage, id, label string) {
	repo, err := d.repoForTask(ctx, id)
	if err != nil {
		// A failed lookup is not "no label". Saying so keeps a Kaneo
		// outage from reading as a board full of unlabelled cards.
		slog.Error("cannot read labels", "task", label, "column", column, "err", err)
		return
	}
	if repo == "" {
		slog.Warn("skip", "task", label, "column", column, "reason", "card needs exactly one repo: label")
		return
	}
	if !d.podWorksRepo(st.pod, repo) {
		slog.Warn("skip", "task", label, "column", column, "reason", st.pod+" does not work "+repo)
		return
	}
	d.runStage(ctx, repo, st, id, label)
}

// runStage launches the stage in its pod unless a run is already there.
func (d *dispatcher) runStage(ctx context.Context, repo string, st stage, id, label string) {
	busy, err := d.podIsBusy(ctx, st.pod)
	if err != nil {
		// A failed check must not read as idle: starting a second agent
		// on a live clone is the one thing this guard exists to prevent.
		slog.Warn("cannot tell whether pod is busy; assuming it is", "pod", st.pod, "err", err)
		busy = true
	}
	if busy {
		// Dropped rather than queued: the card stays where it is, so
		// moving it again once the current run finishes is the retry. A
		// queue here would silently stack up work nobody asked for twice.
		slog.Warn("busy", "task", label, "repo", repo, "pod", st.pod, "hint", "move the card again later")
		return
	}
	slog.Info("start", "task", label, "repo", repo, "pod", st.pod, "script", path.Base(st.script))
	// setsid + nohup, and the exec returns as soon as the run is launched.
	//
	// A plain exec ties the run's life to the connection: the API server,
	// a dispatcher restart, a rollout, or a network blip kills the agent
	// mid-ticket. An author run takes up to an hour, so that window is
	// most of the run. The first real dispatch died this way within
	// seconds of starting.
	//
	// The task is passed to the stage. Without it the stage falls back to
	// scanning every open PR in every repo it owns, which is what a
	// nightly cron wanted and an event does not: the webhook names one
	// card, and that card is the work. The id is the raw task id, not
	// the ticket id, because it becomes the branch name and the sweep
	// looks that branch up. It is handed over as a positional argument
	// rather than spliced into the command text.
	rc, err := d.exec(ctx, st.pod, []string{"sh", "-c",
		`setsid nohup "$0" "$1" >/dev/null 2>&1 </dev/null &`, st.script, id})
	if err != nil {
		slog.Error("launch failed", "task", label, "repo", repo, "err", err)
		return
	}
	// "launched", not "finished": the run is detached and outlives this.
	// The log in the pod and the card are where the outcome lives.
	slog.Info("launched", "task", label, "repo", repo, "rc", rc)
}

// podIsBusy asks whether a stage is already running in this pod.
//
// Asked of the pod, not of this process. The run is detached, so anything
// remembered here would clear the moment the launch returned and would
// not survive a restart either. The scripts take a lock themselves (see
// take_pod_lock in nightly-common.sh), so what is checked is what the run
// actually holds: flock -n succeeds only if nothing holds it, so exit 0
// means idle and anything else means busy.
func (d *dispatcher) podIsBusy(ctx context.Context, pod string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	rc, err := d.exec(ctx, pod, []string{"sh", "-c", "flock -n /tmp/nightly.lock true"})
	if err != nil {
		return true, err
	}
	return rc != 0, nil
}

// podWorksRepo reports whether a pod works this repo at all.
//
// routes picks a pod by column, but which repos a pod acts on is decided
// separately, by the per-pod list the session pods themselves read.
// Dispatching a repo that is not on that list runs a full job that scans
// the wrong set and exits having done nothing - a silent no-op that reads
// as a successful run. Checking here turns that into one line saying why.
func (d *dispatcher) podWorksRepo(pod, repo string) bool {
	n := pod[strings.LastIndex(pod, "-")+1:]
	list, ok := d.repos[n]
	if !ok {
		// No list is not a reason to refuse: the scripts do their own
		// filtering, and failing closed here would stop everything the
		// first time the secret lagged.
		return true
	}
	want := repo
	if !strings.Contains(repo, "/") {
		want = d.owner + "/" + repo
	}
	for _, r := range strings.FieldsFunc(list, func(c rune) bool { return c == ',' || unicode.IsSpace(c) }) {
		if r == want {
			return true
		}
	}
	return false
}

// repoForTask is the repo a card is for, from its repo:<name> label.
//
// It returns the repo, or "" when the card does not carry exactly one
// repo: label, or an error when the lookup itself failed - which is a
// different thing and must not read as "no label".
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
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("%s -> %d", req.URL.Path, res.StatusCode)
	}
	if err := json.NewDecoder(res.Body).Decode(out); err != nil {
		return fmt.Errorf("%s: %w", req.URL.Path, err)
	}
	return nil
}
