# The task-worker image

`ghcr.io/christopherscot/claude-task`, built from `task/Dockerfile` with
context `claude-pods/`. It carries the Go `kaneo-worker`, the three stage
entrypoints the dispatcher execs, the agent's tool allow-list and the
build/test tools the cards' repositories need. Nothing interactive.

The interactive session image (`../Dockerfile`, `claude-pod`) is unchanged
and still ships the worker: the dispatcher execs into `claude-session`,
and that is what keeps the production flow running until it is
retargeted. This directory makes the task image buildable, tested and
deployable ahead of that step without touching the session pods.

## What is here

| File | Role |
|---|---|
| `Dockerfile` | the task image; `KANEO_WORKER_REF` must match `../Dockerfile` while both ship the worker |
| `entrypoint.sh` | clone the pod's repo list, seed skills, pre-trust the repos, idle |
| `image-smoke.sh` | run offline inside the built image by CI before it is published |
| `statefulset.yaml` | `claude-task`, held at 0 replicas; the updater's pin target |
| `kustomization.yaml` | lists the manifests the `claude-task` Application deploys |

CI: `.github/workflows/claude-task-image.yml`. It builds, loads and
smoke-tests the image, prints its size to the job summary, then pushes
`:latest` and a `sha-` tag. To build a branch,
`gh workflow run claude-task-image.yml --ref <branch>`.

Tests that need no image: `../tests/task-entrypoint.sh` (the boot script
against a fake git and repo secret) and `../tests/image-pinning.sh` (the
Application, kustomization and pull-policy invariants, now for three
images).

## Inventory

Against `../Dockerfile` at the commit this was split from.

**Kept, unchanged path**

- `kaneo-worker` (same `KANEO_WORKER_REF`), `stage-author`, `stage-test`,
  `stage-merge` with protocol marker 3
- `prompts/nightly-settings.json` at the worker's `NIGHTLY_SETTINGS`
  default
- `lib/maintenance.sh` at the path the worker looks for
- Claude Code at the same `CLAUDE_CODE_VERSION`, hardlink-deduped
- git, gh, curl, jq, ripgrep, build-essential (make, gcc)
- Go toolchain, kubectl, helm, yq, tofu at the same pins
- typescript, tsx, agent-browser, `kbrowser`, and the `kernel` and
  `agent-browser` skills
- credential handling and account failover: both live in the Go worker,
  which reads `/run/secrets/git/token`, `/run/secrets/kaneo/api-key` and
  `/run/secrets/claude/oauth-token{,-personal}`, exactly as before

**Moved**

- `DISABLE_UPDATES=1`: from `~/.claude/settings.json` (re-synced onto the
  home PVC every boot) to an image `ENV`. Same effect, no home needed.
- git credentials: from a boot-time `gh auth login` + `~/.git-credentials`
  copy to a system gitconfig that routes github.com through
  `gh auth git-credential`. The worker already puts `GH_TOKEN` into every
  tool's environment; gh reads it from there.
- skills: from the `/opt/home-skel` first-boot seed to a plain copy on
  every boot (image wins).

**Removed from the task image**

- tmux, tpm, `tmux.conf`, the always-on `claude --remote-control` loop and
  the `rc` session, `rclaude-layout`, `tmux-sessionizer`
- zsh, oh-my-zsh, starship, zoxide, eza, fzf, fd-find, direnv, delta,
  lazygit, croc, less, vim, openssh-client, gnupg
- Neovim, LazyVim, gopls, goimports, gofumpt, delve
- Google Cloud SDK and the gcloud boot auth, `dp` (deploy wrapper), the
  `gcp-deploy` mount: the allow-list denies `gcloud` to the agent anyway
- the Kaneo CLI: the worker has no direct Kaneo reads or writes, and the
  allow-list does not permit `kaneo`
- `lib/claude-account.sh`: the Bash failover that desloppify still uses;
  the Go worker has its own
- `/opt/home-skel`, the Remote Control trust/onboarding seed for `.claude.json`
  (the entrypoint still pre-trusts `/workspace` and each repo for `claude -p`)
- `OWNER` env (only `dp` read it) and the `-lc` login-shell wrapper around
  the entrypoint

**Not in either image, by design**

- prompt templates and ticket context: frozen into each dispatcher command
  and archived under `/workspace/.nightly/commands/<id>/`
- books and other reference material from the home PVC

## Image sizes

Uncompressed, as reported by `docker image inspect` in CI and by the
nodes' image lists.

| Image | Size |
|---|---|
| `claude-pod` (interactive, live digest `af0467b1…`) | 1,569,488,020 bytes (1,497 MiB) |
| `claude-task` | see the claude-task image workflow run for this branch; recorded in the PR |

## Before the dispatcher is retargeted

Verified while writing this, from a session pod running a protocol-3
command:

- the `claude-session` StatefulSet is `RollingUpdate` with `partition: 3`
  and its current and update revisions match
- this PR's own command archive (`command.json`, `payload.json`,
  `prompt.txt`, `provenance.json`) exists, so the dispatcher/worker
  protocol works end to end on the session backend
- both repositories are reachable: this one for push, `kaneo-dispatcher`
  for a clone at the pinned worker ref

What this change does **not** do: scale, delete or replace any session
pod; change the session image or its workflow; enrol a second image on
the `claude-pods` Application; or make the dispatcher exec into
`claude-task`. Each of those is a later card.
