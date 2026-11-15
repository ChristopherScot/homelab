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
| A fourth k8s node added | A rescheduled pod may land on it, away from its volume, and sit Pending (storageclass.yaml); pin the three or add a fourth garage node | yes | yes |

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

Argo applies everything in this directory. The merge that introduced the
three-node layout pruned the old single-node `garage` StatefulSet and
created `garage-node` (see statefulset.yaml for why a rename). The pods
come up `0/3 Ready` and stay there until someone runs:

```sh
./bootstrap/garage-init.sh
```

It waits for the three nodes to discover each other, assigns each a zone
named after its k8s node, applies the layout, creates `claude-reference`,
and imports the two S3 keys from the Secrets Vault already projects into
`claude-pods` - so nothing that holds those credentials needs to change.
Then re-seed the bucket from a session pod's home:

```sh
kubectl scale statefulset claude-session -n claude-pods --replicas=0
kubectl apply -f claude-pods/worker/seed-reference-job.yaml
kubectl logs -n claude-pods job/seed-reference -f
```

and finally delete the old single node's volumes, which Argo deliberately
left behind (reclaim is Delete; the data in them is the same
re-seedable reference material):

```sh
kubectl delete pvc -n garage data-garage-0 meta-garage-0
```

Once that has happened, this section is a plain "run garage-init.sh,
then seed" and the rest of it can go.

## Re-admitting a node after its disk was lost

A node's identity is a key pair on its `meta` volume. A fresh volume is a
new node with a new id, and the old id is still in the layout. From any
pod:

```sh
garage status                        # new id appears with NO ROLE ASSIGNED,
                                     # old id under FAILED NODES
garage layout assign -z <k8s node> -c 30Gi --replace <old id> <new id>
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
  with the RO/RW split, then one pod is killed and the other two keep
  serving writes. Needs a cluster; SKIPs in CI.
