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
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

const PORT = Number(process.env.PORT ?? 8080);
const NS = process.env.DISPATCH_NS ?? "claude-pods";
const SECRET_FILE =
  process.env.DISPATCH_SECRET_FILE ?? "/run/secrets/kaneo/webhook-secret";

// column slug -> which pod runs which script. Anything not here is inert.
const ROUTES = {
  "to-do": ["claude-session-0", "/usr/local/bin/nightly-author"],
  "in-review": ["claude-session-2", "/usr/local/bin/nightly-test"],
  mergeable: ["claude-session-1", "/usr/local/bin/nightly-merge"],
};

const log = (...a) => console.log(new Date().toISOString(), ...a);

// One run per repo at a time. The pods share a single clone per repository
// and nightly-author runs `git reset --hard` before each ticket, so two runs
// on the same repo would reset each other's working tree mid-edit. Different
// repos run together freely — that is the point of dispatching on a move
// instead of on a clock.
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
  if (busy.has(repo)) {
    // Dropped rather than queued: the card stays where it is, so moving it
    // again once the current run finishes is the retry. A queue here would
    // silently stack up work nobody asked for twice.
    log(`BUSY  ${repo} — ${task} not started; move the card again later`);
    return;
  }
  busy.add(repo);
  log(`START ${task} repo=${repo} pod=${pod} ${script.split("/").pop()}`);
  const child = spawn("kubectl", ["exec", "-n", NS, pod, "--", script], {
    stdio: "ignore",
  });
  child.on("exit", (code, signal) => {
    busy.delete(repo);
    log(`END   ${task} repo=${repo} rc=${code ?? signal}`);
  });
  child.on("error", (err) => {
    busy.delete(repo);
    log(`ERROR ${task} repo=${repo}: ${err.message}`);
  });
}

function oneRepoLabel(task) {
  const names = (task?.labels ?? [])
    .map((l) => l?.name ?? "")
    .filter((n) => n.startsWith("repo:"))
    .map((n) => n.slice("repo:".length));
  return names.length === 1 ? names[0] : null;
}

createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200).end("ok");
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405).end();
    return;
  }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const raw = Buffer.concat(chunks);
    if (!verify(raw, req.headers["x-kaneo-signature"])) {
      log("REJECT bad signature");
      res.writeHead(401).end();
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
    const repo = oneRepoLabel(task);
    if (!repo) {
      log(`SKIP  ${id} -> ${column}: card needs exactly one repo: label`);
      return;
    }
    runStage(repo, route[0], route[1], id);
  });
}).listen(PORT, () => log(`dispatcher listening on :${PORT}`));
