# kaneo-dispatcher

Turns a card move on the Kaneo board into a run in a Claude session pod.
Owned by me-myself-and-i.

Kaneo posts a `task.status_changed` webhook here whenever a card changes
column. Three columns start work - see `routes` in `dispatch.go`, which
is the one place that table lives - and every other column is logged as
a `noop`, which is the audit trail of every card movement. That table is
the safety property: a pod moving a card to `in-progress` cannot
re-trigger the author, because `in-progress` triggers nothing. Keep it in
step with the column graph written down in
`claude-pods/lib/pod-common.sh`.

## What a delivery goes through

1. The body is capped at 1 MiB (413 over) and the `X-Kaneo-Signature`
   HMAC-SHA256 over the raw bytes is checked in constant time (401 on a
   mismatch). Nothing runs for an unsigned request.
2. 202 is answered before any work, so Kaneo's delivery health does not
   wait on a pod.
3. The card's `repo:<name>` label is read back from the Kaneo API - the
   payload carries no labels - resolved to `owner/name`, and checked
   against the list of repos the target pod works (`REPOS_POD<n>`).
4. The `claude-session` StatefulSet is woken: scaled to one past the
   highest ordinal `routes` names and waited on until every pod is
   ready, bounded at ten minutes. The `session-sleep` CronJob in
   `claude-pods/` is the matching sleep. A wake that fails is logged for
   the card and nothing is exec'd; the sweep below is the retry.
5. The pod's lock file is probed with `flock -n`, the same file the
   scripts lock. A pod that is already running a stage is left alone and
   the card stays where it is: moving it again later is the retry.
6. The stage is launched detached (`setsid nohup ... &`) through the
   Kubernetes exec API, so it outlives this process, a rollout and any
   network blip. It is handed the task id and the repo, since
   `stage-author` refuses a named task without one.

`POST /reconcile`, behind the same signature, sweeps the three dispatching
columns for cards that sat there longer than `RECONCILE_STALE` (4h) and
whose work does not exist on GitHub - no pull request, no
`nightly/integration` status, no merge - and re-dispatches them. It also
sweeps `in-progress`, where the author parks a card before working it: a
card stale there was stranded by an author that died, and goes back to
the author without the GitHub check, because judging whatever work exists
is the author's own job. `POST /reconcile?dry` reports without launching
or waking. The hourly `kaneo-reconcile` CronJob in `claude-pods/` is the
caller.

## Layout

```
main.go        process lifecycle: logging, timeouts, shutdown
server.go      routes, metrics middleware, the bounded signed read
dispatch.go    the column table, label lookup, wake, busy probe, launch
reconcile.go   the sweep, and the GitHub questions it asks
kube.go        exec and the StatefulSet wake through the API server,
               with the pod's own identity
rbac.yaml      the Role that allows both; listed in config.yaml
config.yaml    what this service is, for homelabctl
deploy/        Kubernetes manifests, rendered from config.yaml
```

Everything the service reads comes from the environment, and every
secret in it is a key under `secrets:` in `config.yaml`, read from Vault.
The Vault role that allows those reads is derived from the same file:

```sh
homelabctl vault          # print the policy and role
homelabctl vault --apply  # write them
```

## Build and test

```sh
make test                 # go vet, go test -race. What CI runs.
make build
```

The tests need no cluster, no Kaneo and no GitHub: `testhelp_test.go`
fakes all three and records what the dispatcher asked a pod to run.

## Deploy

Push to main. CI builds the image; argocd-image-updater sees the new
digest and the `kaneo-dispatcher` Application syncs it. The Service
answers on 80 (what the generated Ingress routes to) and on 8080, which
is the port Kaneo's webhook integration and the reconcile CronJob post
to: `http://kaneo-dispatcher.claude-pods.svc.cluster.local:8080`.

`deploy/` is rendered from `config.yaml`. Adjust it with `patches` there,
keyed by resource kind, rather than editing the manifests. The copy of
`argocd.json` at the repo root is what registers the service with Argo;
a test keeps it identical to the rendered one.
