# The dispatcher change

What it takes to move from role-pinned pods to anonymous workers.
Written from reading `dispatcher/dispatch.mjs` at 232df50, not from
memory. **Not implemented** — this is the plan.

## Today

```js
const ROUTES = {
  "to-do":     ["claude-session-0", "/usr/local/bin/stage-author"],
  "in-review": ["claude-session-2", "/usr/local/bin/stage-test"],
  mergeable:   ["claude-session-1", "/usr/local/bin/stage-merge"],
};
```

A column names a pod *and* a script. `WAKE_REPLICAS` derives from the
highest ordinal, so every dispatch wakes all three pods even when one
card needs one stage.

## The change

```js
const ROUTES = {
  "to-do":     "/usr/local/bin/stage-author",
  "in-review": "/usr/local/bin/stage-test",
  mergeable:   "/usr/local/bin/stage-merge",
};
```

A column names only a script. `runStage(repo, pod, script, task)`
already takes the pod as a parameter, so the change is in *who supplies
it*: a new `claimIdleWorker()` scales the set up if needed, then returns
the first ordinal whose `/tmp/nightly.lock` is free.

Three call sites move:

| Site | Today | After |
|---|---|---|
| `ROUTES[col.slug]` destructure | `[pod, script]` | `script` |
| `ensureAwake()` | scale to `WAKE_REPLICAS` (3) | scale to `claimed + 1` |
| `runStage(...)` | fixed pod | claimed worker |

## What already works and needs no change

- **`podIsBusy(pod)`** asks a pod, not a role — it is already written
  for interchangeable workers. This is the piece that makes the whole
  change modest.
- **`session-sleep`** checks every pod and scales to 0 only when all are
  idle. Unchanged.
- **Reconcile** re-dispatches by column; it would claim a worker the
  same way.

## What needs deciding

- **`podWorksRepo`.** Refuses a repo absent from that pod's list in
  `/run/secrets/repos/pod<n>`. Measured: 24 of 26 repos are common to
  all three, and only pod1 carries the other 2 — so this guards a bad
  mount rather than enforcing specialization. Give every worker the
  union of 26 and it stays a safety net while workers become
  interchangeable.
- **Remote Control session names.** Today `pod0-author` tells you at a
  glance which agent is doing what. Anonymous workers lose that. Either
  rename the session when a worker claims a card, or keep one
  long-lived pod purely for attaching that never runs stage work.
- **A claim race.** Two webhooks arriving together could both see the
  same worker idle. `flock` is the arbiter — the loser's `runStage`
  hits BUSY and the card stays put, which is the existing behaviour for
  a busy pod, so the race degrades into something already handled.

## What this does not solve

Scaling to exactly one worker still means the StatefulSet runs ordinal
0. Two concurrent cards need 0 and 1. That is strictly better than
today's always-three, but ordinals stay dense — a worker pool, not
per-task pods. Per-task pods need the ephemeral Job model, which is
what the Garage work is groundwork for.
