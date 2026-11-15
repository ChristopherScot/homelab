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

`POST /reconcile`, behind the same signature, checks active and human-review
cards for a merged PR and moves them to Done. It uses the newest matching
same-repository PR, re-reads the card before updating, and verifies the result.
Backlog and Done remain untouched. Kaneo has no conditional update operation;
a concurrent edit between the final read and PUT can still be overwritten.

Unfinished work in dispatching columns is retried after `RECONCILE_STALE`
(4h). Stale In Progress cards return to the author, whose mode logic decides
how to resume. Unmerged human-review cards remain parked. Busy workers are
reported as skipped, and failed launches as errors. `POST /reconcile?dry`
performs reads only. The hourly `kaneo-reconcile` CronJob remains the caller.

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

Follow the first-deployment handoff below before merging. Subsequently, CI builds the image; argocd-image-updater sees the new
digest and the `kaneo-dispatcher` Application syncs it. The Service
answers on 80 (what the generated Ingress routes to) and on 8080, which
is the port Kaneo's webhook integration and the reconcile CronJob post
to: `http://kaneo-dispatcher.claude-pods.svc.cluster.local:8080`.

`deploy/` is rendered from `config.yaml`. Adjust it with `patches` there,
keyed by resource kind, rather than editing the manifests. The copy of
`argocd.json` at the repo root is what registers the service with Argo;
a test keeps it identical to the rendered one.

### First deployment handoff

This PR transfers the existing Deployment, Service and Ingress from the
`claude-pods` Argo Application to `kaneo-dispatcher`. A normal automated sync
could prune them before the replacement image or Vault role is ready.

1. Publish the service image from this branch using the workflow's manual
   trigger. It publishes a SHA tag; verify that image before selecting it for
   the first rollout. The default branch publishes `latest` after merging.
2. From this directory, run `homelabctl vault --apply` with an authenticated
   Vault administrator. This creates the new role for ServiceAccount
   `kaneo-dispatcher`; retain the existing `claude-pods` policy and role.
3. Pause automated sync on `claude-pods` and the root app while transferring
   ownership. Record their existing sync settings first. Merge, then sync the
   new Application with the verified image digest. Confirm the ExternalSecret
   is Ready, the Deployment is Available and both Service ports work.
4. Confirm Argo tracking on Deployment, Service and Ingress now names
   `kaneo-dispatcher` before allowing the old Application to prune. Restore
   the recorded sync settings and confirm both Applications are healthy.
5. Verify a signed dry reconcile and a controlled dispatch through client-go
   against the real kubelet. Keep the card open until these checks pass.

If the new deployment fails, stop its automatic sync before restoring the
previous Deployment/Service/Ingress from the pre-merge revision. Preserve the
Kaneo webhook URL and existing secrets throughout the handoff.
