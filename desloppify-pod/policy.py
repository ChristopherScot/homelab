"""Tool policy for the desloppify pod.

The pod works on schoolhouse-world/app, where a merge to main would reach
production and bypass the human reviewer that repo requires. Nothing here
may touch main.

Four layers enforce that, of which this is the second:

  1. the pod's PAT has no Administration scope, so branch protection
     cannot be removed;
  2. this policy, consulted from a PreToolUse hook before every tool call;
  3. branch protection on the integration branch;
  4. the prompt.

The hook is what makes this a gate. The SDK's ``can_use_tool`` callback is
consulted only for calls the CLI has not already auto-approved - measured:
``date``, ``echo``, ``ls``, ``whoami`` and ``git status`` all bypassed it,
while a ``PreToolUse`` hook saw every one. ``types.py`` says so directly:
"To gate every tool call, use a PreToolUse hook instead."

Decisions are made on the parsed command. A rule like ``Bash(git:*)``
matches on the first word, so it permits ``git push origin main`` as
readily as ``git log``; the distinction this pod needs cannot be written
in settings.json at all.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass

# The branch that must never be written to, and the one the pod may merge
# into. Both are matched literally - a ref is not a glob.
PROTECTED_BRANCHES = frozenset({"main", "master", "production", "prod", "release"})
INTEGRATION_BRANCH = "chris-agentic-looping"

# The only repository this pod may address. A command naming any other is
# refused: the pod has one job in one repo, and a --repo typo should fail
# rather than act somewhere unexpected.
ALLOWED_REPO = "schoolhouse-world/app"

# Characters that chain, substitute or redirect. One of these means the
# string holds more than the command it appears to, so the checks below
# would be reading only its first clause.
SHELL_METACHARS = re.compile(r"[;&|<>`$(){}\n]|\breval\b")

ALLOWED: dict[str, set[str]] = {
    "git": {
        "fetch", "log", "diff", "show", "status", "rev-parse", "describe",
        "branch", "checkout", "switch", "restore", "stash", "worktree",
        "ls-files", "ls-tree", "blame", "shortlog", "merge-base", "add",
        "cat-file", "for-each-ref", "config", "clean", "reset", "commit",
        "push", "rm", "mv", "apply", "symbolic-ref",
    },
    "gh": {"pr", "issue", "label", "repo", "api", "search", "auth",
           "browse", "stack"},
    "desloppify": set(),
    # Shell builtins and keywords. The table models binaries, so without
    # these a bare `cd` or the `for` opening a loop reads as an unknown
    # command. They execute nothing on their own - what follows them is
    # a separate clause and is checked as one.
    "cd": set(), "export": set(), "local": set(), "read": set(),
    "node": set(), "npm": set(), "npx": set(), "yarn": set(), "pnpm": set(),
    "tsc": set(), "tsgo": set(), "biome": set(), "oxlint": set(),
    "eslint": set(), "prettier": set(), "jest": set(), "vitest": set(),
    "python3": set(), "python": set(), "pip": set(), "pytest": set(),
    "ruff": set(), "black": set(), "mypy": set(),
    "go": set(), "gofmt": set(), "cargo": set(), "dbt": set(),
    "jq": set(), "yq": set(), "rg": set(), "grep": set(), "fd": set(),
    "find": set(), "ls": set(), "cat": set(), "head": set(), "tail": set(),
    "wc": set(), "diff": set(), "sed": set(), "awk": set(), "sort": set(),
    "uniq": set(), "cut": set(), "tr": set(), "mkdir": set(), "cp": set(),
    "mv": set(), "rm": set(), "touch": set(), "chmod": set(), "ln": set(),
    "env": set(), "which": set(), "stat": set(), "du": set(), "df": set(),
    "date": set(), "echo": set(), "printf": set(), "true": set(),
    "sleep": set(), "timeout": set(), "test": set(), "basename": set(),
    "dirname": set(), "realpath": set(), "readlink": set(), "tee": set(),
    "xargs": set(), "file": set(), "base64": set(), "seq": set(),
    "nl": set(), "column": set(), "comm": set(), "join": set(),
    "paste": set(), "tar": set(), "gzip": set(), "unzip": set(),
}

# A second level, for a namespace whose subcommands are not all safe.
# Every other entry in ALLOWED names the subcommands it permits; `stack`
# would otherwise be the one that admits a whole namespace, because
# check_bash stops at the first level. gh-stack v0.2.0 ships 20
# subcommands and is still a 0.x: enumerating the ones the runner's
# prompt actually instructs means a version bump cannot widen this gate
# without someone adding a line here. The refusals below are kept as
# well, so a reader greping for `merge` finds the reason and not just
# an absence.
# sync is the sanctioned rebase path: it cascade-rebases onto updated
# parents and force-pushes with --force-with-lease --atomic, which is
# the capability `gh stack rebase` is refused for. The runner calls it
# itself, and --force-with-lease bounds it to branches this pod owns; a
# bare rebase has neither the lease nor the runner's sequencing.
ALLOWED_SUB: dict[str, set[str]] = {
    "gh stack": {"init", "add", "submit", "sync", "checkout", "view"},
}

# Why a particular refused verb is refused. These are messages, not a
# second gate: ALLOWED_SUB alone decides, and a verb named here that is
# also allowlisted is simply allowed. Keeping the reasons as a lookup
# rather than as parallel FORBIDDEN rules is what stops the two from
# disagreeing -- the earlier design had both, and a verb added to the
# allowlist stayed denied by the regex while the suite reported PASS,
# so neither layer's failure was visible through the other.
SUB_REASONS: dict[tuple[str, str], str] = {
    ("gh stack", "merge"):
        "merging is the runner's after its checks, not the agent's -- and "
        "`gh stack merge` merges every PR up to the one named, without "
        "prompting in a non-interactive terminal",
    ("gh stack", "unstack"):
        "unstacking drops the stack on GitHub, which is the state that "
        "left homelab#64 unmergeable for ten days",
    ("gh stack", "link"):
        "relinking chains PRs onto an arbitrary base, which is what "
        "`gh pr edit --base` is refused for",
    ("gh stack", "modify"):
        "restructuring drops, folds and reorders branches -- unstack's "
        "authority through a TUI",
    ("gh stack", "rebase"):
        "a cascading rebase rewrites history across the stack, which is "
        "what `git rebase` is refused for; `gh stack sync` is the "
        "sanctioned path and carries --force-with-lease",
}

FORBIDDEN: list[tuple[re.Pattern[str], str]] = [
    # --- the main guarantee -------------------------------------------
    # Anything that could put a commit on a protected branch, or open a
    # PR that targets one. The pod's base is always the integration
    # branch; a PR with no explicit --base inherits the repo default,
    # which is main, so a bare `gh pr create` is refused too.
    (re.compile(r"^git\s+push\b.*\b(origin\s+)?(HEAD:)?(refs/heads/)?"
                r"(main|master|production|prod|release)\b"),
     "pushing to a protected branch"),
    (re.compile(r"^git\s+push\b.*--mirror\b"), "mirror push rewrites every ref"),
    (re.compile(r"^git\s+push\b.*(--force|--force-with-lease|-f)\b"),
     "force-push"),
    (re.compile(r"^git\s+push\b.*--delete\b"), "deleting a remote branch"),
    (re.compile(r"^gh\s+pr\s+merge\b"),
     "merging is done by the runner after its checks, not by the agent"),
    # Overnight PRs open as drafts so a human reads them before they are
    # reviewable; nothing merges from a draft. Non-interactive `gh stack
    # submit` implies --auto, which creates drafts unless --open is
    # passed, so this refuses only that flag. Stated in the prompt and
    # the execute directive too -- this is the copy that holds when one
    # of those is edited.
    (re.compile(r"^gh\s+stack\s+submit\b.*--open\b"),
     "overnight PRs open as drafts; a reviewer marks them ready"),
    (re.compile(r"^gh\s+pr\s+edit\b.*(--base|-B)\b"), "retargeting a PR's base"),


    # --- protection and repository settings ---------------------------
    # The PAT has no Administration scope, so these would fail anyway.
    # Refusing them here makes the attempt visible in the audit log
    # instead of as an opaque 403.
    (re.compile(r"\bbranches/[^/\s]+/protection\b"), "branch protection is not the pod's to change"),
    (re.compile(r"^gh\s+api\b.*-X\s*(DELETE|PUT|PATCH|POST)\b.*\bprotection\b"),
     "branch protection is not the pod's to change"),
    (re.compile(r"^gh\s+repo\s+(delete|archive|edit|rename|create)\b"),
     "the pod does not alter repositories"),
    (re.compile(r"^gh\s+(workflow|run|secret|variable|release|ruleset)\b"),
     "workflows, secrets and releases are out of scope"),
    (re.compile(r"^gh\s+(auth\s+)?token\b"), "credentials are not readable"),
    (re.compile(r"^gh\s+auth\s+(login|logout|refresh|switch)\b"),
     "the pod does not change its own credential"),

    # --- history and remotes ------------------------------------------
    (re.compile(r"^git\s+(rebase|cherry-pick|revert|filter-branch|filter-repo)\b"),
     "the pod does not rewrite history"),
    (re.compile(r"^git\s+reset\b.*--hard\b.*\borigin/(main|master)\b"),
     "resetting onto a protected branch"),
    (re.compile(r"^git\s+(remote|tag)\s+(add|remove|rm|set-url|delete|-d)\b"),
     "the pod does not reconfigure remotes or tags"),
    (re.compile(r"^git\s+config\b.*(user\.email|user\.name|url\..*insteadOf|"
                r"credential\.|http\..*extraheader)"),
     "identity and credential config are fixed by the runner"),
    (re.compile(r"^git\s+(checkout|switch)\s+.*(-B|-C|--force-create)\s+"
                r"(main|master|production|prod|release)\b"),
     "recreating a protected branch"),
    (re.compile(r"^git\s+branch\s+.*(-D|-d|--delete|-M|-m|--move|-C|--copy)\b"),
     "the pod does not delete or rename branches"),
    (re.compile(r"^git\s+update-ref\b"), "writing refs directly"),

    # --- host and credentials ------------------------------------------
    (re.compile(r"^(sudo|su|shutdown|reboot|mkfs|dd|vault|aws|gcloud|"
                r"systemctl|mount|umount|kubectl|helm|tofu|terraform|docker)\b"),
     "not available to this pod"),
    (re.compile(r"^(chown|chgrp|useradd|usermod|passwd|crontab|ssh|scp|nc|"
                r"ncat|socat|telnet)\b"),
     "the pod does not administer hosts or open connections"),
    (re.compile(r"\.claude/\.credentials\.json"), "credentials are not readable"),
    (re.compile(r"/run/secrets/"), "secrets are not readable"),
    (re.compile(r"\.git/config\b"), "git config is not read or written directly"),
    (re.compile(r"\b(curl|wget)\b.*\|\s*(ba)?sh\b"), "piping a download into a shell"),
    (re.compile(r"^rm\s+.*(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])"),
     "recursive force-delete"),
    (re.compile(r"\bgit\s+push\b.*\bhttps?://[^@\s]*:[^@\s]*@"),
     "a URL with inline credentials"),
]

ALLOWED_TOOLS = {
    "Read", "Glob", "Grep", "Write", "Edit", "MultiEdit", "NotebookEdit",
    "TodoWrite", "Task", "BashOutput", "KillShell", "WebFetch", "WebSearch",
    # The channel the run's verdict comes back on. Omitting it refuses the
    # report at the last step of an otherwise complete run.
    "StructuredOutput",
    # The SDK names the subagent tool Agent, not Task. Refusing it made
    # run 5 score all twenty review dimensions serially in one context;
    # the review flow is written to fan out. A subagent inherits this
    # same hook, so its tool calls are decided here too.
    "Agent",
}


@dataclass(frozen=True)
class Decision:
    allow: bool
    reason: str


# Which base/trunk flag each command spells, and what to call it in a
# refusal. `gh pr create` takes -B; `gh stack init` takes -b and rejects
# -B as an unknown shorthand, so the spelling is per-command data rather
# than something a reader has to infer.
BASE_FLAGS: dict[tuple[str, ...], tuple[str, str, str]] = {
    ("pr", "create"): ("-B", "gh pr create", "PR base"),
    ("stack", "init"): ("-b", "gh stack init", "stack trunk"),
}


def _base_ok(argv: list[str]) -> Decision | None:
    """Refuse a gh command that opens a PR or stack on the wrong base.

    Walks argv the way _repo_args_ok does rather than matching the
    command string. A regex cannot see argument boundaries: `--base  X`
    with two spaces made the old lookahead test the space instead of X
    and refuse the correct branch, and `-BX` glued to its value was
    invisible to the presence check -- both denied with advice the agent
    had already followed. Spelling out more forms had been the fix three
    rounds running; walking the arguments ends the class.
    """
    words = [a for a in argv if not a.startswith("-")]
    key = tuple(words[:2])
    spec = BASE_FLAGS.get(key)
    if spec is None:
        return None
    short, label, noun = spec

    value = None
    seen = False
    for i, arg in enumerate(argv):
        if arg in ("--base", short):
            seen = True
            value = argv[i + 1] if i + 1 < len(argv) else None
        elif arg.startswith("--base="):
            seen = True
            value = arg.split("=", 1)[1]
        elif arg.startswith(f"{short}=") and len(arg) > len(short) + 1:
            seen = True
            value = arg[len(short) + 1:]
        elif arg.startswith(short) and len(arg) > len(short):
            # The glued POSIX short form, `-Bmain`.
            seen = True
            value = arg[len(short):]
        if seen and value:
            break

    if not seen:
        return Decision(
            False,
            f"{label} without --base takes the repo default, which is "
            f"main; pass --base {INTEGRATION_BRANCH}")
    if value != INTEGRATION_BRANCH:
        return Decision(
            False, f"the only permitted {noun} is {INTEGRATION_BRANCH}")
    return None


def _repo_args_ok(argv: list[str]) -> Decision | None:
    """Refuse a gh command naming a repository other than this pod's."""
    for i, arg in enumerate(argv):
        value = None
        if arg == "--repo" or arg == "-R":
            value = argv[i + 1] if i + 1 < len(argv) else None
        elif arg.startswith("--repo="):
            value = arg.split("=", 1)[1]
        if value and value not in (ALLOWED_REPO, ALLOWED_REPO.split("/")[1]):
            return Decision(False, f"this pod only works on {ALLOWED_REPO}")
    return None


# The shell contract, stated once, next to the code that enforces it.
# The agent prompt interpolates this rather than paraphrasing it: PR #129's
# first draft paraphrased, claimed chaining was refused outright (it is
# not - see check_bash's pipeline branch), and the two representations
# disagreed at birth.
SHELL_CONTRACT = (
    "Command substitution, redirection and grouping are refused outright. "
    "A pipeline or `&&`/`;` chain passes only if every clause passes on "
    "its own - a simple pipe of allowed commands (`rg pattern | head`) is "
    "fine. But the splitter is quote-blind: a quoted argument containing "
    "`;`, `|`, `&` or `$` makes the whole call fail as unparseable, which "
    "looks like chaining being refused. One command per Bash call is the "
    "reliable habit."
)


def _split_commands(command: str) -> list[str]:
    return [c.strip() for c in re.split(r"\|\||&&|\||;", command) if c.strip()]


def check_bash(command: str) -> Decision:
    command = command.strip()
    if not command:
        return Decision(False, "empty command")

    for pattern, reason in FORBIDDEN:
        if pattern.search(command):
            return Decision(False, reason)

    clauses = _split_commands(command)
    if len(clauses) > 1:
        for clause in clauses:
            verdict = check_bash(clause)
            if not verdict.allow:
                return verdict
        return Decision(True, "pipeline, every clause allowed")

    if SHELL_METACHARS.search(command):
        return Decision(
            False,
            "command substitution, redirection or grouping - run the steps "
            "as separate calls so each is checked on its own",
        )

    try:
        argv = shlex.split(command)
    except ValueError as exc:
        return Decision(False, f"unparseable: {exc}")
    if not argv:
        return Decision(False, "empty command")

    idx = 0
    while idx < len(argv) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", argv[idx]):
        idx += 1
    if idx >= len(argv):
        return Decision(False, "assignment with no command")

    binary = argv[idx].rsplit("/", 1)[-1]
    rest = argv[idx + 1:]

    if binary not in ALLOWED:
        return Decision(False, f"{binary} is not on this pod's tool list")

    if binary == "gh":
        verdict = _repo_args_ok(rest)
        if verdict is not None:
            return verdict
        verdict = _base_ok(rest)
        if verdict is not None:
            return verdict

    subcommands = ALLOWED[binary]
    if not subcommands:
        return Decision(True, f"{binary} allowed")

    # Index the subcommand by position rather than by searching for its
    # string later, which found the wrong element whenever a flag's
    # value equalled it. A flag that consumes the next argument can
    # still make that value look like the subcommand (`gh --title stack
    # stack add`); the checks below then read the wrong word and refuse,
    # which is the safe direction and is why this is not special-cased.
    sub_at = next((i for i, a in enumerate(rest)
                   if not a.startswith("-")), None)
    sub = rest[sub_at] if sub_at is not None else None
    if sub is None:
        return Decision(True, f"{binary} with no subcommand")
    if sub not in subcommands:
        return Decision(False, f"{binary} {sub} is not allowed for this pod")

    # A namespace that carries its own subcommands (`gh stack`) is
    # checked one level deeper, or the allowance above would admit
    # everything under it.
    nested = ALLOWED_SUB.get(f"{binary} {sub}")
    if nested is not None:
        tail = rest[sub_at + 1:]
        verb = next((a for a in tail if not a.startswith("-")), None)
        if verb is None:
            return Decision(False, f"{binary} {sub} needs a subcommand")
        if verb not in nested:
            why = SUB_REASONS.get((f"{binary} {sub}", verb))
            if why:
                return Decision(False, why)
            return Decision(
                False, f"{binary} {sub} {verb} is not allowed for this pod")
        return Decision(True, f"{binary} {sub} {verb} allowed")

    return Decision(True, f"{binary} {sub} allowed")


def check_tool(name: str, payload: dict) -> Decision:
    if name == "Bash":
        return check_bash(str(payload.get("command", "")))
    if name in ALLOWED_TOOLS:
        return Decision(True, f"{name} allowed")
    return Decision(False, f"{name} is not available to this pod")
