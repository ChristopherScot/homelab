"""The run report's dealings with GitHub, kept SDK-free so tests reach it.

The incident this exists for: a run killed by max_turns mid-`gh pr
create` dies before it sees the create succeed, and its self-report then
claims BLOCKED/no-PR while the PR sits open (2026-11-10, PR #17066 open
for six hours while the report said otherwise). GitHub is the system of
record for "does a PR exist"; the agent's report is testimony.
"""

from __future__ import annotations

import json
import subprocess
import sys


def prs_for_run(repo: str, branch: str) -> list[int]:
    """Every OPEN PR GitHub has for this run's branches.

    One run opens one PR per cluster. The prompt in run.py requires each
    cluster branch to be `{branch}-<slug>`, so they all extend the run
    branch and `head:` finds the whole stack in one call -- GitHub's
    search matches extensions of the term (head:foo matches foo-bar),
    which is why the prompt interpolates args.branch rather than naming
    a prefix of its own. If that instruction and this query ever drift,
    verification silently returns nothing and a killed run reports real
    work as lost. test_report.py pins the pairing with real branch names.

    `--state open`, not `all`: the fact being verified is "the create
    succeeded seconds before the agent died", and that PR is open. A PR
    the agent opened and then deliberately closed is a decision, not
    lost bookkeeping - matching it would overrule the agent's honest
    BLOCKED with stale work.
    """
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--repo", repo,
             "--search", f"head:{branch}", "--state", "open",
             "--json", "number"],
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0:
            # A broken net must say so, or it stays broken invisibly
            # until the next incident sails through it.
            print(f"WARNING: PR verification failed: gh exited "
                  f"{out.returncode}: {(out.stderr or '').strip()[:200]}",
                  file=sys.stderr)
            return []
        prs = json.loads(out.stdout or "[]")
        return sorted(int(pr["number"]) for pr in prs)
    except Exception as exc:
        # Never turn a finished run into a crash; an unverifiable PR
        # leaves the self-report standing - but say why.
        print(f"WARNING: PR verification failed: {exc}", file=sys.stderr)
        return []


def normalize_pr_fields(payload: dict) -> dict:
    """Make pr_numbers authoritative and pr_number derived from it.

    One run now opens one PR per cluster, so the list is the fact and
    the scalar is a view of it -- kept because the logfmt line and the
    lockfile check read a single number. Deriving it here, at the one
    place the report is assembled, is what stops the two from
    disagreeing: a payload naming only `pr_numbers` used to ship
    `pr_number: null`, and the runner's `[ -z "$pr" ]` gate then
    announced "complete (no PR)" over three open PRs -- the same
    failure this module exists to prevent, one field over.
    """
    numbers = [n for n in (payload.get("pr_numbers") or []) if n is not None]
    if not numbers and payload.get("pr_number") is not None:
        numbers = [payload["pr_number"]]
    if not numbers:
        return payload
    return {**payload, "pr_numbers": numbers, "pr_number": numbers[0]}


def apply_pr_verification(payload: dict, found: list[int]) -> tuple[dict, bool]:
    """Fold GitHub-verified PRs into a self-report that lacks them.

    Returns the (possibly corrected) payload and whether a correction
    was applied. A payload that already names a PR is left alone - the
    verification exists for the run that died before its bookkeeping,
    not to second-guess one that finished. Either way the caller gets
    pr_number and pr_numbers in agreement.
    """
    if payload.get("pr_numbers") or payload.get("pr_number"):
        return normalize_pr_fields(payload), False
    if not found:
        return payload, False
    return normalize_pr_fields({**payload,
                                "outcome": "PROGRESS",
                                "pr_numbers": found}), True
