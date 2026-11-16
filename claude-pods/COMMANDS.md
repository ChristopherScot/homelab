The author, test and merge stages execute only dispatcher-issued commands:

```
stage-author <task-id> <owner/repository> <command-id>
```

The three stage scripts only exec `kaneo-worker`, built from a reviewed commit
of the dispatcher repository. The dispatcher persists the command before launch. A stage without all three
arguments exits before obtaining credentials or taking work. The dispatcher
selects the mode, PR/head and base/branch revisions. Workers execute that assignment and refuse changed remote revisions.
There is no board scan, repository sweep or daily merge-compensation sweep.

Starts, outcomes, notes, mentions and links are reported to
`$KANEO_DISPATCH_URL/worker-events` (default: the in-cluster dispatcher Service).
The existing mounted API key authenticates the request; command identity scopes
it to the assigned task. Only a matching HTTP 200 v1 acknowledgment grants
permission to start. Failed or uncertain reports are logged and never fall back
to direct Kaneo calls. Ticket text and comments arrive in the command snapshot;
workers have no automatic Kaneo reads.

A merge requires fresh dispatcher authorization for its PR and reviewed SHA.
The worker records the actual merge before any fallible report, then checks CI
for that exact merge commit and base branch. Done is reported only after green
verification. Unknown CI leaves the command held for explicit recovery. Reverts
also require authorization, which durably invalidates the original PR before
GitHub is called; a lost final report cannot make reverted work count as Done.

Before starting, workers fetch `POST /worker-command`, validate its v1 payload,
SHA-256 digest, identity and result contract, and acknowledge that digest in the
start report. Protocol marker 3 distinguishes workers that support snapshots.

The dispatcher owns the Markdown templates and deterministic fresh/rework/resume
selection, including the rework cap. Workers substitute only workspace and verdict
paths; ticket/comment text is appended literally and never interpolated against
environment variables. Tool permissions and Claude runtime selection stay local.
The assigned timeout comes from the snapshot.

Each run archives `command.json`, exact `payload.json`, rendered `prompt.txt` and
`provenance.json` under `$STATE_DIR/commands/<command-id>/` before execution. The
hashes identify the raw template, frozen payload and final rendered prompt.
Existing audit directories are never reused. Finished commands retire their heavy
server payload; keep the worker PVC archives for historical inspection.

Checkout preparation preserves local edits and unpushed commits. Remote-tracking
publication evidence is retained (`fetch --no-prune`), while fresh `ls-remote`
validates the assigned revisions. Test/review verdicts are refused if the checkout
HEAD changes during Claude execution. A changed input needs a new command; the
worker does not choose a newer template or PR.

Service source: https://github.com/ChristopherScot/kaneo-dispatcher

Quiesce existing workers before rollout. Deploy the dispatcher endpoint/RBAC,
then replace every session pod with this image; check the StatefulSet partition.
The dispatcher refuses old scripts lacking `dispatcher-command-protocol: 3`,
and these workers refuse missing, unsupported or mismatched prompt payloads.
Validate with a disposable ticket before enabling the real backlog. No deployment is performed
by this change. Recovery instructions live in the dispatcher README.

The Go worker owns the typed protocol, prompt admission/archive, pod lock,
checkout preparation, Claude account/model selection, result parsing and reports.
Git, `gh` and Claude remain subprocesses. One Claude deadline spans probing and
account fallback. Each tool inherits the held pod lock, preserving busy status
if the worker is killed while that tool survives; normal completion and
cancellation clean up the tool process group before releasing the lock.

`verdict.txt` and credential-redacted Claude attempt records now live under the
command archive. Merge and revert intents are persisted before remote writes,
and confirmed receipts before reports. Uncertain writes require inspection and
manual recovery, never automatic replay. CI observations must be complete and
known to pass before success is reported. Rework notes carry a structured kind;
the dispatcher owns receipt wording and counting.

During rollout, inspect any old repository-local `.nightly-verdict` files and
other dirty work before enabling new commands. The Go worker does not discard
old dirty checkouts. Bash now handles only stage entrypoints and best-effort
pressure-based cache maintenance; `claude-account.sh` remains for desloppify.
Worker execution tests are in the dispatcher Go module. Shell tests here cover
entrypoints, maintenance and the other pod tools.
