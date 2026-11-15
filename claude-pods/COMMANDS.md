The author, test and merge stages execute only dispatcher-issued commands:

```
stage-author <task-id> <owner/repository> <command-id>
```

The dispatcher persists the command before launch. A stage without all three
arguments exits before obtaining credentials or taking work. Review workers
select only the newest open, same-repository PR on the assigned task branch.
There is no board scan, repository sweep or daily merge-compensation sweep.

Starts, outcomes, notes, mentions and links are reported to
`$KANEO_DISPATCH_URL/worker-events` (default: the in-cluster dispatcher Service).
The existing mounted API key authenticates the request; command identity scopes
it to the assigned task. Only a matching HTTP 200 v1 acknowledgment grants
permission to start. Failed or uncertain reports are logged and never fall back
to direct Kaneo mutations. Workers still read task context with the Kaneo CLI.

A merge requires fresh dispatcher authorization for its PR and reviewed SHA.
The worker records the actual merge before any fallible report, then checks CI
for that exact merge commit and base branch. Done is reported only after green
verification. Unknown CI leaves the command held for explicit recovery. Reverts
also require authorization, which durably invalidates the original PR before
GitHub is called; a lost final report cannot make reverted work count as Done.

Companion service: https://github.com/ChristopherScot/kaneo-dispatcher/pull/2

Quiesce existing workers before rollout. Deploy the dispatcher endpoint/RBAC,
then replace every session pod with this image; check the StatefulSet partition.
The dispatcher refuses old scripts lacking `dispatcher-command-protocol: 1`,
and these workers refuse old launches without a command ID. Validate with a
disposable ticket before enabling the real backlog. No deployment is performed
by this change. Recovery instructions live in the dispatcher README.
