# Ephemeral workers: state of play

Groundwork for replacing the three role-pinned `claude-session` pods
with disposable workers. **Nothing here is wired into the dispatcher
yet** — Garage is deployed and running, the Jobs are written, and the
credential handoff is the one step that needs a human.

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

## Known discrepancy

The live layout advertises **9.3 GiB**, not 10 GiB. It was applied when
`garage-init.sh` defaulted to `10G` (decimal) against a `10Gi` (binary)
PVC. The script now says `10Gi`, but re-running it will not correct the
applied layout - the layout step short-circuits on "already assigned".

Harmless at 74MB of use. Fixing it means `garage layout assign -c 10Gi`
and `layout apply --version 2`, which is a live cluster change and not
worth doing until something needs the space.

## What is running

- **Garage** (`garage` namespace), single node, `replication_factor 1`,
  bucket `claude-reference`.
- **Two keys**: `claude-worker` (read, for pods) and `claude-seed`
  (read-write, for seeding). Verified distinct in `garage bucket info`.

## The PoC ran, and it works

Measured on the live cluster 2026-11-12, not inferred:

```
seed-reference:  1801 objects, 71.4 MB uploaded (books 48M,
                 skills 6.1M, plugins 21M)

poc-worker:      pulled 74M in 7s, 1801 files
                 books: 609  skills: 476  plugins: 716
                 local write OK (own copy)
                 longhorn/nfs mounts: 0
```

Every claim the design rests on is now demonstrated: a worker with **no
PersistentVolumeClaim** obtained the full reference set in 7 seconds -
free against a pod startup that already takes ~70s - using only the
read-only key, got its own writable copy rather than a shared mount,
and left nothing attached when it exited.

The remaining steps below are about moving the credentials into Vault.
The storage model itself no longer needs proving.

### Startup, measured

Dropping the PVCs is also the startup win, which was not an expected
benefit:

| | session pod (2 PVCs) | worker (none) |
|---|---|---|
| scheduled -> volumes attached | ~10s | - |
| volumes attached -> container started | **~28s** | - |
| scheduled -> container started | 41s total | **same second** |
| reference pull | - | 7s |

A session pod spends roughly 28 seconds attaching two Longhorn volumes
before its container starts. The PoC worker, with no
PersistentVolumeClaims, was scheduled and started in the same second.
Both volumes are already single-replica and node-local, so this is
Longhorn engine startup rather than a remote attach - which is why it
cannot be tuned away, only avoided.

Net: about 41s of startup becomes about 8s, pull included.

## The remaining step

Garage mints the S3 key, so it cannot be generated ahead of time:

**Order matters here.** An earlier version of this file told you to
delete `garage-rpc` before the Vault side could serve a replacement.
Doing that today takes garage down at its next restart, because the
`garage` Vault role does not exist yet and External Secrets cannot
create the secret. Delete nothing until step 4 proves the store works.

```sh
# 1. create the vault role and policy. The garage block exists in this
#    script but has not been run, so the SecretStore currently fails
#    with: invalid role name "garage"
./bootstrap/vault-policies.sh

# 2. print the credentials
./bootstrap/garage-init.sh

# 3. seed both paths. s3-reference takes the READ-ONLY key
#    (claude-worker), never claude-seed.
vault kv put kv/garage/s3-reference \
  access-key-id=<Key ID> secret-access-key=<Secret key>
vault kv put kv/garage/rpc rpc-secret="$(openssl rand -hex 32)"

# 4. VERIFY before deleting anything - and check the ExternalSecret,
#    NOT the SecretStore. A Valid store proves only that ESO can log in
#    to Vault with that role; it says nothing about whether the role can
#    read the path. Both states coexist on this cluster right now:
#    vault-claude-pods is Valid/True while its garage-s3-reference
#    ExternalSecret fails with a 403. Checking the store would green-
#    light step 5 with the path still unreadable.
#
#    This must say SecretSynced/True:
kubectl get externalsecret garage-rpc -n garage

# 5. only now hand the RPC secret over. External Secrets will not adopt
#    a Secret it did not create, so the hand-made one has to go first -
#    which is safe only because step 4 proved ESO has actually read the
#    path, not merely authenticated.
kubectl delete secret garage-rpc -n garage
# refreshInterval is 1h, so recreation is not instant - nudge it rather
# than wondering whether it is broken:
kubectl annotate externalsecret garage-rpc -n garage \
  force-sync=$(date +%s) --overwrite
kubectl get secret garage-rpc -n garage

# 6. grant the claude-pods vault role read on BOTH kv/garage/s3-reference
#    and kv/garage/s3-seed. Seeding alone is not enough: those
#    ExternalSecrets fail with a 403, not a 404, so they keep failing
#    after step 3 until the policy is widened - and widening it for one
#    path leaves the seed job failing for the reason you just fixed for
#    the other. That role is not managed by bootstrap/vault-policies.sh.
#
#    Widen the POLICY's contents, not the role's allowed_policies.
#    Policy contents are evaluated per request and take effect on the
#    next reconcile; a role property change is frozen at token-creation
#    time and silently does nothing for up to the 1h ttl - which looks
#    exactly like "the policy did not work".
```

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
