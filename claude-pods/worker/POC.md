# Garage + ephemeral workers: what was built, what was faked

Written 2026-11-12, after a night of building. This is the honest
account: what runs, what is a shortcut, and what the real thing should
look like. Numbers here were measured on the cluster unless the text
says otherwise.

---

## Why any of this

Three `claude-session` pods are pinned to roles by StatefulSet ordinal -
pod0 authors, pod1 merges, pod2 tests. Ordinals are dense, so **waking
the tester wakes all three**, and each carries ~4.4GB of per-pod state.
The goal was workers that scale independently.

Four constraints, all from the user, all load-bearing:

1. **Roles must scale independently.** Hard requirement.
2. **Books must never reach git.** They are copyrighted texts that today
   live only on a home PVC - not in git, not in the image, not in a
   secret.
3. **No shared writable storage.** A worker must not be able to see or
   edit another's files.
4. **Everything scales to zero when idle.**

(2) rules out ephemeral workers *unless* reference material comes from
somewhere. (3) rules out a shared read-write volume. Object storage
satisfies both: each worker pulls its own copy over HTTP, so there is no
filesystem to share, and a read-only credential makes the write
isolation structural rather than a convention.

---

## Architecture

```
                   ┌─────────────────────────────────┐
                   │ garage (namespace: garage)      │
                   │   StatefulSet, 1 replica        │
                   │   meta  PVC  2Gi  single-ssd r=1│
                   │   data  PVC 10Gi  longhorn   r=2│
                   │   bucket: claude-reference      │
                   │     1801 objects, 71.4 MB       │
                   │   keys:                         │
                   │     claude-worker  R            │
                   │     claude-seed    RW           │
                   └───────────┬─────────────────────┘
                               │ S3 over HTTP (no mount)
          ┌────────────────────┼────────────────────┐
          │                    │                    │
   ┌──────▼──────┐      ┌──────▼──────┐      ┌──────▼──────┐
   │ worker (Job)│      │ worker (Job)│      │ seed (Job)  │
   │ init: pull  │      │ init: pull  │      │ uploads from│
   │   74M → /ref│      │   74M → /ref│      │ a session   │
   │ main: stage │      │ main: stage │      │ pod's home  │
   │ NO PVCs     │      │ NO PVCs     │      │ RW key      │
   └─────────────┘      └─────────────┘      └─────────────┘
```

**Why Garage and not MinIO:** MinIO was tried here before and never
worked - its Services are still orphaned in the `minio` namespace with
no endpoints, 716 days on. Garage is one binary, SQLite metadata, no
operator.

**Why `replication_factor = 1`:** Garage's docs warn against it for
production data. Correct trade here - the bucket holds hand-seeded
reference material that can be re-seeded in minutes.

---

## Flow, as it ran

1. **Seed** (manual, rare). `seed-reference-job.yaml` mounts
   `home-claude-session-0` read-only and `aws s3 sync`s books, skills
   and plugins into the bucket with the **RW** key. Measured: 1801
   objects, 71.4 MB.
   Requires the session pods at 0 replicas - the PVC is RWO.
2. **Worker starts.** An init container pulls the whole bucket into an
   `emptyDir` with the **read-only** key. Measured: **74M in 7s, 1801
   files**.
3. **Stage runs** in the main container against `/ref`, with its own
   writable copy.
4. **Worker exits.** Nothing is left attached.

---

## Measured

| | |
|---|---|
| Seed upload | 1801 objects, 71.4 MB |
| Worker pull | 74M in **7s** |
| &nbsp;&nbsp;↳ books (609 files, 48M) | 2.3s (~21 MB/s) |
| &nbsp;&nbsp;↳ skills+plugins (1192 files, 26M) | ~4.3s - **per-object overhead, not bandwidth** |
| Job apply → container running | **1.4s** |
| S3 round trip (1 object) | up 632ms, down 578ms, byte-identical |
| Session pod, scheduled → started | **41s**, of which ~28s is Longhorn attach |
| PVC-free worker, scheduled → started | **same second** |

Concurrency tuning (`AWS_MAX_CONCURRENT_REQUESTS=50`) bought 0.6s of the
7s, confirming the small-file cost is round trips rather than parallelism.

---

## Shortcuts taken

**These are the reasons the PoC is not the real thing.**

### 1. Credentials are hand-made, not from Vault
`garage-s3-poc`, `garage-s3-seed` (claude-pods) and `garage-rpc`
(garage) were created with `kubectl create secret` from keys Garage
minted. The Vault-backed ExternalSecrets exist in git and **all three
are failing** - `garage-rpc` because the `garage` Vault role does not
exist, the other two with a **403** because the `claude-pods` role has
no read on `kv/garage/*`.

The RW key copy was explicitly authorised by the user for the test, to
be rotated.

### 2. The dispatcher was bypassed entirely
The PoC is a Job applied by hand. It never went through the dispatcher,
never scaled anything, never waited on `rollout status`. **The
worker-dispatch path does not exist.** Any end-to-end number that
includes dispatch is unmeasured.

### 3. The worker runs a toy payload
`poc-worker-job.yaml`'s main container is `busybox` printing file
counts. It has never run a real stage script against a real card.

### 4. `garage-rpc` will not be adopted
It has none of External Secrets' ownership markers and the
ExternalSecret defaults to `creationPolicy: Owner`, which refuses to
adopt a Secret it did not create. **Seeding Vault without deleting it
first leaves the ExternalSecret in SecretSyncError while Garage keeps
running on the stale value** - a failure that pages nobody.

### 5. The Argo app is Degraded
Expected, and caused entirely by (1). Everything else is Synced.

### 6. The live layout advertises 9.3 GiB, not 10
It was applied while `garage-init.sh` defaulted to `10G` (decimal)
against a `10Gi` (binary) PVC. The script says `10Gi` now, but the
layout step short-circuits on an already-assigned cluster, so the fix
is not retroactive. Harmless at 71 MB of use.

### 7. Single node, single meta replica
`meta-garage-0` is `numberOfReplicas: 1` on `longhorn-single-ssd`,
co-located with the pod. Meta holds the bucket, the keys and the
object→block map, so **losing it makes the 2-replica data volume
unreadable**. Recovery is re-run `garage-init.sh` and re-upload - which
mints a *new* access key and stales `kv/garage/s3-reference`.

---

## Punch list

**Blocking the real thing**

- [ ] Run `./bootstrap/vault-policies.sh` - creates the `garage` role
      and clears the Degraded app
- [ ] Seed `kv/garage/rpc`, `kv/garage/s3-reference` (read-only key) and
      `kv/garage/s3-seed` (RW key)
- [ ] Grant the `claude-pods` Vault role read on `kv/garage/*` - **the
      policy's contents, not the role's `allowed_policies`**, which is
      frozen at token creation and silently does nothing for up to 1h
- [ ] Delete the hand-made `garage-rpc` **only after** the ExternalSecret
      reports `SecretSynced/True`
- [ ] Rotate `claude-worker` and `claude-seed`, and delete
      `garage-s3-poc` / `garage-s3-seed`
- [ ] Build the dispatcher change (see DISPATCH.md) - six edit points
      across two dispatch paths
- [ ] Run a real stage in a worker, not busybox

**Worth doing**

- [ ] Merge #175 (wrapper error handling) and #176 (PoC result)
- [ ] Decide what `ORD` becomes - `entrypoint.sh:58` derives it from the
      hostname, which under a Job is a random suffix, so the repo-secret
      lookup and role assignment both **fail silently**
- [ ] ServiceMonitor + alert on Garage's admin port: the readiness probe
      is `tcpSocket`, so a Garage that is up but has lost its layout
      reads Ready and 500s every worker
- [ ] Decide how a worker's Remote Control session is named - anonymous
      workers lose the `pod0-author` labelling, and the flag I thought
      solved it does not (it prefixes a *random* name)

**Nice to have**

- [ ] Ship reference material as one archive instead of 1801 objects -
      ~4.3s of the 7s pull is per-object overhead
- [ ] Make the layout step reconcile rather than short-circuit, so
      changing `GARAGE_CAPACITY` has an effect
- [ ] `rpc_public_addr` is loopback: correct for one node, silently
      wrong for two

---

## How the real thing should work

### Workers

Ephemeral **Jobs**, one per card, no PersistentVolumeClaims. Role is a
runtime argument from the dispatch, not an identity. This is the user's
design and the PoC supports it.

What survives from the PoC: the init-container pull, the `emptyDir`, the
read-only key, exiting when done.

What has to change: a real stage script as the payload, and the ordinal
replaced with something explicitly passed in.

### Dispatch

`ROUTES` drops the pod name and keeps only the script. A
`claimIdleWorker()` creates a Job rather than scaling a StatefulSet.
`podIsBusy` already asks a pod rather than a role, so it needs no
change; `take_pod_lock` remains the arbiter of a claim race.

The thing to kill is `WAKE_REPLICAS`, which forces three pods awake for
one card because ordinals are dense.

### Credentials

Vault-backed throughout. Workers get the **read-only** key; only the
seed job gets RW. That split is already enforced in Garage - verified in
`garage bucket info`, not just intended.

### Reference material

Stays in Garage, seeded by hand. Books never enter git or an image
layer. If the 7s pull ever matters, ship an archive - but it is 7s
against a pod that does real work for minutes.

### What I would not do

**Do not give workers a shared writable volume**, even read-mostly. The
isolation here is structural - there is no filesystem to share - and
that is the property worth keeping.

**Do not put the layout step on a timer.** It is a cluster-level
decision with a version contract (`--version` must be exactly current+1)
and an automated applier that guesses wrong makes recovery harder.
