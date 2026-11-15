# Garage

In-cluster S3. Three nodes, one per k8s node, every object on all three.
Clients talk to `http://garage.garage.svc.cluster.local:3900` with the
region `garage`; see [PERMISSIONS.md](PERMISSIONS.md) for how a consumer
gets a key.

## Where the redundancy lives

Garage replicates; Longhorn does not. Each pod's two volumes are on
`longhorn-garage` - one replica, pinned to the pod's node - and the three
pods are forced onto three different nodes, each its own zone in the
layout. storageclass.yaml has the argument for why the replication is
Garage's and not Longhorn's. What it buys, by event:

| Event | What happens | Reads | Writes |
|---|---|---|---|
| One node (or its pod) down | Other two have quorum; the pod waits for its node | yes | yes |
| Two nodes down | Survivor has no quorum; `/health` fails, it leaves the Service | no | no |
| Whole-house power cut | All three restart, rediscover each other within a minute, resync | after rejoin | after rejoin |
| One node's disk lost | Node comes back as a stranger; re-admit it (below), Garage re-replicates | yes | yes |
| A fourth k8s node added | Existing volumes retain their host affinity; Garage remains on its original three nodes | yes | yes |

Both `metadata_fsync` and `data_fsync` are on, because the nodes share
one mains supply and "a node lost power" is usually all of them.

## Longhorn's own policies, and what they mean here

The volumes are in Longhorn's `default` recurring-job group: a daily
snapshot (keep 3) and a weekly backup to the NFS target on node2 (keep
4). That was left as is. For a replicated store the backup is a safety net
against the thing replication does not cover - an operator or a bug
deleting objects - not against hardware. Be clear about what a restore
is: three volumes restored from the same week's backups give Garage a
cluster whose tables merge (they are CRDTs) and whose blocks it
re-checks, which is recoverable but not a point-in-time. A bucket whose
contents cannot be re-created deserves an S3-level copy (rclone from the
bucket to the Synology, one copy, not three); none does yet.

Single-replica strict-local volumes never rebuild, so the snapshot-chain
cost that longhorn-settings/config.yaml describes does not apply to them.

## Capacity

30Gi per node, which at `replication_factor 3` is 30Gi usable. Sized to
node2, which had 47Gi of Longhorn headroom when this was written. The
init script reads each node's capacity from its data PVC, so there is one
place it is declared. To grow a running cluster:

1. Expand all three `data-garage-node-N` PVCs (the class allows it).
2. For each node, `garage layout assign -c <new size> <node id>`, then
   the `garage layout apply --version N` that `garage layout show` prints.

Change the size in statefulset.yaml too, for the next fresh cluster: a
volumeClaimTemplate is only read when a PVC is created.

## Bringing it up (and the one-time move from the single node)

Argo replaces the single-node StatefulSet and switches the `garage`
Service to the new pods when this PR merges. Perform this cutover while
an operator is available; clients cannot use the bucket until bootstrap
and restore finish.

1. Pause bucket writers. Preserve **all** objects from the existing
   `claude-reference` bucket outside the cluster and outside Git. Record
   the object keys, sizes and SHA-256 hashes of the downloaded contents.
   Confirm the download matches the live inventory before merging.
2. Confirm Vault's three ExternalSecrets are Ready and each node has
   room for 33Gi of new volumes. Retain `data-garage-0` and
   `meta-garage-0` throughout the migration.
3. Merge and wait for all three `garage-node` pods to run. They remain
   unready until `./bootstrap/garage-init.sh` assigns the layout. This
   script imports the existing consumer credentials from Vault-backed
   Kubernetes Secrets, so clients keep their current credentials.
4. Upload the preserved objects using the seed credential. Download the
   new bucket again and compare every key and SHA-256 hash with the
   pre-cutover snapshot. Job completion or an object count alone is not
   sufficient verification.
5. Verify the worker credential can read the reference material and
   cannot write; verify the seed credential can write and delete a test
   object. Confirm all three pods are Ready and Argo is Healthy/Synced,
   then resume writers.

Keep the original PVCs and the snapshot until a separate cleanup. If
cutover fails, revert the manifest change through Git, restore the
single-node StatefulSet against its retained PVCs, and confirm its
bucket before resuming consumers.

For a fresh installation with no existing bucket, initialize the layout
and use `claude-pods/worker/seed-reference-job.yaml` to populate it from
`home-claude-session-0`. The session StatefulSet must be at zero replicas
while that RWO volume is mounted by the seed job. Verify the expected
source directories and contents: the seed job skips missing directories.

## Re-admitting a node after its disk was lost

A node's identity is a key pair on its `meta` volume. A fresh volume is a
new node with a new id, and the old id is still in the layout. From any
pod:

```sh
garage status                        # new id appears with NO ROLE ASSIGNED,
                                     # old id under FAILED NODES
garage layout assign -z <k8s node> -c <size of its data PVC> --replace <old id> <new id>
garage layout show                   # prints the apply command
garage layout apply --version N
```

Garage then copies that node's share from the other two. Nothing else
changes: the bucket, keys and grants live in the replicated tables.

## Tests

- `tests/manifests.sh` - the invariants above, against the committed
  files. Runs in CI.
- `tests/cluster-smoke.sh` - the same manifests rendered into a scratch
  namespace with small volumes: three nodes on three k8s nodes, replicas
  on the right nodes, `garage-init.sh` lays it out, an S3 round trip
  with the RO/RW split, then each peer is removed in turn and every
  surviving pair reads existing objects and accepts new writes. Finally
  all pods restart on their original hosts. Set `GARAGE_SMOKE_RUN=1` to
  run; SKIPs in CI. These are Garage peer failures, not host shutdowns.
- `tests/bootstrap.sh` - executes bootstrap against a stateful kubectl
  substitute, including interrupted layout apply, failed lookups,
  credential import errors, and repeat execution. Runs in CI.
