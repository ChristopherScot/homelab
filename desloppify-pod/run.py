"""One desloppify session against projects/webapp.

The pod runs the desloppify loop - scan, next, fix, resolve - on a work
branch, opens a PR against the integration branch, and merges it there.
main is never a valid target; see policy.py for how that is enforced.

Every tool call goes through a PreToolUse hook. ``can_use_tool`` is not
used: it is consulted only for calls the CLI has not already auto-approved,
which measured as five of five read-only commands bypassing it entirely.

Auth is CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`. The API-key
variables are cleared at import - either one takes precedence and bills
per-token against the API account instead of the subscription.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

for _var in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"):
    os.environ.pop(_var, None)

sys.path.insert(0, str(Path(__file__).parent))

from claude_agent_sdk import (  # noqa: E402
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    HookMatcher,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolUseBlock,
)

import policy  # noqa: E402

PROJECT_PATH = "projects/webapp"

REPORT_SCHEMA = {
    "type": "json_schema",
    "schema": {
        "type": "object",
        "required": ["outcome", "findings_resolved", "pr_number"],
        "additionalProperties": False,
        "properties": {
            "outcome": {
                "type": "string",
                "enum": ["PROGRESS", "NOTHING_TO_DO", "BLOCKED"],
                "description": (
                    "PROGRESS: you resolved findings and opened a PR. "
                    "NOTHING_TO_DO: the queue was empty. "
                    "BLOCKED: you could not run the loop."
                ),
            },
            "pr_number": {
                "type": ["integer", "null"],
                "description": "The PR you opened, or null.",
            },
            "findings_resolved": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Each finding you resolved, as the id and a short label.",
            },
            "score_before": {"type": ["number", "null"]},
            "score_after": {"type": ["number", "null"]},
            "files_changed": {"type": "array", "items": {"type": "string"}},
            "deferred": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Findings you deliberately left, and why.",
            },
            "summary": {"type": "string"},
        },
    },
}


class Audit:
    """Every tool decision, as JSONL. The denials are the interesting half:
    a denied push to main is the signal the policy is doing its job."""

    def __init__(self, path: Path | None):
        self.path = path
        self.allowed = 0
        self.denied: list[tuple[str, str, str]] = []
        # The call a stalled run stopped after: without it a timeout
        # reports that the run wedged but not where.
        self.last: tuple[float, str, str, bool] | None = None
        self._fh = path.open("a") if path else None

    def record(self, tool: str, detail: str, allow: bool, reason: str) -> None:
        self.last = (time.time(), tool, detail[:300], allow)
        if allow:
            self.allowed += 1
        else:
            self.denied.append((tool, detail, reason))
        if self._fh:
            self._fh.write(json.dumps({
                "ts": time.time(), "tool": tool, "detail": detail[:400],
                "allow": allow, "reason": reason,
            }) + "\n")
            self._fh.flush()

    def close(self) -> None:
        if self._fh:
            self._fh.close()


def make_hook(audit: Audit):
    async def pre_tool_use(input_data, tool_use_id, context):
        name = input_data.get("tool_name", "")
        payload = input_data.get("tool_input", {}) or {}
        decision = policy.check_tool(name, payload)
        detail = (
            str(payload.get("command", ""))
            if name == "Bash"
            else json.dumps({k: v for k, v in payload.items()
                             if k in ("file_path", "pattern", "url")})
        )
        audit.record(name, detail, decision.allow, decision.reason)
        if decision.allow:
            return {}
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    f"Refused by the pod's tool policy: {decision.reason}. "
                    "This is a hard boundary, not an obstacle to route "
                    "around. Continue within it, or report BLOCKED."
                ),
            }
        }

    return pre_tool_use


def build_prompt(args: argparse.Namespace) -> str:
    return f"""\
You are running desloppify against `{PROJECT_PATH}` in {args.repo}, checked
out at {args.dir} on branch `{args.branch}`.

This is a monorepo. Scan ONLY `{PROJECT_PATH}` — scanning the repository
root mixes state across unrelated projects and produces unreliable results.

## State

desloppify's state lives at {args.state_dir}, symlinked into the clone as
`.desloppify`. It persists across runs, so the queue you see is a
continuation of previous sessions, not a fresh start. Do not delete it.

## The loop

    desloppify scan --path {PROJECT_PATH}    # only if the queue is empty or stale
    desloppify next                          # what to fix now
    # ... fix it in code ...
    desloppify resolve <id> ...              # exactly as `next` prints it
    desloppify next                          # again

Follow the scan output's INSTRUCTIONS FOR AGENTS. Don't substitute your own
analysis for the queue, and don't rescan mid-queue.

Do large refactors and small fixes with equal energy. Fix things properly,
not minimally. But stop when you have a coherent batch — you have a budget,
and a reviewable PR beats an exhaustive one.

## Committing

You are on `{args.branch}`, cut from `{args.integration_branch}`. Commit
your work there, push it, and open ONE pull request:

    gh pr create --repo {args.repo} --base {args.integration_branch} \\
      --title "desloppify: <what you fixed>" --body "<details>"

The PR body should say what findings you resolved, what the score did, and
anything you deliberately deferred.

## Tests

Postgres, Redis and Hasura run beside you in this pod, on the ports
`src/tests/.envs/.env.test.local` names.

Do not run `yarn test`. It is `test:setup && vitest`, and `test:setup`
begins with `test:containers-up`, which calls `docker compose` - there is
no Docker here, so the chain short-circuits before vitest ever starts.
Run the two steps that work, skipping only the compose one:

    yarn test:db:migrate    # sequelize, against the Postgres beside you
    yarn vitest --run

The migration is not optional: the database starts empty, and a suite run
against an unmigrated one fails in a way that reads as a broken refactor.

A refactor verified only by typecheck and lint has not been verified:
neither catches a behavioural regression, which is most of what a
refactor can break.

## Dependencies

If you change `package.json`, run `yarn install` afterwards and commit the
resulting `yarn.lock`. CI runs `yarn --immutable`, which fails the whole
build - before any linting or typechecking - if the lockfile does not
match. Verifying with a `node_modules` installed before your edit proves
nothing about it.

Treat a "zero importers" finding on a dependency with suspicion: a
package with no imports in `src` may still be a peer dependency that
something else requires. `grep <name> yarn.lock` before removing it.

## Boundaries

`{args.integration_branch}` is the ONLY branch you may target. main is off
limits — not by convention, by policy: pushes to it, PRs against it, and
changes to its protection are all refused before they execute. Do not try
to work around a refusal. If something genuinely requires crossing that
line, stop and report BLOCKED with the reason.

Do not merge your own PR. The runner decides that after its own checks.

Report your result as the structured output you have been given.
"""


async def run(args: argparse.Namespace) -> int:
    if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        print("FATAL: CLAUDE_CODE_OAUTH_TOKEN is not set "
              "(generate one with `claude setup-token`)", file=sys.stderr)
        return 2
    if not os.environ.get("GH_TOKEN"):
        print("FATAL: GH_TOKEN is not set", file=sys.stderr)
        return 2

    audit = Audit(Path(args.audit) if args.audit else None)

    options = ClaudeAgentOptions(
        model=args.model,
        fallback_model=args.fallback_model,
        cwd=args.dir,
        # desloppify's state lives outside the clone so it survives the
        # reset between runs, and the agent reads it through a symlink.
        add_dirs=[args.dir, args.state_dir],
        # The PreToolUse hook decides every call, so the CLI's approval
        # prompt is a second gate with no approver behind it: three runs
        # died on "This command requires approval" for commands the
        # policy had already allowed. acceptEdits does not help, because
        # it auto-approves edits and still prompts for Bash.
        #
        # This turns off that prompt, not the boundary. Measured under
        # bypassPermissions: the hook saw every call, and a command the
        # policy refuses was still refused.
        permission_mode="bypassPermissions",
        setting_sources=[],
        hooks={"PreToolUse": [HookMatcher(matcher=None, hooks=[make_hook(audit)])]},
        output_format=REPORT_SCHEMA,
        max_budget_usd=args.max_cost,
        max_turns=args.max_turns,
        env={"GH_TOKEN": os.environ["GH_TOKEN"]},
    )

    started = time.monotonic()
    result: ResultMessage | None = None
    rate_limit = None
    timed_out = False

    async def drive(client):
        nonlocal result, rate_limit
        await client.query(build_prompt(args))
        async for message in client.receive_response():
            if isinstance(message, AssistantMessage) and args.verbose:
                for block in message.content:
                    if isinstance(block, TextBlock):
                        print(block.text, flush=True)
                    elif isinstance(block, ToolUseBlock):
                        detail = block.input.get("command", "") if block.name == "Bash" else ""
                        print(f"  [{block.name}] {str(detail)[:120]}", flush=True)
            elif isinstance(message, SystemMessage):
                if "rate_limit" in str(getattr(message, "subtype", "")):
                    rate_limit = getattr(message, "data", None)
            elif isinstance(message, ResultMessage):
                result = message

    # A run that is blocked rather than working hits neither max_turns nor
    # max_budget_usd: the first one to stall sat idle for eleven hours
    # with no further tool calls. This is the only bound on wall clock.
    async with ClaudeSDKClient(options=options) as client:
        try:
            await asyncio.wait_for(drive(client), timeout=args.timeout)
        except asyncio.TimeoutError:
            timed_out = True
            print(f"TIMEOUT after {args.timeout}s - no result", file=sys.stderr)

    audit.close()
    payload = (result.structured_output if result and result.structured_output else {}) or {}

    # Why it stalled, not just that it did. The last decision the hook
    # recorded is the call the run stopped after, and the gap between
    # that and the timeout is how long it sat there.
    stalled_after = None
    if audit.last is not None:
        ts, tool, detail, allowed = audit.last
        stalled_after = {
            "tool": tool,
            "detail": detail,
            "allowed": allowed,
            "idle_s": round(time.time() - ts, 1),
            "at": time.strftime("%H:%M:%S", time.localtime(ts)),
        }

    if timed_out:
        where = ""
        if stalled_after:
            where = (f" - last tool call was {stalled_after['tool']} at "
                     f"{stalled_after['at']}, idle {stalled_after['idle_s']}s "
                     f"since: {stalled_after['detail'][:120]}")
        payload = {**payload, "outcome": "BLOCKED",
                   "summary": f"timed out after {args.timeout}s{where}"}
        print(f"TIMEOUT{where}", file=sys.stderr)

    report = {
        "repo": args.repo,
        "timed_out": timed_out,
        # One of: completed, timeout, max_turns, budget, api_error,
        # no_result. A BLOCKED run is not self-explaining otherwise.
        "stop_reason": (
            "timeout" if timed_out
            else (result.terminal_reason or "completed") if result and not result.is_error
            else f"api_error_{result.api_error_status}" if result and result.api_error_status
            else "error" if result
            else "no_result"
        ),
        "stalled_after": stalled_after,
        "project": PROJECT_PATH,
        "branch": args.branch,
        "outcome": payload.get("outcome", "BLOCKED"),
        "pr_number": payload.get("pr_number"),
        "elapsed_s": round(time.monotonic() - started, 1),
        "cost_usd": result.total_cost_usd if result else None,
        "turns": result.num_turns if result else None,
        "is_error": result.is_error if result else True,
        "terminal_reason": result.terminal_reason if result else None,
        "tools_allowed": audit.allowed,
        "tools_denied": len(audit.denied),
        "denials": [{"tool": t, "detail": d[:200], "reason": r}
                    for t, d, r in audit.denied],
        "rate_limit": rate_limit,
        "output": payload,
    }
    print(json.dumps(report, indent=2))
    return 0 if (result and not result.is_error) else 1


def main() -> int:
    p = argparse.ArgumentParser(description="Run desloppify on projects/webapp.")
    p.add_argument("--repo", default=os.environ.get("DESLOP_REPO", "schoolhouse-world/app"))
    p.add_argument("--dir", required=True)
    p.add_argument("--branch", required=True)
    p.add_argument("--integration-branch",
                   default=os.environ.get("DESLOP_INTEGRATION_BRANCH",
                                          "chris-agentic-looping"))
    p.add_argument("--state-dir", required=True)
    p.add_argument("--model", default=os.environ.get("DESLOP_MODEL", "claude-opus-5"))
    p.add_argument("--fallback-model", default=os.environ.get("DESLOP_MODEL_FALLBACK", "sonnet"))
    p.add_argument("--max-cost", type=float,
                   default=float(os.environ.get("DESLOP_MAX_COST_USD", "25.0")))
    p.add_argument("--max-turns", type=int,
                   default=int(os.environ.get("DESLOP_MAX_TURNS", "400")))
    p.add_argument("--timeout", type=float,
                   default=float(os.environ.get("DESLOP_TIMEOUT_S", "7200")),
                   help="wall-clock limit for the whole run, in seconds")
    p.add_argument("--audit", default=os.environ.get("DESLOP_AUDIT_LOG"))
    p.add_argument("--verbose", action="store_true")
    return asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
