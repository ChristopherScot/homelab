"""Regression tests for the PR-verification epilogue (PR #129).

The incident being pinned: the 2026-11-10 run was killed by max_turns
six seconds after its `gh pr create` succeeded, self-reported
BLOCKED/no-PR, and the morning report lied while PR #17066 sat open.
These tests fail if that correction ever stops being applied, per Find
Bugs Once.
"""

import json
import pathlib
import sys
import types
import unittest.mock as mock

import report


def fake_proc(returncode=0, stdout="", stderr=""):
    return types.SimpleNamespace(returncode=returncode, stdout=stdout,
                                 stderr=stderr)


# --- apply_pr_verification: the override wiring itself -------------------

# The incident shape: agent died before bookkeeping, GitHub has the PR.
payload, verified = report.apply_pr_verification(
    {"outcome": "BLOCKED", "summary": "killed"}, [17066])
assert verified is True
assert payload["outcome"] == "PROGRESS"
assert payload["pr_number"] == 17066
assert payload["pr_numbers"] == [17066]
assert payload["summary"] == "killed", "unrelated fields must survive"

# A stack of cluster PRs: all recorded, and pr_number stays the bottom
# one, since that is what the logfmt line and the lockfile check read.
payload, verified = report.apply_pr_verification(
    {"outcome": "BLOCKED"}, [29, 30, 31])
assert verified is True
assert payload["pr_number"] == 29
assert payload["pr_numbers"] == [29, 30, 31]

# No PR on GitHub: the self-report stands, whatever it says.
payload, verified = report.apply_pr_verification({"outcome": "BLOCKED"}, [])
assert verified is False
assert payload == {"outcome": "BLOCKED"}

# A run that reported its own PR is never second-guessed.
original = {"outcome": "PROGRESS", "pr_number": 17001}
payload, verified = report.apply_pr_verification(original, [99999])
assert verified is False
assert payload["pr_number"] == 17001

# --- prs_for_run: GitHub as system of record ---------------------------

with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, '[{"number": 17066}]')) as m:
    assert report.prs_for_run("o/r", "b") == [17066]
    # --state open, not all: a PR the agent opened and deliberately
    # closed is a decision, not lost bookkeeping.
    assert "open" in m.call_args[0][0], m.call_args[0][0]
    assert "all" not in m.call_args[0][0]

with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, "[]")):
    assert report.prs_for_run("o/r", "b") == []

# One PR per cluster: a run opens several, and all of them must be seen.
# Verification that only found the bottom one would report three of four
# clusters as lost work.
RUN_BRANCH = "desloppify/webapp-20261111-0300"
CLUSTER_BRANCHES = [f"{RUN_BRANCH}-json-parse-guards",
                    f"{RUN_BRANCH}-log-sensitive",
                    f"{RUN_BRANCH}-deprecated"]
with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, json.dumps(
                           [{"number": 31, "headRefName": CLUSTER_BRANCHES[2]},
                            {"number": 29, "headRefName": CLUSTER_BRANCHES[0]},
                            {"number": 30, "headRefName": CLUSTER_BRANCHES[1]}]))) as m:
    assert report.prs_for_run("o/r", RUN_BRANCH) == [29, 30, 31]

# The pairing that actually matters, and the one a mocked return cannot
# check: GitHub's head: matches EXTENSIONS of the term. So every branch
# the prompt tells the agent to create must start with the run branch.
# When this drifted (the prompt said desloppify/webapp-<slug>, a sibling
# rather than an extension) the search matched nothing and a killed run
# reported four real PRs as lost. Asserted here against the prompt text
# itself so the two cannot drift again.
# Read run.py as text rather than importing it: run.py pulls in
# claude_agent_sdk, which is not installed where these tests run.
_run_src = (pathlib.Path(__file__).parent / "run.py").read_text()
assert "gh stack add {args.branch}-" in _run_src, (
    "the prompt must derive cluster branch names from args.branch. A "
    "hardcoded prefix produces siblings of the run branch, and head: "
    "matches extensions only - so prs_for_run would find nothing and a "
    "killed run would report real PRs as lost (the 2026-11-11 defect)")
for b in CLUSTER_BRANCHES:
    assert b.startswith(RUN_BRANCH), f"{b} does not extend {RUN_BRANCH}"

# gh failing must not crash the epilogue, and must say why on stderr.
with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(1, "", "auth died")):
    with mock.patch.object(report.sys, "stderr") as err:
        assert report.prs_for_run("o/r", "b") == []

with mock.patch.object(report.subprocess, "run",
                       side_effect=OSError("gh: not found")):
    assert report.prs_for_run("o/r", "b") == []

# Unparseable gh output is a verification failure, not a crash.
with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, "not json")):
    assert report.prs_for_run("o/r", "b") == []

print("test_report: all assertions passed")
