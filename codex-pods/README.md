# Codex pod

`codex-session-0` runs in `codex-pods`, with its own home and workspace PVCs,
service accounts, SecretStore, and secrets. It uses the existing tooling image
and GitHub account in Vault, with a pinned
Codex CLI installed by an init container. No new image build or CI job is needed.
The `codex-pods` Argo CD Application owns its deployment.

On startup it checks ChatGPT authentication, verifies GitHub repository access,
clones `ChristopherScot/homelab`, and asks Codex to execute `printf CODEX_POD_TOOL_OK`
outside the repository. Readiness requires a successful shell-tool event with
that output in Codex's JSONL events, plus the final `CODEX_POD_OK` response. A
chat-only response cannot pass the check. The pod then waits
for work. No Kubernetes service account token is mounted in the Codex container.

## Daily Dependabot repair

The `codex-dependabot` Kubernetes CronJob runs daily at **06:00 America/New_York**.
Its trigger has permission only to inspect and exec into `codex-session-0`.
The work runs there, using the existing writable ChatGPT login and the mounted
GitHub credential, whose Schoolhouse repository/CI read access was verified.
The narrower PAT used by the other repair pod lacks Actions and Checks access.

The startup probe and daily repair/review processes use `--sandbox danger-full-access`
inside this unprivileged container. The pod cannot create Bubblewrap's nested
mount namespace, so the container is the isolation boundary for these trusted
repository runs, as described in the [official container guidance](https://learn.chatgpt.com/docs/agent-approvals-security).
This adds no privileged container, host mount, Kubernetes API token, or Linux
capability. The reviewer is instructed not to edit; the runner also checks that
the working files, staged tree, and HEAD have not changed during review. The
resulting commit must contain that exact reviewed tree and parent before a push.
Other
Codex invocations retain the configured default permissions.

The runner lists open Dependabot PRs in **schoolhouse-world/app**, selects those
with completed failing checks, and skips drafts, forks, green checks, and checks
still in progress. It works oldest PR first in a checkout reserved for this job,
preserving ignored dependency caches between PRs. It asks Codex to read the CI
logs, make a focused repair that preserves the dependency upgrade, and run the
relevant checks. Missing services, memory, or credentials result in a failed
attempt rather than a claimed pass. The container memory limit is **4 GiB**;
its scheduling request remains 512 MiB. The original 2 GiB limit was exceeded
during dependency installation in a real run.
Yarn's heavy-task pool is limited to two workers and network concurrency to eight;
Node subprocesses default to a 1024 MiB old-space heap cap. These settings avoid
sizing Yarn's pool from all eight visible node CPUs. The prompt keeps the agent
from raising them to larger CI settings. The heap cap is per Node process, not
a limit on total container memory. See [Yarn's container sizing guidance](https://yarnpkg.com/configuration/yarnrc#taskPoolConcurrency).

A separate Codex process reviews the exact staged patch and the repair's test
log. The runner publishes only after passing validation and approval with no
findings. It rechecks that the PR is open, still failing, and still at the
original head. It commits and pushes normally to that Dependabot branch so
GitHub CI reruns; concurrent branch updates reject the push. It never merges,
force-pushes, creates PRs, or posts comments. Workflow edits require human review.

Runs hold `/tmp/codex-task.lock`, also reserved for future Kaneo work, so task
sources cannot overlap in the pod. Each repair is limited to 30 minutes, each
review to 15 minutes, and a daily run to six hours. `concurrencyPolicy: Forbid`
also prevents overlapping CronJobs. Cancellation terminates the active agent's
process group, including remaining members of that group, before releasing the
task lock. Children that deliberately create separate sessions are outside this
process-group guarantee.
Results and private agent logs persist in
`/workspace/.codex-dependabot/run-*`; container logs contain progress summaries
and are visible to Loki. Failed attempts make the job fail after it tries the
remaining candidates. No Kaneo hook behavior is configured yet.

`bash /etc/codex-pod/daily-dependabot.sh --dry-run` only discovers candidates;
it makes no model calls, checkouts, commits, or pushes. Tests use a local bare
Git remote and simulated agents to verify that rejected reviews, moved heads,
reviewer edits, and workflow edits cannot publish a repair:

```sh
node --test codex-pods/tests/dependabot.test.mjs
```

## Authentication

The Vault KV v2 path `kv/codex-pods/auth`, property `auth_json`, holds the
initial ChatGPT login cache. `codex-auth-seed` syncs it through the existing
`vault-codex-pods` SecretStore. Credentials never belong in this repository.
`bootstrap/codex-vault.sh` declares the namespace-scoped Vault Kubernetes role
and its read-only policy. It is also called by `bootstrap/vault-policies.sh`.

The seed must come from a **separate OAuth login reserved for this pod**, not a
copy of a laptop login that remains in use. Two machines refreshing the same
credential bundle can invalidate each other's authentication. Create the pod's
login with an isolated `CODEX_HOME` and file-based credential storage, complete
its OAuth authorization, and seed that cache into Vault. Stop using that
isolated login locally after transferring it to the pod. Browser sign-in or
human verification may be required for that initial authorization.

The entrypoint copies the seed only if `$CODEX_HOME/auth.json` is absent. Codex
refreshes that writable file on the home PVC, which must survive restarts.
The original Vault seed does not track refreshed tokens and must not overwrite
the PVC copy. If the home PVC is lost, seed Vault with a current login before
recreating the pod. A revoked or expired login may require authenticating again;
this does not bypass ChatGPT plan limits or account policies.

Official documentation: [headless authentication and login caching](https://learn.chatgpt.com/docs/auth?surface=cli).
See also [one refresh stream per credential bundle](https://learn.chatgpt.com/docs/auth/ci-cd-auth).

## Use and inspect

Deployment changes go through a PR, merge, and Argo CD reconciliation.
Read-only checks:

```sh
kubectl get pods -n codex-pods -l app=codex-session
kubectl logs -n codex-pods codex-session-0 -c codex
```

Once ready, Codex is available inside the pod at `/opt/codex/node_modules/.bin/codex`.
The repository is `/workspace/homelab`; the writable login cache and session
state are under `/home/node/.codex`. Future task dispatch is intentionally
left unconfigured until its behavior is specified.
