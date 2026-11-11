# Codex worker Jobs

Scheduled and manual runs use the same finite Kubernetes Job template in `codex-pods`. The Argo CD Application manages configuration. There is no idle worker pod or KEDA wake window.

## Manual runs

From the homelab repository:

```sh
./scripts/codex-run.sh
./scripts/codex-run.sh --follow
./scripts/codex-run.sh --status
```

The first command submits a one-off Job from the GitOps-managed `codex-dependabot` CronJob template and returns its name and log command. `--follow` starts a run and streams logs; closing the terminal only stops watching. `--status` lists runs. Job submission is a runtime action; configuration changes still go through PRs and Argo CD.

Each run starts its own pod. The container exits when the task succeeds or fails, releasing CPU and memory. A server-side six-hour task deadline plus 30 minutes for startup prevents an interrupted client from leaving it running forever. Finished Job/Pod records remain for one day, then TTL cleanup removes them. Login state, workspace, and logs remain on persistent volumes. The CLI is supplied by the worker image.

The helper refuses to submit while a worker Job is active. A lock on the home PVC covers installation, OAuth refresh, and the full task, protecting the login and shared checkout if submissions race. A second worker that encounters the lock exits without working. Scheduled overlap is also prevented by `concurrencyPolicy: Forbid`.

## Daily Dependabot repair

The CronJob runs at **06:00 America/New_York**. It scans open Dependabot PRs in **schoolhouse-world/app**, selecting same-repository branches with failed checks and none still running. Drafts, forks, and green PRs are skipped.

Codex reads CI logs, makes focused repairs that preserve the dependency upgrade, and runs relevant checks. A separate Codex process reviews the exact staged patch and execution log. The runner checks working files, staged tree, HEAD, current PR head, and committed tree/parent before a normal push to the original Dependabot branch. It never merges, force-pushes, creates PRs, or posts comments. Workflow changes require human review.

Yarn uses two heavy-task workers and eight network requests; Node subprocesses default to a 1024 MiB old-space heap cap. The pod limit is **4 GiB**, with a **512 MiB** scheduling request. Node prefers IPv4 and disables automatic address-family switching: the default 250 ms attempts failed against npm on the current cluster route, while a single IPv4 connection succeeded. These settings cover bootstrap npm and task subprocesses. The heap cap is per process, not total container memory. Missing resources and failed validation are reported rather than claimed as a pass.

Logs and summaries persist under `/workspace/.codex-dependabot/run-*`. `daily-dependabot.sh --dry-run` only discovers candidates, without model calls, checkouts, commits, or pushes.

## Startup and isolation

The worker locks its persistent state, verifies the image contains Codex CLI **0.167.0**, and configures the writable ChatGPT login. A missing or mismatched CLI fails startup immediately; startup never installs or updates it. It verifies GitHub access and requires a real successful shell-tool JSONL event for `printf CODEX_POD_TOOL_OK`, plus the final `CODEX_POD_OK` response, before running its task.

A dedicated `codex-pod` image adds the pinned CLI under `/opt/codex` to a digest-pinned copy of the existing development-tool image. The `codex-pod image` workflow builds and tests it with networking disabled and a fresh home directory before publishing. The Job references a published image digest through GitOps. The home PVC cannot shadow the image CLI; old cached CLI files are unused. The worker has no Kubernetes API token, host mounts, elevated capabilities, or privileged mode.

Startup and task agents use `--sandbox danger-full-access` inside the unprivileged container because Bubblewrap cannot create a nested mount namespace here. The container is the isolation boundary, following the [official guidance](https://learn.chatgpt.com/docs/agent-approvals-security). Other invocations retain configured defaults.

## Authentication and storage

External Secrets seeds the initial ChatGPT login from `kv/codex-pods/auth`, property `auth_json`. The entrypoint copies it only if `$CODEX_HOME/auth.json` is absent; Codex refreshes the writable PVC copy. Credentials never belong in Git. The existing GitHub credential has Schoolhouse repository, Actions, and check-run access. API authentication is disabled.

Use a **distinct OAuth session reserved for this worker**. Independent refreshes of a copied active laptop session can invalidate each other; the initial copied login's sharing risk remains unresolved. The original Vault seed becomes stale after refresh, so PVC loss requires a current seed. See [authentication guidance](https://learn.chatgpt.com/docs/auth/ci-cd-auth).

`home-codex-session-0` (5 GiB SSD) and `workspace-codex-session-0` (10 GiB HDD) are the original StatefulSet claims. They are adopted explicitly with pruning/deletion disabled; retiring the StatefulSet preserves the data.

## Validation

```sh
node --test codex-pods/tests/*.test.mjs
shellcheck codex-pods/entrypoint.sh codex-pods/daily-dependabot.sh scripts/codex-run.sh
kubectl kustomize codex-pods
```
