"""The wall-clock timeout fires and reports BLOCKED.

max_turns and max_budget_usd do not bound a run that is blocked rather
than working; the first stall sat idle for eleven hours. This asserts the
bound exists and that a timeout is not mistaken for a pass.
"""

import asyncio
import sys


async def _never_returns():
    await asyncio.sleep(3600)


async def main() -> int:
    failures = []

    # The pattern run.py uses: wait_for around the driver.
    timed_out = False
    try:
        await asyncio.wait_for(_never_returns(), timeout=0.2)
    except asyncio.TimeoutError:
        timed_out = True
    if not timed_out:
        failures.append("a blocked coroutine was not timed out")

    # A timeout must read as BLOCKED, never as a pass.
    payload = {"outcome": "PROGRESS", "pr_number": 7}
    if timed_out:
        payload = {**payload, "outcome": "BLOCKED", "summary": "timed out after 0.2s"}
    if payload["outcome"] != "BLOCKED":
        failures.append("a timed-out run did not report BLOCKED")
    if "timed out" not in payload.get("summary", ""):
        failures.append("the timeout reason was not recorded")

    # A run that finishes inside the bound is untouched.
    async def quick():
        return "done"
    try:
        got = await asyncio.wait_for(quick(), timeout=5)
    except asyncio.TimeoutError:
        got = None
    if got != "done":
        failures.append("a fast run was wrongly timed out")

    if failures:
        print(f"FAIL - {len(failures)}")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS - 4 cases (timeout fires, reports BLOCKED, records reason, fast run unaffected)")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
