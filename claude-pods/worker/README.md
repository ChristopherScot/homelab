# Ephemeral workers: state of play

Groundwork for replacing the three role-pinned `claude-session` pods
with disposable workers. **Nothing here is wired into the dispatcher
yet** — Garage is deployed and running, its credentials are in Vault,
and the Jobs are written.

## Why this shape

Four constraints drove it:

1. **Roles must scale independently.** Today `claude-session-0/1/2` are
   pinned to author/merge/test by StatefulSet ordinal, and ordinals are
   dense — waking the tester wakes all three, because ordinal 2 cannot
   exist without 0 and 1.
2. **Books must never reach git.** They live only on a home PVC today:
   not in git, not in the image, not in a secret.
3. **No shared writable storage.** A worker must not be able to see or
   edit another's files.
4. **Everything scales to zero when not working.**

(2) rules out ephemeral homes unless the books come from somewhere, and
(3) rules out a shared read-write volume. Object storage satisfies
both: workers pull their own copy over HTTP, so there is no filesystem
to share, and a read-only key makes write isolation structural rather
than behavioural.

## What is running

- **Garage** (`garage` namespace), three nodes, `replication_factor 3`,
  bucket `claude-reference`. One node per k8s node; see garage/README.md
  for what happens when one goes away, and garage/PERMISSIONS.md for how
  a new consumer gets a key.
- **Two keys**: `claude-worker` (read, for pods) and `claude-seed`
  (read-write, for seeding). Verified distinct in `garage bucket info`.

## Credentials

Vault holds both S3 keys (`kv/garage/s3-reference`, `kv/garage/s3-seed`)
and the RPC secret (`kv/garage/rpc`); `bootstrap/vault-policies.sh
--garage-only` declares who may read them, and the ExternalSecrets in
garage/secrets.yaml project them. `bootstrap/garage-init.sh` imports the
two keys from those projected Secrets into any rebuilt cluster, so a
rebuild never changes what the pods hold. Adding a consumer, sharing a
bucket, or rotating a key is walked through in garage/PERMISSIONS.md.
Workers must never mount the seeder Secret.

## Then the PoC proves the model

```sh
kubectl scale statefulset claude-session -n claude-pods --replicas=0
kubectl apply -f claude-pods/worker/seed-reference-job.yaml
kubectl logs -n claude-pods job/seed-reference -f

kubectl apply -f claude-pods/worker/poc-worker-job.yaml
kubectl logs -n claude-pods job/poc-worker -f
```

The worker job prints its pull duration, the file counts it received,
and the number of Longhorn/NFS mounts it holds — which should be zero.

## A trap found while reviewing this

`entrypoint.sh:58` derives the pod's identity from its hostname:

```sh
ORD="${HOSTNAME##*-}"
```

Under a StatefulSet that yields `0`, `1`, `2`. Under a **Job** - which
is what `poc-worker-job.yaml` is - a pod's hostname is
`poc-worker-<random>`, so `ORD` becomes the random suffix. Everything
keyed on it then misses silently:

- `/run/secrets/repos/pod${ORD}` does not exist, so the repo list falls
  back to `CLONE_REPOS` and the worker may clone nothing
- the `case "$ORD"` role lookup falls through to `agent`

Neither errors. A Job-based worker would come up looking fine and
quietly working the wrong set. Whatever replaces the ordinal has to be
passed in explicitly - the hostname cannot carry it once workers stop
being a StatefulSet.

## What is NOT designed yet

- **The dispatcher change.** Today `ROUTES` maps a column to a fixed
  pod name. It would map a column to a *script*, and pick any idle
  worker. The busy lock already works this way (`podIsBusy` asks a pod,
  not a role), so this is a modest change rather than a rewrite.

  One thing that looked like a blocker and is not: `podWorksRepo`
  refuses to dispatch a repo that is not on that pod's list in
  `/run/secrets/repos/pod<n>`, which would make workers
  non-interchangeable. Measured, the lists are near-identical - 24 of
  26 repos are common to all three pods, and only pod1 carries the
  other 2. So the check is guarding against a bad mount rather than
  enforcing specialization, and giving every worker the union of 26
  keeps it as a safety net while making workers genuinely
  interchangeable.
- **Remote Control sessions.** Workers are anonymous, so the
  `pod0-author` naming that tells you which agent is doing what would
  be lost. Either name the session after the card it picked up, or keep
  one long-lived pod for attaching that never does stage work.
- **The go-build cache.** 1.4GB per session pod, and a real cost. The
  stage scripts do not invoke `go` themselves, which is why an earlier
  version of this file wrongly concluded the cache was only from
  interactive use - but the prompts they render do: `author.md` and
  `review.md` both say `go test ./...`, `test.md` says to build and run
  it, and `prompts/nightly-settings.json` allow-lists `Bash(go:*)`
  precisely so those calls do not stop for an approval nobody is there
  to give. An ephemeral worker on a Go repo starts cold.
- **Interactive work in a worker.** Separately from the cache: these
  pods are also where hand work happens, and an ephemeral worker is a
  bad place for that. Whether the pool keeps one long-lived pod for
  interactive use is a different decision from how stages run.

  Note the repo clones are NOT a concern, which was not obvious: a
  session pod carries 32 full clones (153MB), but a worker only needs
  the one repo its card names, and `git clone --depth 50` of homelab
  measured 1 second and 3.2MB. Cloning on demand is cheaper than
  carrying warm clones, so only the build cache is a real loss.
- **Transcripts.** `.claude/projects` is ~79MB of session history. A
  resumed card currently has it; an ephemeral worker would not.

## What checks out

Verified against the live cluster and the scripts, so the design does
not rest on assumption:

- **The stage scripts do not touch $HOME.** No reference to `$HOME`,
  `~/` or `.claude/` in claude-pods/stage-author.sh,
  stage-merge.sh or stage-test.sh. They need their lib (in the image) and
  `/workspace/<repo>` (which a worker clones). So an ephemeral worker
  with no persistent home can run them unchanged - this was the last
  structural unknown.
- **Workers can be interchangeable.** See the podWorksRepo note above.
- **Cloning on demand beats carrying clones.** 1s and 3.2MB shallow,
  against 153MB of warm clones per pod.
- **Garage adoption works.** Argo adopted the hand-applied StatefulSet
  rather than fighting it; the pod rolled once on a spec change and the
  layout, bucket and keys survived on their PVCs.
- **The S3 data path works end to end.** Not inferred from "garage is
  running" - a pod in the cluster uploaded an object, listed it,
  downloaded it and diffed it byte-for-byte: upload 632ms, download
  578ms, round trip OK. That is the assumption the whole worker design
  rests on, and it is now measured rather than assumed.
