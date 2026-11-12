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
  worker. The busy lock already works this way, so this is a modest
  change rather than a rewrite.
- **Remote Control sessions.** Workers are anonymous, so the
  `pod0-author` naming that tells you which agent is doing what would
  be lost. Either name the session after the card it picked up, or keep
  one long-lived pod for attaching that never does stage work.
- **The go-build cache.** 1.4GB per session pod today, regenerable but
  not free. An ephemeral worker starts cold.
- **Transcripts.** `.claude/projects` is ~79MB of session history. A
  resumed card currently has it; an ephemeral worker would not.

## Remote Control naming, resolved

Listed above as undecided; it is not. `claude --remote-control` has a
second flag the current entrypoint does not use:

```
--remote-control-session-name-prefix <prefix>
    Prefix for auto-generated Remote Control session names
    (default: hostname)
```

The default prefix is the **hostname**, which in a StatefulSet is the
pod name. So a worker's session self-labels as `claude-worker-0`
without anyone maintaining a role table, and the ordinal is enough to
tell two live sessions apart.

What this does *not* give you is which card a worker is working. The
name is fixed when the RC process starts, and that process runs under
`while true; do claude --remote-control ...; done`, so changing it
means killing the loop and dropping any attached connection. Naming a
session after its current card is therefore not free, and is probably
not worth it: the card is visible on the Kaneo board, and the session
list only needs to answer "which worker is this".
