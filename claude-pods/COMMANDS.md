The author, test and merge stages execute only dispatcher-issued commands:

```
stage-author <task-id> <owner/repository> <command-id>
```

The dispatcher persists the command before launch. A stage without all three
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
start report. Protocol marker 2 distinguishes workers that support snapshots.

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
The dispatcher refuses old scripts lacking `dispatcher-command-protocol: 2`,
and these workers refuse missing, unsupported or mismatched prompt payloads.
Validate with a disposable ticket before enabling the real backlog. No deployment is performed
by this change. Recovery instructions live in the dispatcher README.
