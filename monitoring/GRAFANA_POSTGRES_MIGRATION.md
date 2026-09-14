# Grafana → Postgres (CloudNativePG) migration

**Status: COMPLETE.** Executed 2026-05-19 → 2026-05-20; re-verified
2026-09-13. Kept as a record of why the backend changed and what the
migration actually did. See [Outcome](#outcome) for verified end state.

## Why
Grafana stored everything in a single SQLite file on a Longhorn
(network) block device. A brief pod-network blip on 2026-05-19 stalled an
in-flight write, wedged the SQLite journal, and left the db unreadable
(`unable to open database file: input/output error`). That broke token
validation, alert evaluation (causing a false "Longhorn backup in error"
page via `exec_err_state: Alerting`), and the MCP. Restarting didn't help
because the new pod fought the old one for the single RWO volume.

Postgres fixes the class of problem:
- Grafana talks to PG over a connection → network blips become retried
  query errors, not file corruption.
- PG WAL + crash recovery is built for storage stalls.
- CNPG gives replication + failover.
- Grafana's pod becomes **stateless** (no PVC) → restarts are clean, so a
  liveness probe becomes a safe self-healing mechanism instead of a
  footgun.

## Starting state (pre-migration)
- Grafana: `monitoring/grafana-local-cr.yaml`, operator-managed Grafana CR
  `local`, backed by `local-pvc` (1Gi longhorn, SQLite).
- CNPG operator installed (`cloudnativepg` app); one demo cluster
  `pg-test/test-db` (single instance, unused).
- Pattern for CNPG clusters: `cloudnative-pg-clusters/*.yaml` + an Argo app.

## What does NOT auto-migrate
- **Dashboards / datasources**: GitOps-provisioned (GrafanaDashboard /
  GrafanaDatasource CRs). Repopulate automatically on the new backend. ✓
- **`claude-mcp` service account + token**: NOT in Git. Lives only in
  SQLite. A backend swap orphans it → **MCP breaks until a new token is
  issued and written to Vault `kv/grafana-local/mcp_token`.** Must be
  re-created post-migration. (This is the main gotcha.)
- **Any manually-created users / API keys / annotations / alert silences**:
  lost unless explicitly migrated.

## Decision: fresh start vs. data migration
RESOLVED 2026-05-19: the Longhorn alert rules are **UI-created** — there
are zero `GrafanaAlertRuleGroup` CRs in the repo and zero live in the
cluster (`kubectl get grafanaalertrulegroups -A` → none). They exist only
in Grafana's SQLite db. Dashboards/datasources ARE GitOps-provisioned and
repopulate automatically; alert rules and the `claude-mcp` service account
do NOT.

DECISION 2026-05-19: alerts will stay **UI-managed** (user's call — fine
since CNPG backups make them durable, and converting to CRs isn't worth
the friction yet; revisit if UI management starts to hurt).

SUPERSEDED: the rules were later converted to `GrafanaAlertRuleGroup` CRs
anyway — see `monitoring/grafana-alertrules-*.yaml`. They are now
Git-managed, so this migration's "alert rules only live in SQLite" risk no
longer applies to future backend work.

Because we're keeping the UI-created rules, do a **data migration**, not a
fresh start — a fresh start would force recreating every rule by hand.

### Path: SQLite → Postgres data migration
Carry the existing db content (alert rules, `claude-mcp` service account,
any users/annotations) across so nothing is lost.

Options for the actual copy:
- **`pgloader`** — purpose-built sqlite→postgres migrator. One-shot job:
  point it at the SQLite file (copy it out of the PVC first) and the new
  PG database. Handles schema + data type translation.
- **Grafana's own approach** — stand up Grafana pointed at the new empty
  PG, then use the HTTP API / `grafana-cli` to export from old and import
  to new. More manual, more moving parts. Prefer pgloader.

Sequence: scale Grafana to 0 (releases SQLite + quiesces writes) → copy
grafana.db out → pgloader into the CNPG `grafana` database → point Grafana
config at PG → scale up → verify rules + service account present.

NOTE: this preserves the `claude-mcp` token IF pgloader copies the
service-account token tables intact. Verify post-migration that the MCP
still authenticates; if not, re-issue the token (Vault
`kv/grafana-local/mcp_token`) as a fallback.

## Steps

### 1. Create a Grafana Postgres cluster (CNPG)
New file `cloudnative-pg-clusters/grafana-db.yaml`:
- namespace `monitoring` (or keep in a pg namespace and cross-namespace
  the connection — same-namespace is simpler)
- `instances: 2` (primary + replica for failover — the whole point)
- `storage.storageClass: longhorn`, size ~2Gi
- `bootstrap.initdb` with database `grafana`, owner `grafana`
- CNPG auto-creates a secret `grafana-db-app` with the connection creds

### 2. Point Grafana at Postgres
In `grafana-local-cr.yaml`, add to `spec.config`:
```yaml
database:
  type: postgres
  host: grafana-db-rw.monitoring.svc:5432   # CNPG -rw service
  name: grafana
  user: <from secret>
  # password via GF_DATABASE_PASSWORD env from the CNPG app secret
  ssl_mode: require
```
Inject `GF_DATABASE_PASSWORD` (and user) as env from the CNPG-generated
`grafana-db-app` secret, same pattern as the existing admin/SMTP env refs.

### 3. Remove SQLite volume coupling
- Drop the `local-pvc` volume + volumeMount override from the deployment
  spec in the CR (Grafana no longer needs persistent storage).
- Leave the PVC itself for now (delete after confirming PG works, so we
  have a rollback).

### 4. Re-add the liveness probe (now safe)
Stateless pod → no mount contention. Use upstream defaults:
```yaml
livenessProbe:
  httpGet: { path: /api/health, port: 3000 }
  initialDelaySeconds: 60
  timeoutSeconds: 30
  failureThreshold: 10
```

### 5. Recreate the claude-mcp service account token
After Grafana is up on PG:
- Recreate the `claude-mcp` Admin service account (or let it be
  auto-created if provisioned).
- Issue a new token, write to Vault `kv/grafana-local/mcp_token`.
- ESO syncs it into the `mcp-grafana` secret; restart `mcp-grafana`.

### 6. Cutover sequence (minimize downtime + keep GitOps honest)
- Because app-of-apps auto-sync reverts manual edits, do this via Git:
  commit cluster + CR changes together, push, sync app-of-apps → monitoring.
- Grafana pod rolls, connects to PG, comes up empty, GitOps re-provisions
  dashboards/datasources/alert-rules.
- Verify: `/api/health` db=ok, alert rules present + normal, MCP token
  re-issued and working.

### 7. Cleanup (after a few days of stability)
- Delete `local-pvc` and its Longhorn volume.
- Remove the demo `pg-test/test-db` cluster if it was only a placeholder.

## Rollback
Keep `local-pvc` until confident. To roll back: revert the CR `database`
config + restore the volume/volumeMount, sync. SQLite data is untouched.

## How the open questions resolved
1. **Git- or UI-provisioned alert rules?** UI-created — zero
   `GrafanaAlertRuleGroup` CRs existed at the time. This forced a data
   migration over a fresh start. (Since then the groups *have* been moved
   into Git: `monitoring/grafana-alertrules-*.yaml`, 6 files / 15 rule
   titles. Note Git holds 15 but only 12 are live in 5 groups — the
   `ingress` group (3) is disabled pending the chart's `metrics.enabled`
   (see commit `edb1200`).)
2. **Namespace?** Same-namespace `monitoring`, as the simpler option.
3. **`instances: 2`?** Confirmed fine; running 2/2 since.

## Outcome

The migration succeeded and **the main gotcha never materialized**: the
doc predicted the `claude-mcp` service account + token lived only in
SQLite and would be orphaned, requiring a fresh token written to Vault
`kv/grafana-local/mcp_token`. pgloader carried the service account and
its token across intact — **no token re-issue was needed**, and the Vault
fallback went unused.

Verified 2026-09-13 (~117 days after cutover):

| Check | Result |
|---|---|
| CNPG `grafana-db` | Healthy, 2/2 instances, primary `grafana-db-2` |
| Grafana `/api/health` | `"database": "ok"`, v12.4.1 |
| Alert rules | 12 rules across 5 groups (longhorn 4, infrastructure 3, nodes 2, secrets 2, certs 1) |
| `claude-mcp` service account | Survived as `sa-1-claude-mcp` (user id 2), token `claude-mcp-token` |
| MCP auth | Works — authenticates as `service-account:2`, reads all 12 rules |
| Dashboards / datasources | 4 dashboards + 2 datasources, "successfully applied to 1 instances" |

Follow-ups from the plan that were completed: the SQLite `local-pvc` was
dropped (commit `e9c51e4`) once PG was confirmed good, and the liveness
probe was re-added now that the pod is stateless.

### Gotchas when verifying
- Counting rows in the legacy `dashboard` table reads 0 and looks alarming.
  Grafana 12 keeps operator-provisioned dashboards in unified storage; check
  the Grafana CR's `.status.dashboards` instead.
- `kubectl get grafanadashboard` prints a "NO MATCHING INSTANCES" column that
  renders blank/misleading; the CR's `.status.conditions` is authoritative
  ("Dashboard was successfully applied to 1 instances").
- Service-account tokens live in `api_key` (joined to `"user"` via
  `service_account_id`); there is no `service_account_token` table.
