# Worker and node memory protection

Claude workers keep their existing 2 GiB cgroup limit and now reserve all 2 GiB
with the scheduler. Preferred anti-affinity spreads them without making one
unavailable node block all three dispatcher stages. Pod environment defaults
reduce compiler/test fan-out; managed `/etc/claude-code/CLAUDE.md` tells agents
to batch required work sequentially, preserve work on resource failures, and
report operations that cannot fit. Heap targets are per process, not pod caps.

## What happened on 2026-11-16

At 16:55:28 UTC node1 became unavailable. Kaneo's database primary and the
External Secrets validating webhook were on it: Kaneo failed database
connections and restarted, while Argo reported a webhook with no endpoints.
The webhook moved to pop-os at 17:01:10 and CNPG promoted kaneo-db-2 there at
17:01:48. Node1 became Ready at 17:15:24.

Grafana/VictoriaMetrics samples before the outage show node1's Claude worker
at roughly 130–150 MiB working set, not near its 2 GiB cap. The host OOM-kill
counter stayed at 1382 and boot time did not change. Host syslog shows k3s
losing scheduler leader election at 17:14:49, exiting with status 1 and
restarting. Etcd requests were timing out and Raft send buffers filled.
Those establish the failure path, not the underlying reason for the stall.

There was memory contention: available host memory reached about 0.93 GiB,
memory PSI waiting reached 34%, and about 1.3 GiB was swapped. Longhorn's
instance manager (~1.69 GiB), Alloy metrics (~951 MiB) and media workloads
were much larger consumers than Claude. The evidence does **not** establish
that Claude caused this incident, or that memory safeguards alone prevent
every recurrence.

The node1 kubelet `/configz` nevertheless exposed a concrete protection gap:
no `systemReserved` or `kubeReserved`, and an `evictionHard` map containing
only `nodefs.available=5%` and `imagefs.available=5%`. Memory eviction was
absent. `bootstrap/k3s-memory.py` adds 512 MiB system and 1536 MiB Kubernetes
scheduling reservations, plus a 512 MiB memory eviction threshold. It retains
existing disk thresholds and non-memory reservations and supplies inode
thresholds if missing. It does not enforce hard limits on system daemons.

## Rollout

The worker template is GitOps-managed. Its existing rolling-update partition
of 3 is retained: running jobs keep their current image and resources until
the normal idle sleep/wake cycle recreates the pods. The sleep must reach zero
pods and matching StatefulSet `currentRevision` / `updateRevision`; a wake
racing teardown can retain the previous revision. Wait for the image build
and image-updater digest before checking the new pods. Verify the 2 GiB
request/limit, environment defaults, and `/etc/claude-code/CLAUDE.md` in each.
No active worker should be deleted to accelerate this rollout.

The host configuration needs a separate maintenance rollout; merging does
**not** apply it. Use one node at a time, starting with a node that is not
hosting Kaneo's primary, and wait for cluster/storage health before continuing.

1. Install `python3-yaml` on the host. Check effective service arguments and
   environment locally for `--kubelet-arg`, `K3S_KUBELET_ARG` or an alternate
   `--config` / `K3S_CONFIG_FILE`; CLI arguments override YAML. Consolidate
   any overrides into the chosen file before proceeding. Do not paste secret
   values from the service environment into logs or PRs. The helper rejects
   YAML drop-ins and external kubelet config rather than guessing precedence.
2. Check current requests, real memory consumption and worker activity.
   Reservations plus eviction reduce allocatable memory by **2.5 GiB**.
   At investigation time container requests were ~2.1/5.6/3.7 GiB on
   node1/node2/pop-os; one worker per node adds 1.5 GiB to those requests.
   This fits their ~11.6/11.6/15.5 GiB capacity, but recheck init-container
   reservations, pending pods, and live placement before rollout. Also include
   **desloppify's scheduled 8.25 GiB request** (7 GiB worker plus native
   sidecars), even while it is asleep. With three workers spread across the
   observed placement, no node has 8.25 GiB free after these reservations.
   Desloppify must wait for workers to finish and sleep, or workloads must be
   relocated / capacity added before host rollout if simultaneous execution
   is required. Soft affinity permits placement on fewer nodes but does not
   repack already running pods. Do not force-delete working pods to make room;
   check that the scheduled job can eventually start when workers sleep.
3. Let workers on the selected node finish and sleep. Cordon that node, and
   use the existing storage/database maintenance procedure before restarting
   its control plane. Never restart multiple control-plane nodes together.
4. Preview locally: `sudo python3 bootstrap/k3s-memory.py`. The rendered
   config may contain existing secrets; do not publish it. Apply with
   `sudo python3 bootstrap/k3s-memory.py --write`. The original is retained as
   `/etc/rancher/k3s/config.yaml.before-memory`; no service is restarted.
   Archive an existing backup before a subsequent, different config change.
5. Restart this node's k3s during the maintenance window. Wait for it to become
   Ready, verify `/api/v1/nodes/<node>/proxy/configz` contains the reservations
   and memory eviction, and check reduced `.status.allocatable.memory`.
   Check Kaneo HTTP responses, CNPG primary/replicas, Longhorn volume health,
   Argo sync and node memory pressure before uncordoning and moving on.

Hard eviction is a last resort and can interrupt a pod without its normal
checkpoint grace period. The full worker request and conservative tool
defaults are intended to avoid reaching it. Some workloads genuinely need
more than 2 GiB and must report that constraint rather than repeatedly OOM.

To roll back a host, restore its `.before-memory` backup and restart k3s in
the same one-node maintenance sequence. To roll back worker defaults, revert
the template/image change and wait for idle recreation. The network helper
`k3s-config.sh` now preserves configuration and applies these same safeguards,
so a future interface change cannot silently erase them.

## References

- [Kubernetes node reservations](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [K3s configuration precedence](https://docs.k3s.io/installation/configuration)
- [Claude managed memory](https://code.claude.com/docs/en/memory)
