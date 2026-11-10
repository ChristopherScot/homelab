"""Regression tests for the PR-verification epilogue (PR #129).

The incident being pinned: the 2026-11-10 run was killed by max_turns
six seconds after its `gh pr create` succeeded, self-reported
BLOCKED/no-PR, and the morning report lied while PR #17066 sat open.
These tests fail if that correction ever stops being applied, per Find
Bugs Once.
"""

import json
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
    {"outcome": "BLOCKED", "summary": "killed"}, 17066)
assert verified is True
assert payload["outcome"] == "PROGRESS"
assert payload["pr_number"] == 17066
assert payload["summary"] == "killed", "unrelated fields must survive"

# No PR on GitHub: the self-report stands, whatever it says.
payload, verified = report.apply_pr_verification({"outcome": "BLOCKED"}, None)
assert verified is False
assert payload == {"outcome": "BLOCKED"}

# A run that reported its own PR is never second-guessed.
original = {"outcome": "PROGRESS", "pr_number": 17001}
payload, verified = report.apply_pr_verification(original, 99999)
assert verified is False
assert payload["pr_number"] == 17001

# --- pr_for_branch: GitHub as system of record ---------------------------

with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, '[{"number": 17066}]')) as m:
    assert report.pr_for_branch("o/r", "b") == 17066
    # --state open, not all: a PR the agent opened and deliberately
    # closed is a decision, not lost bookkeeping.
    assert "open" in m.call_args[0][0], m.call_args[0][0]
    assert "all" not in m.call_args[0][0]

with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, "[]")):
    assert report.pr_for_branch("o/r", "b") is None

# gh failing must not crash the epilogue, and must say why on stderr.
with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(1, "", "auth died")):
    with mock.patch.object(report.sys, "stderr") as err:
        assert report.pr_for_branch("o/r", "b") is None

with mock.patch.object(report.subprocess, "run",
                       side_effect=OSError("gh: not found")):
    assert report.pr_for_branch("o/r", "b") is None

# Unparseable gh output is a verification failure, not a crash.
with mock.patch.object(report.subprocess, "run",
                       return_value=fake_proc(0, "not json")):
    assert report.pr_for_branch("o/r", "b") is None

print("test_report: all assertions passed")
