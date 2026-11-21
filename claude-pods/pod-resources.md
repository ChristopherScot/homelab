# Shared pod memory budget

This worker has a **2 GiB hard memory limit for the entire container**. Claude,
subagents, compilers, tests, language servers and subprocesses all share it.
Exceeding it can kill the worker before it saves its work. Work within this
budget; do not raise Kubernetes limits or remove the runtime defaults.

- Run one memory-heavy command at a time. Delegate analysis when useful, but
  do not run builds or test suites concurrently in multiple agents.
- Keep the supplied serial build settings. Go uses `-p=1`, `GOMAXPROCS=2`
  and a soft 512 MiB runtime target; Node has a 768 MiB old-space cap. These
  are per-process settings, not an allowance for each concurrent tool.
- Configure test runners to use one worker (using the runner's documented
  option), and run large suites in sequential package/file batches. Complete
  all required checks; batching is not permission to skip coverage.
- Prefer the provided remote browser. Stop test servers and other processes
  when their work is finished.
- Before a large operation, inspect `/sys/fs/cgroup/memory.current`,
  `/sys/fs/cgroup/memory.max` and `/sys/fs/cgroup/memory.events` when present.
  On cgroup v1 use the corresponding files under `/sys/fs/cgroup/memory/`.
  Leave headroom for Claude and native allocations; a JavaScript heap cap
  does not bound total process memory.
- If a command runs out of memory, save the diagnosis and retry with less
  parallelism or smaller sequential batches, not the same command unchanged.
  If a single required operation still cannot fit, preserve the work and
  report the exact command and resource blocker for a larger runner. Do not
  claim tests passed or loop through repeated OOM kills.
