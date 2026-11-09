#!/usr/bin/env node
// Turns a Kaneo card move into a pod run.
//
// Kaneo POSTs here whenever a task changes column, and the column it landed
// in decides what happens. Most columns decide nothing: see ROUTES. That
// table IS the safety property — a pod moving a card to in-progress cannot
// re-trigger the author, because in-progress triggers nothing. There is no
// actor check anywhere here and none is needed: the pipeline flows one way,
// so the only way to make a cycle is for a human to drag a card backwards,
// which is a deliberate "do it again".
//
// Replaces the three nightly cronjobs. Work starts when a card moves rather
// than at 00:00, and each stage hands to the next by moving the card.
//
// Node rather than a shell script because the HMAC must be computed over the
// exact bytes Kaneo sent: reading a raw body is the one thing a shell HTTP
// loop cannot be trusted to do.
import { createServer } from "node:http";
import { createHmac, timingSafeEqual } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const PORT = Number(process.env.PORT ?? 8080);
const NS = process.env.DISPATCH_NS ?? "claude-pods";
// Same default and same env var as nightly-common.sh, so a short repo: label
// resolves to the same full name here as it does in the scripts.
const OWNER = process.env.NIGHTLY_OWNER ?? "ChristopherScot";
const BRANCH_PREFIX = process.env.KANEO_BRANCH_PREFIX ?? "fix/";
const PROJECT = process.env.KANEO_PROJECT_ID ?? "pwz0urubiajnchag39tcbjkl";
const API_URL =
  process.env.KANEO_API_URL ?? "http://kaneo.kaneo.svc.cluster.local:5173";
const SECRET_FILE =
  process.env.DISPATCH_SECRET_FILE ?? "/run/secrets/kaneo/webhook-secret";

// column slug -> which pod runs which script. Anything not here is inert.
const ROUTES = {
  "to-do": ["claude-session-0", "/usr/local/bin/nightly-author"],
  "in-review": ["claude-session-2", "/usr/local/bin/nightly-test"],
  mergeable: ["claude-session-1", "/usr/local/bin/nightly-merge"],
};

const log = (...a) => console.log(new Date().toISOString(), ...a);

// A Kaneo task.status_changed payload is a few KB; 1 MiB is generous.
const MAX_BODY = 1024 * 1024;


function verify(rawBody, sigHex) {
  let secret;
  try {
    secret = readFileSync(SECRET_FILE, "utf8").trim();
  } catch {
    return false;
  }
  if (!secret || !sigHex) return false;
  const want = createHmac("sha256", secret).update(rawBody).digest();
  let got;
  try {
    got = Buffer.from(sigHex, "hex");
  } catch {
    return false;
  }
  // Length check first: timingSafeEqual throws on a length mismatch, and a
  // throw here would read as a server error rather than a bad signature.
  return got.length === want.length && timingSafeEqual(got, want);
}

// Is a stage already running in this pod?
//
// Asked of the pod, not of this process. The run is detached so it
// outlives the exec that started it, and the in-memory set would clear the
// moment the launch returned — which would let the next card start a second
// agent beside a live one. The pod's own process table is the only thing
// that knows, and it survives a dispatcher restart too, which the set never
// did.
function podIsBusy(pod) {
  const r = spawnSync(
    "kubectl",
    // A lockfile, not a process scan. The scripts take the lock
    // themselves (see nightly-common.sh), so what is checked here is what
    // the run actually holds — a cmdline grep guesses at that from
    // outside and gets it wrong for a script invoked as `sh <path>`.
    //
    // flock -n succeeds only if nothing holds it, so exit 0 here means
    // IDLE and 1 means busy.
    ["exec", "-n", NS, pod, "--", "sh", "-c",
     "flock -n /tmp/nightly.lock true"],
    { encoding: "utf8", timeout: 20_000 },
  );
  // A failed check must not read as idle: starting a second agent on a
  // live clone is the one thing this guard exists to prevent.
  if (r.error || r.status === null) {
    log(`WARN  cannot tell whether ${pod} is busy; assuming it is`);
    return true;
  }
  // flock succeeded -> nobody holds it -> the pod is idle.
  return r.status !== 0;
}

function runStage(repo, pod, script, task) {
  if (podIsBusy(pod)) {
    // Dropped rather than queued: the card stays where it is, so moving it
    // again once the current run finishes is the retry. A queue here would
    // silently stack up work nobody asked for twice.
    log(`BUSY  ${pod} — ${task} (${repo}) not started; move the card again later`);
    return;
  }
  log(`START ${task} repo=${repo} pod=${pod} ${script.split("/").pop()}`);
  // setsid + nohup, and the exec returns as soon as the run is launched.
  //
  // A plain `kubectl exec` ties the run's life to the connection: the API
  // server, a dispatcher restart, a rollout, or a network blip kills the
  // agent mid-ticket. An author run takes up to an hour, so that window is
  // most of the run. The first real dispatch died this way within seconds
  // of starting.
  //
  // Detaching means the exec exits immediately and rc here says only
  // "the run was launched", not "the run succeeded" — the log in the pod
  // and the card are where the outcome lives, which is where the rest of
  // this design already looks for it.
  const child = spawn(
    "kubectl",
    [
      "exec", "-n", NS, pod, "--",
      "sh", "-c",
      // The task is passed to the stage. Without it the stage falls back
      // to scanning every open PR in every repo it owns, which is what a
      // nightly cron wanted and an event does not: the webhook names one
      // card, and that card is the work. The first real run moved CLA-13
      // to in-review and the test stage went off and tested an unrelated
      // PR instead.
      `setsid nohup ${script} ${task} >/dev/null 2>&1 < /dev/null &`,
    ],
    { stdio: "ignore" },
  );
  child.on("exit", (code, signal) => {
    // "launched", not "finished" — the run is detached and outlives this.
    log(`LAUNCHED ${task} repo=${repo} rc=${code ?? signal}`);
  });
  child.on("error", (err) => {
    log(`ERROR ${task} repo=${repo}: ${err.message}`);
  });
}

// Does this pod work this repo at all?
//
// ROUTES picks a pod by column, but which repos a pod acts on is decided
// separately by /run/secrets/repos/pod<n>. Dispatching a repo that is not
// on that pod's list runs a full job that scans the wrong set and exits
// having done nothing — a silent no-op that reads as a successful run.
// Checking here turns that into one line saying why.
//
// Read per request rather than cached: the secret is Vault-backed and
// refreshes on its own schedule, and a dispatcher holding a stale copy
// would refuse work the pod would happily do.
function podWorksRepo(pod, repo) {
  const n = pod.slice(pod.lastIndexOf("-") + 1);
  let list;
  try {
    list = readFileSync(`/run/secrets/repos/pod${n}`, "utf8");
  } catch {
    // No list mounted is not a reason to refuse: the scripts do their own
    // filtering, and failing closed here would stop everything the first
    // time the mount lagged.
    return true;
  }
  const want = repo.includes("/") ? repo : `${OWNER}/${repo}`;
  return list.split(/[\s,]+/).filter(Boolean).includes(want);
}

// The repo a card is for, from its repo:<name> label.
//
// Fetched from the API rather than read off the webhook, because the
// payload's `task` object carries only id, number, title, status,
// statusName, priority and url — there are no labels in it. Reading
// task.labels from the payload silently yielded "no label" for every card,
// so every dispatch was skipped as unlabelled even when the label was
// right there on the board.
//
// Returns the repo, or null when the card does not carry exactly one
// repo: label, or "" when the lookup itself failed — which is a different
// thing and must not read as "no label".
async function repoForTask(taskId) {
  const key = readFileSync(
    process.env.DISPATCH_API_KEY_FILE ?? "/run/secrets/kaneo/api-key",
    "utf8",
  ).trim();
  // /api/label/task/{id}, not /api/task/{id}: the task endpoint does not
  // return labels at all.
  const res = await fetch(`${API_URL}/api/label/task/${encodeURIComponent(taskId)}`, {
    headers: { Authorization: `Bearer ${key}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`task lookup ${res.status}`);
  const body = await res.json();
  const names = (Array.isArray(body) ? body : [])
    .map((l) => l?.name ?? "")
    .filter((n) => n.startsWith("repo:"))
    .map((n) => n.slice("repo:".length));
  return names.length === 1 ? names[0] : null;
}


// --- reconcile ---------------------------------------------------------
//
// Event dispatch has no retry. If a webhook fires and the work cannot
// start — the cluster API is down, the dispatcher is mid-restart, the pod
// is not ready — nothing ever picks it up again, and the card is left
// looking exactly like one nobody has touched.
//
// That is not hypothetical: CLA-11 was moved to To Do on 3 Nov while two
// nodes were down, the exec failed, and it sat there for five days.
//
// Nothing records "this was dispatched". The busy set is in memory and
// dies with the pod, and a dispatch log would be a second source of truth
// that disagrees with reality — and would have died that night too. So
// this compares the column against the world instead, using only state
// that survives a restart: when the card entered its column, and whether
// the work that column implies actually exists on GitHub.

const STALE_MS = Number(process.env.RECONCILE_STALE_MS ?? 4 * 60 * 60 * 1000);

async function kaneo(path) {
  const key = readFileSync(
    process.env.DISPATCH_API_KEY_FILE ?? "/run/secrets/kaneo/api-key",
    "utf8",
  ).trim();
  const res = await fetch(`${API_URL}/api${path}`, {
    headers: { Authorization: `Bearer ${key}` },
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`${path} -> ${res.status}`);
  return res.json();
}

// When the card last changed column. The task object's updatedAt is null
// in this Kaneo build, so the activity feed is the only record of it.
async function enteredColumnAt(taskId) {
  const acts = await kaneo(`/activity/${encodeURIComponent(taskId)}`);
  const moves = (Array.isArray(acts) ? acts : [])
    .filter((a) => a?.type === "status_changed" && a?.createdAt)
    .map((a) => Date.parse(a.createdAt))
    .filter((n) => Number.isFinite(n));
  return moves.length ? Math.max(...moves) : null;
}

// Has the work this column implies already happened?
//
// Asked of GitHub, not of Kaneo: a branch and a commit status survive
// everything this dispatcher does, and they are what the next stage reads
// anyway. If the answer is yes, the card is mid-flight and must be left
// alone — re-dispatching would run a second agent beside a live one.
function ghJson(args) {
  const r = spawnSync("gh", args, { encoding: "utf8", timeout: 30_000 });
  if (r.status !== 0) throw new Error(`gh ${args[0]}: ${(r.stderr || "").trim()}`);
  return r.stdout.trim() ? JSON.parse(r.stdout) : null;
}

function workExists(column, repo, task) {
  const branch = `${BRANCH_PREFIX}${task}`;
  const prs = ghJson([
    "pr", "list", "--repo", `${OWNER}/${repo.replace(/^.*\//, "")}`,
    "--head", branch, "--state", "all",
    "--json", "number,state,headRefOid",
  ]) ?? [];
  const pr = prs[0];
  // A merged pull request ends the card's story whatever column it is
  // sitting in. CLA-13 was merged by hand while in In Review and carries
  // no nightly/integration status, so the in-review check below would
  // have called it unfinished and re-dispatched the test stage against
  // work that is already on main.
  if (pr?.state === "MERGED") return true;
  switch (column) {
    // The author's job is to open a pull request. One exists -> it ran.
    case "to-do":
      return Boolean(pr);
    // The test pod's job is to post nightly/integration at the head.
    case "in-review": {
      if (!pr) return false;
      const st = ghJson([
        "api", `repos/${OWNER}/${repo.replace(/^.*\//, "")}/commits/${pr.headRefOid}/status`,
        "--jq", '[.statuses[] | select(.context == "nightly/integration")] | length',
      ]);
      return Number(st) > 0;
    }
    // The merge pod's job is to merge it.
    case "mergeable":
      return Boolean(pr) && pr.state === "MERGED";
    default:
      return true;
  }
}

// One sweep. Returns a summary rather than logging only, so the CronJob's
// own output says what happened.
async function reconcile(dryRun) {
  const board = await kaneo(`/task/tasks/${PROJECT}`);
  const columns = board?.data?.columns ?? [];
  const now = Date.now();
  const out = { checked: 0, redispatched: [], skipped: [], errors: [] };

  for (const col of columns) {
    const route = ROUTES[col.slug];
    if (!route) continue; // inert column: nothing was ever owed here
    for (const task of col.tasks ?? []) {
      // The raw task id drives branch lookups; ticketId is only ever for
      // the log line, where a human reads it. The branch is built from
      // whatever the dispatcher hands the stage, and that is task.id —
      // PR #98 is on fix/d3kgbstyuu5mmygqtorppai2, not fix/CLA-13.
      // Searching for the ticketId branch would find nothing, conclude
      // the work never happened, and re-dispatch a finished card.
      const id = task.id;
      const label = task.ticketId ?? task.id;
      out.checked++;
      try {
        const at = await enteredColumnAt(id);
        // No recorded move means the card was created straight into this
        // column and never moved, so no webhook ever fired for it. Treat
        // creation as the clock.
        const since = at ?? Date.parse(task.createdAt ?? "") ?? null;
        if (!since || now - since < STALE_MS) {
          continue; // still within the window a real run could take
        }
        const repo = await repoForTask(id);
        if (!repo) {
          out.skipped.push(`${label}: no single repo: label`);
          continue;
        }
        if (!podWorksRepo(route[0], repo)) {
          out.skipped.push(`${label}: ${route[0]} does not work ${repo}`);
          continue;
        }
        if (workExists(col.slug, repo, id)) {
          // The work ran; the card is simply waiting on the next stage,
          // or on a human. Not ours to restart.
          out.skipped.push(`${label}: work already exists`);
          continue;
        }
        const age = Math.round((now - since) / 3600_000);
        if (dryRun) {
          out.redispatched.push(`${label} (${col.slug}, ${age}h) [dry-run]`);
          continue;
        }
        log(`RECONCILE ${label} stuck in ${col.slug} for ${age}h; re-dispatching`);
        // id, not label: this is what becomes the branch name.
        runStage(repo, route[0], route[1], id);
        out.redispatched.push(`${label} (${col.slug}, ${age}h)`);
      } catch (err) {
        // An error here must not read as "nothing to do". Report it and
        // leave the card alone.
        out.errors.push(`${label}: ${err.message}`);
      }
    }
  }
  return out;
}

createServer((req, res) => {
  // Reconcile is a POST so it cannot be triggered by a stray GET, and it
  // is behind the same HMAC as the webhook — it starts real work.
  if (req.method === "GET" && req.url?.startsWith("/reconcile")) {
    res.writeHead(405).end("POST with a signature");
    return;
  }
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200).end("ok");
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405).end();
    return;
  }
  // Bounded: this endpoint is unauthenticated until the HMAC is checked,
  // and the body must be buffered whole to check it. Without a cap a large
  // POST is memory growth an anonymous caller controls.
  const chunks = [];
  let size = 0;
  let tooBig = false;
  req.on("data", (c) => {
    if (tooBig) return;
    size += c.length;
    if (size > MAX_BODY) {
      tooBig = true;
      log(`REJECT body over ${MAX_BODY} bytes`);
      res.writeHead(413).end();
      req.destroy();
      return;
    }
    chunks.push(c);
  });
  req.on("end", () => {
    if (tooBig) return;
    const raw = Buffer.concat(chunks);
    // Node gives a header as a string OR an array when it appears twice.
    // Passing an array to Buffer.from throws, which would reject a valid
    // delivery as a server error rather than verify it.
    const sigHeader = req.headers["x-kaneo-signature"];
    const sig = Array.isArray(sigHeader) ? sigHeader[0] : sigHeader;
    if (!verify(raw, sig)) {
      log("REJECT bad signature");
      res.writeHead(401).end();
      return;
    }
    // /reconcile is the sweep, not a webhook. Same signature check, since
    // it starts the same work.
    if (req.url?.startsWith("/reconcile")) {
      const dryRun = req.url.includes("dry");
      reconcile(dryRun)
        .then((r) => {
          log(
            `RECONCILE done checked=${r.checked} redispatched=${r.redispatched.length} skipped=${r.skipped.length} errors=${r.errors.length}`,
          );
          for (const line of r.redispatched) log(`  redispatch ${line}`);
          for (const line of r.skipped) log(`  skip       ${line}`);
          for (const line of r.errors) log(`  ERROR      ${line}`);
        })
        .catch((e) => log(`RECONCILE failed: ${e.message}`));
      res.writeHead(202).end();
      return;
    }

    // Answer before doing the work: Kaneo records delivery health, and a
    // response that waits on a pod run would read as a failed delivery.
    res.writeHead(202).end();

    let body;
    try {
      body = JSON.parse(raw.toString("utf8"));
    } catch {
      log("REJECT unparseable body");
      return;
    }
    if (body.event !== "task.status_changed") {
      log(`ignore event=${body.event}`);
      return;
    }
    const task = body.task ?? {};
    const id = task.ticketId ?? task.id ?? "?";
    const column = body.data?.newStatus ?? "?";
    const route = ROUTES[column];
    if (!route) {
      // Inert columns are logged, not dropped: this is the audit trail of
      // every card movement, Chris's included.
      log(`noop  ${id} -> ${column}`);
      return;
    }
    // The lookup is async, so the rest of this handler runs in a promise.
    // The 202 has already been sent, which is what Kaneo needs for its
    // delivery health — the work is genuinely asynchronous from here.
    repoForTask(task.id ?? id)
      .then((repo) => {
        if (!repo) {
          log(`SKIP  ${id} -> ${column}: card needs exactly one repo: label`);
          return;
        }
        if (!podWorksRepo(route[0], repo)) {
          log(`SKIP  ${id} -> ${column}: ${route[0]} does not work ${repo}`);
          return;
        }
        runStage(repo, route[0], route[1], id);
      })
      .catch((err) => {
        // A failed lookup is not "no label". Saying so keeps a Kaneo
        // outage from reading as a board full of unlabelled cards.
        log(`ERROR ${id} -> ${column}: cannot read labels: ${err.message}`);
      });
  });
}).listen(PORT, () => log(`dispatcher listening on :${PORT}`));
