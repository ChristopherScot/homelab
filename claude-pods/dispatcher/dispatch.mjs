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

// One run per POD at a time, not per repo.
//
// Per-repo was wrong: each stage runs a fixed script in a fixed pod, and
// that script writes $STATE_DIR/prompt.txt — one fixed path — before
// feeding it to the agent. Two runs in the same pod race on that file and
// the second writer wins, so one ticket gets the other's prompt. They also
// share the clones under /workspace, where nightly-author does
// `git reset --hard` before each ticket.
//
// Pod is the real resource, and it is also the coarser lock, so it covers
// the repo case for free.
//
// In-process only: a dispatcher restart forgets what is in flight. That is
// why the Deployment is replicas:1 with strategy Recreate — a second
// replica would have its own empty set and start a run on top of a live
// one. A lockfile inside the pod would survive restarts and is the better
// fix if this ever needs more than one replica.
const busy = new Set();

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

function runStage(repo, pod, script, task) {
  if (busy.has(pod)) {
    // Dropped rather than queued: the card stays where it is, so moving it
    // again once the current run finishes is the retry. A queue here would
    // silently stack up work nobody asked for twice.
    log(`BUSY  ${pod} — ${task} (${repo}) not started; move the card again later`);
    return;
  }
  busy.add(pod);
  log(`START ${task} repo=${repo} pod=${pod} ${script.split("/").pop()}`);
  const child = spawn("kubectl", ["exec", "-n", NS, pod, "--", script], {
    stdio: "ignore",
  });
  child.on("exit", (code, signal) => {
    busy.delete(pod);
    log(`END   ${task} repo=${repo} rc=${code ?? signal}`);
  });
  child.on("error", (err) => {
    busy.delete(pod);
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
      const id = task.id;
      const label = task.ticketId ?? id;
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
        if (workExists(col.slug, repo, label)) {
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
        runStage(repo, route[0], route[1], label);
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
