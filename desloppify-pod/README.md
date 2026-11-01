# desloppify pod

Runs [desloppify](https://github.com/peteromallet/desloppify) against
`projects/webapp` in `schoolhouse-world/app`, opens a PR against the
integration branch, and merges it there.

## main is unreachable

Four independent layers, in the order they stop a mistake:

1. **Credential.** A fine-grained PAT scoped to this one repo with
   Contents + Pull requests write and no Administration scope, so branch
   protection cannot be removed. `nightly-desloppify.sh` refuses to start
   if the token can read main's protection, which an over-scoped token can.
2. **Tool policy** (`policy.py`), consulted from a `PreToolUse` hook before
   every tool call. Pushes to a protected branch, PRs based on anything but
   the integration branch, `gh pr merge`, and protection-API calls are all
   refused before they execute.
3. **Branch protection** on the integration branch.
4. **The prompt**, which is the weakest and is treated as such.

`can_use_tool` is deliberately not used: it is consulted only for calls the
CLI has not already auto-approved. Measured, five of five read-only
commands bypassed it while a `PreToolUse` hook saw every one.

## Layout

| File | What |
|---|---|
| `policy.py` | The allow/deny decision for every tool call |
| `test_policy.py` | 108 cases; `python3 test_policy.py` |
| `run.py` | One session: hook, structured report, budget cap |
| `nightly-desloppify.sh` | Branch setup, state symlink, PR verification, merge |

## State

desloppify's queue lives on the PVC at `$DESLOP_STATE_DIR/webapp` and is
symlinked into the clone as `.desloppify`, so work is incremental across
runs rather than restarting each night.

## Why webapp only

`app` is a yarn-workspaces monorepo with nine projects in `projects/`.
desloppify's docs are explicit that scanning a parent containing several
programs "mixes state and path context, producing unreliable results", so
the scan is scoped to the one project the repo's own lint scripts target.

## Merging

The agent cannot merge; `gh pr merge` is refused by policy. The runner
merges, and only after checking the PR's base is the integration branch and
every changed file is inside `projects/webapp`.
