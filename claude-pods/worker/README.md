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

## The remaining step

Garage mints the S3 key, so it cannot be generated ahead of time:

```sh
# 1. print the credentials
./bootstrap/garage-init.sh

# 2. seed Vault with the READ-ONLY key (claude-worker)
vault kv put kv/garage/s3-reference \
  access-key-id=<Key ID> secret-access-key=<Secret key>

# 3. and the RPC secret, deleting the hand-made one first -- External
#    Secrets will not adopt a Secret it did not create
kubectl delete secret garage-rpc -n garage
vault kv put kv/garage/rpc rpc-secret="$(openssl rand -hex 32)"

# 4. grant the claude-pods vault role read on kv/garage/s3-reference
#    (that role is not managed by bootstrap/vault-policies.sh)
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
- **The go-build cache.** 1.4GB per session pod today, regenerable but
  not free. An ephemeral worker starts cold.

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
  `~/` or `.claude/` in nightly-author.sh, nightly-merge.sh or
  nightly-test.sh. They need their lib (in the image) and
  `/workspace/<repo>` (which a worker clones). So an ephemeral worker
  with no persistent home can run them unchanged - this was the last
  structural unknown.
- **Workers can be interchangeable.** See the podWorksRepo note above.
- **Cloning on demand beats carrying clones.** 1s and 3.2MB shallow,
  against 153MB of warm clones per pod.
- **Garage adoption works.** Argo adopted the hand-applied StatefulSet
  rather than fighting it; the pod rolled once on a spec change and the
  layout, bucket and keys survived on their PVCs.
