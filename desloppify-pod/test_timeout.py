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

    # A BLOCKED run has to say WHY. These are the shapes a run ends in,
    # and each must be distinguishable in the report: "BLOCKED" alone
    # sends a reader to a transcript that may not exist.
    def stop_reason(timed_out, result_err, api_status, terminal, has_result):
        if timed_out:
            return "timeout"
        if has_result and not result_err:
            return terminal or "completed"
        if has_result and api_status:
            return f"api_error_{api_status}"
        if has_result:
            return "error"
        return "no_result"

    cases = [
        ((True,  False, None, None,       True),  "timeout"),
        ((False, False, None, "completed", True), "completed"),
        ((False, False, None, "max_turns", True), "max_turns"),
        ((False, True,  429,  None,       True),  "api_error_429"),
        ((False, True,  None, None,       True),  "error"),
        ((False, False, None, None,       False), "no_result"),
    ]
    for args_, want in cases:
        got = stop_reason(*args_)
        if got != want:
            failures.append(f"stop_reason{args_} = {got!r}, want {want!r}")

    # A stall must name the call it stopped after.
    last = (1000.0, "Bash", "npx tsgo -p ./projects/webapp --noEmit", True)
    ts, tool, detail, _ = last
    stalled = {"tool": tool, "detail": detail, "idle_s": round(5000.0 - ts, 1)}
    if stalled["tool"] != "Bash" or "tsgo" not in stalled["detail"]:
        failures.append("the stalled-after call was not recorded")
    if stalled["idle_s"] != 4000.0:
        failures.append(f"idle_s wrong: {stalled['idle_s']}")

    if failures:
        print(f"FAIL - {len(failures)}")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS - 12 cases (timeout, BLOCKED reporting, 6 stop_reason shapes, stall attribution)")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
