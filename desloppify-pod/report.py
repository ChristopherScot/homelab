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

    Returns the head branch alongside each number so a caller can show
    which cluster a PR belongs to.

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
             "--json", "number,headRefName"],
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


def apply_pr_verification(payload: dict, found: list[int]) -> tuple[dict, bool]:
    """Fold a GitHub-verified PR into a self-report that lacks one.

    Returns the (possibly corrected) payload and whether a correction
    was applied. A payload that already names a PR is left alone - the
    verification exists for the run that died before its bookkeeping,
    not to second-guess one that finished.
    """
    if payload.get("pr_numbers") or payload.get("pr_number") or not found:
        return payload, False
    return {**payload,
            "outcome": "PROGRESS",
            "pr_number": found[0],
            "pr_numbers": found}, True
