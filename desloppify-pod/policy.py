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
    # No "push". The agent does not need it: `gh stack` is what puts work
    # on the remote, and it spawns its own git as a subprocess of the gh
    # binary, which this hook never sees. Checked against the audit logs
    # rather than assumed - the 2026-11-14 run opened PR #17094 via
    # `gh stack add` and `gh stack submit` with zero `git push` calls,
    # and across all history the agent pushed exactly twice, both on
    # 2026-11-04/05 to its own desloppify/* branch, before gh stack
    # existed here. The runner's own one-time push of the integration
    # branch lives in nightly-desloppify.sh, outside this gate entirely.
    #
    # The point is not that pushing is dangerous in itself; it is that
    # every guard protecting main has to decide what a push TARGETS, and
    # that means reading a branch name out of a command line. Doing that
    # correctly means agreeing with bash about quoting, escaping and
    # line continuations - and each of those was a bypass here in turn
    # (`ma"in"`, then `ori\<newline>gin`), each needing its own fix.
    # Both are closed, so this is not removing a broken guard; it is
    # removing the need to keep getting that question right.
    #
    # And this layer was never the last one, nor the strongest.
    # `timeout git push ...`, `xargs git push ...` and anything via node
    # or python reach a real push on either side of this change, because
    # the allowlist only inspects argv[0]. The pre-push hook that
    # nightly-desloppify.sh installs catches those - but it is itself
    # reachable: `--no-verify`, `-c core.hooksPath=/dev/null`, or simply
    # `rm .git/hooks/pre-push` are all allowed here, so it is a speed
    # bump for an agent that is trying, not a wall.
    #
    # What actually holds is outside this repo: branch protection on
    # main and the scopes on the PAT. Worth saying plainly, because
    # every layer in here is easier to overrate than to measure, and a
    # comment claiming one of them is the guarantee is how the next
    # person stops looking.
    "git": {
        "fetch", "log", "diff", "show", "status", "rev-parse", "describe",
        "branch", "checkout", "switch", "restore", "stash", "worktree",
        "ls-files", "ls-tree", "blame", "shortlog", "merge-base", "add",
        "cat-file", "for-each-ref", "config", "clean", "reset", "commit",
        "rm", "mv", "apply", "symbolic-ref",
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
# prompt actually instructs means a version bump cannot widen this gate.
# `top` was missing from the first list and three nightly runs died on
# it - the runner needs it between checkout and add, because checkout
# lands on the PR's own branch and add only works from the top of the
# stack. Navigation verbs are not dangerous; the reason the others are
# absent is that nothing calls them
# without someone adding a line here. The refusals below are kept as
# well, so a reader greping for `merge` finds the reason and not just
# an absence.
# sync is the sanctioned rebase path: it cascade-rebases onto updated
# parents and force-pushes with --force-with-lease --atomic, which is
# the capability `gh stack rebase` is refused for. The runner calls it
# itself, and --force-with-lease bounds it to branches this pod owns; a
# bare rebase has neither the lease nor the runner's sequencing.
ALLOWED_SUB: dict[str, set[str]] = {
    "gh stack": {"init", "add", "submit", "sync", "checkout", "view",
                 "top"},
    # Same argument for `gh pr`: 18 verbs are exposed and the runner's
    # prompt instructs a handful. Refusing the dangerous ones by name
    # left `gh pr new` allowed -- gh's own documented alias for create,
    # so _base_ok found no spec and skipped the base check entirely --
    # while the suite reported green. Closing the namespace ends that
    # class instead of adding one more name to it.
    #
    # ready and review are in: opening as drafts is a default the prompt
    # states, not a boundary. Nothing merges from a draft either way,
    # and barring the agent from ever marking one reviewable would stop
    # a normal operation to enforce a preference. Only `submit --open`
    # is refused, so the default holds without the capability being
    # taken away.
    #
    # The verbs left out divide into two kinds, and only the first is a
    # boundary: merge, close, reopen and revert change what is merged or
    # orphan the PRs above them in a stack. checkout, lock, unlock and
    # update-branch are simply unused -- add them if a run turns out to
    # need one, rather than reading their absence as a prohibition.
    "gh pr": {"create", "view", "list", "comment", "edit", "checks",
              "diff", "status", "ready", "review"},
    # Same treatment for two more whole namespaces that were admitted at
    # the first level and then carved back by regex: `gh auth` had rules
    # naming token/login/logout/refresh/switch, and `gh repo` had
    # delete/archive/edit/rename/create. Enumerating what is permitted
    # inverts that - a verb a future gh release adds is refused because
    # it is absent, rather than permitted until someone notices and
    # writes another pattern.
    #
    # status and view are what is left because they are read-only and
    # the only reason to keep the namespaces at all; the audit logs show
    # the agent has never invoked either namespace.
    "gh auth": {"status"},
    "gh repo": {"view"},
}

# gh's own command aliases, resolved to the canonical verb before any
# per-verb lookup. A gate keyed on spelling is defeated by every synonym
# the tool ships: `gh pr new` is documented as an alias for create, and
# because _base_ok keys on ("pr", "create") it found no spec for ("pr",
# "new") and skipped the base check -- so `gh pr new --base main` opened
# a PR against main with the suite green. Canonicalising first means the
# verb lists and BASE_FLAGS are keyed on capability, not on how it was
# typed.
VERB_ALIASES: dict[tuple[str, str, str], str] = {
    ("gh", "pr", "new"): "create",
}


# gh flags that consume the following argument. Without this, every
# gate guessing at "which word is the subcommand" reads a flag's value
# as a positional: `gh pr --repo <repo> merge 5` looked like the
# subcommand was the repo name, so `gh pr merge`'s refusal -- a regex
# needing `pr` and `merge` adjacent -- never matched, and a squash-merge
# was allowed. The flags are gh's, not a guess: --repo/-R, the base
# flags, and the text flags the pod passes.
VALUE_FLAGS: frozenset[str] = frozenset({
    "--repo", "-R", "--base", "-B", "-b", "--head", "-H",
    "--title", "-t", "--body", "--body-file", "-F", "--label", "-l",
    "--assignee", "-a", "--reviewer", "-r", "--milestone", "-m",
    "--project", "-p", "--template", "-T", "--json", "-q", "--jq",
    "--template-file", "--limit", "-L", "--state", "-s", "--search",
    "--author", "-A", "--comment-body", "--remote", "--stack",
})


def _positionals(argv: list[str]) -> list[str]:
    """The positional words of a gh command, flag values excluded.

    One parse, so every gate agrees on which word is the subcommand.
    Three gates used to work this out separately -- a regex over the
    raw string, a filtered word list, and an index of the first
    non-flag argument -- and they disagreed: a flag placed before its
    verb defeated the regex and fooled the word list, which is how
    `gh pr --repo <repo> merge` reached the allow path.
    """
    words: list[str] = []
    skip = False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg == "--":
            break
        if arg.startswith("-"):
            # `--flag=value` carries its value; a bare value flag eats
            # the next argument.
            if "=" not in arg and arg in VALUE_FLAGS:
                skip = True
            continue
        words.append(arg)
    return words


def _canonical_verb(namespace: str, sub: str, verb: str) -> str:
    """The canonical spelling of a verb, for gating purposes."""
    return VERB_ALIASES.get((namespace, sub, verb), verb)

# Why a particular refused verb is refused. These are messages, not a
# second gate: ALLOWED_SUB alone decides, and a verb named here that is
# also allowlisted is simply allowed. Keeping the reasons as a lookup
# rather than as parallel FORBIDDEN rules is what stops the two from
# disagreeing -- the earlier design had both, and a verb added to the
# allowlist stayed denied by the regex while the suite reported PASS,
# so neither layer's failure was visible through the other.
SUB_REASONS: dict[tuple[str, str], str] = {
    # The allowlist refuses these by absence, which is the stronger
    # mechanism but says only "not allowed for this pod". Where the
    # reason is worth stating - a boundary rather than a verb nobody
    # calls - it is stated here, so narrowing a namespace does not cost
    # the explanation the deleted regex carried.
    ("gh auth", "token"): "credentials are not readable",
    ("gh auth", "login"): "the pod does not change its own credential",
    ("gh auth", "logout"): "the pod does not change its own credential",
    ("gh auth", "refresh"): "the pod does not change its own credential",
    ("gh auth", "switch"): "the pod does not change its own credential",
    ("gh repo", "delete"): "the pod does not alter repositories",
    ("gh repo", "archive"): "the pod does not alter repositories",
    ("gh repo", "edit"): "the pod does not alter repositories",
    ("gh repo", "rename"): "the pod does not alter repositories",
    ("gh repo", "create"): "the pod does not alter repositories",
    ("git", "push"):
        "pushing is `gh stack`'s job here -- `gh stack submit` puts new "
        "branches and their PRs on the remote, and `gh stack sync` "
        "fetches, rebases and pushes a stack that is already up there. "
        "Between them there is no run that needs a direct push",
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
    ("gh pr", "merge"):
        "merging is done by the runner after its checks, not by the agent",
    ("gh pr", "revert"):
        "reverting opens a PR the runner did not sequence",
    ("gh pr", "close"):
        "closing a stacked PR orphans the ones above it, which is the "
        "state that left homelab#64 unmergeable for ten days",
    ("gh pr", "update-branch"):
        "updating a stacked branch is `gh stack sync`'s job",
    ("gh stack", "rebase"):
        "a cascading rebase rewrites history across the stack, which is "
        "what `git rebase` is refused for; `gh stack sync` is the "
        "sanctioned path and carries --force-with-lease",
}


def _known_verbs(namespace: str) -> frozenset[str]:
    """Every verb this gate has an opinion about, for one namespace.

    Derived from the tables that hold the opinions, so a verb added to
    any of them is recognised here without a second edit.
    """
    verbs = set(ALLOWED_SUB.get(f"gh {namespace}", ()))
    verbs |= {v for (ns, v) in SUB_REASONS if ns == f"gh {namespace}"}
    for key, canonical in VERB_ALIASES.items():
        if len(key) == 3 and key[1] == namespace:
            verbs.add(key[2])
            verbs.add(canonical)
    return frozenset(verbs)


def _verb_of(namespace: str, words: list[str]) -> tuple[str | None, bool]:
    """The verb among these positionals, and whether they are ambiguous.

    gh resolves the first positional as the verb and validates flags
    against that verb, so a flag belonging to the verb may legally come
    before it: `gh pr --match-head-commit view merge 5 --squash` runs a
    MERGE, with `view` consumed as the flag's value. Taking the first
    positional read that as a `view`, so the merge refusal never ran --
    and the three flags that reach it (--match-head-commit,
    --author-email, --subject) are `gh pr merge`'s own, all three
    missing from VALUE_FLAGS.

    Enumerating harder is not the fix: VALUE_FLAGS copies another
    project's flag arity and can only trail its releases. Instead pick
    the word this gate recognises, and if two are recognised, report it
    ambiguous so the caller refuses rather than choosing. A permitted
    verb then cannot launder a refused one, whatever the flag table
    happens to know.
    """
    known = _known_verbs(namespace)
    found = [w for w in words if w in known]
    if len(found) > 1:
        return found[0], True
    if found:
        return found[0], False
    return (words[0] if words else None), False

FORBIDDEN: list[tuple[re.Pattern[str], str]] = [
    # --- the main guarantee -------------------------------------------
    # Anything that could put a commit on a protected branch, or open a
    # PR that targets one. The pod's base is always the integration
    # branch; a PR with no explicit --base inherits the repo default,
    # which is main, so a bare `gh pr create` is refused too.
    #
    # There are no `git push` patterns here any more. They were all
    # anchored `^git\s+push\b`, so with the verb gone from ALLOWED the
    # subcommand check refuses every string they could match before they
    # are ever consulted. Verified rather than assumed: re-inserting all
    # four changes no verdict anywhere in the suite.
    #
    # They are deleted rather than kept "just in case" someone re-adds
    # push, but NOT because they are evadable - #182's _normalised()
    # closed that, and with `push` restored they correctly refuse
    # `ma"in"`, `'main'` and `ma""in` today. They are deleted because
    # dead code in a security gate is a liability: it reads as active
    # protection, so the next person weighing whether to re-add the verb
    # would count a guard that is not running. Re-adding push means
    # re-adding these deliberately and re-testing them.
    #
    # The reason the verb went rather than the guards is still the
    # targeting problem: a regex has to decide what a push TARGETS,
    # which means reading a branch name out of a command line and
    # agreeing with bash about quoting, escaping and line
    # continuations. `ma"in"` and `ori\<newline>gin` each defeated these
    # patterns at some point, and each needed its own fix. An allowlist
    # matches argv, so the question does not arise.
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


    # --- protection and repository settings ---------------------------
    # The PAT has no Administration scope - nightly-desloppify.sh
    # refuses to start if the token can so much as READ main's
    # protection - so this would fail anyway. Kept because it makes the
    # attempt visible in the audit log instead of as an opaque 403, and
    # because it is the one gh api path worth naming.
    #
    # Nothing else under `gh` is named here. A subcommand ALLOWED does
    # not list, or a verb ALLOWED_SUB does not list, is already refused
    # - and by absence, so it covers the verbs a future gh release adds
    # as well as today's.
    (re.compile(r"\bbranches/[^/\s]+/protection\b"), "branch protection is not the pod's to change"),
    (re.compile(r"^gh\s+api\b.*-X\s*(DELETE|PUT|PATCH|POST)\b.*\bprotection\b"),
     "branch protection is not the pod's to change"),

    # --- history and remotes ------------------------------------------
    # Only verbs that ARE in ALLOWED need a rule: each of these narrows
    # something the agent legitimately does to exclude one dangerous
    # shape. A verb ALLOWED omits needs no pattern.
    (re.compile(r"^git\s+reset\b.*--hard\b.*\borigin/(main|master)\b"),
     "resetting onto a protected branch"),
    (re.compile(r"^git\s+config\b.*(user\.email|user\.name|url\..*insteadOf|"
                r"credential\.|http\..*extraheader)"),
     "identity and credential config are fixed by the runner"),
    (re.compile(r"^git\s+(checkout|switch)\s+.*(-B|-C|--force-create)\s+"
                r"(main|master|production|prod|release)\b"),
     "recreating a protected branch"),
    (re.compile(r"^git\s+branch\s+.*(-D|-d|--delete|-M|-m|--move|-C|--copy)\b"),
     "the pod does not delete or rename branches"),

    # --- host and credentials ------------------------------------------
    # No binary blocklist here: ALLOWED is an allowlist, so sudo, ssh,
    # kubectl and the rest are refused by not being on it. Blocklisting
    # them too meant maintaining the list that did not matter.
    #
    # What remains is about CONTENT rather than which binary is running,
    # so it holds for `cat`, `grep`, `sed` or anything else permitted.
    (re.compile(r"\.claude/\.credentials\.json"), "credentials are not readable"),
    (re.compile(r"/run/secrets/"), "secrets are not readable"),
    (re.compile(r"\.git/config\b"), "git config is not read or written directly"),
    (re.compile(r"^rm\s+.*(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])"),
     "recursive force-delete"),
    # Any URL carrying credentials, not just a push's. This was scoped
    # to `git push` and that verb is gone, which would have left it
    # matching nothing - but the hazard was never about the verb. The
    # gap was real before the verb was removed: `git fetch
    # https://user:token@...` was allowed on main while the same URL in
    # a push was refused.
    # Userinfo in an https URL at all, with or without a colon. The
    # bare form is the common one for a GitHub PAT
    # (https://ghp_xxx@github.com/...), and this pod holds a token, so
    # omitting it would leave the likeliest shape open: `git fetch
    # https://ghp_xxx@github.com/a/b` was allowed until this pattern
    # dropped the `:`. The class stops at `/` and whitespace so a
    # host:port URL, a path, or a later email address is not userinfo.
    (re.compile(r"\bhttps?://[^@\s/]+@"),
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
# The short base flag and what to call the value, per command. The
# command name itself is the key, so the refusal message derives from it
# rather than restating it -- a hand-written label that drifted from its
# key would name a different command than the one being gated, which is
# the wrong-advice class these rules keep tripping over.
BASE_FLAGS: dict[tuple[str, ...], tuple[str, str]] = {
    ("pr", "create"): ("-B", "PR base"),
    ("stack", "init"): ("-b", "stack trunk"),
}


def _base_values(argv: list[str], short: str) -> list[str | None]:
    """Every base value named in argv, in the order it appears.

    All occurrences, not the first: gh takes the last spelling to
    appear, so `-B <good> --base main` creates against main, and a
    collector that stopped early approved exactly that.
    """
    values: list[str | None] = []
    for i, arg in enumerate(argv):
        if arg in ("--base", short):
            values.append(argv[i + 1] if i + 1 < len(argv) else None)
        elif arg.startswith("--base="):
            values.append(arg.split("=", 1)[1])
        elif arg.startswith(f"{short}=") and len(arg) > len(short) + 1:
            values.append(arg[len(short) + 1:])
        elif arg.startswith(short) and len(arg) > len(short):
            # The glued POSIX short form, `-Bmain`.
            values.append(arg[len(short):])
    return values


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
    # Everything after `--` is positional, so a --base there is not a
    # flag. Walking past it let `gh pr create -- --base <branch>` look
    # like it had named a base when gh would have used the repo default.
    if "--" in argv:
        argv = argv[:argv.index("--")]
    words = _positionals(argv)
    if len(words) >= 2:
        words[1] = _canonical_verb("gh", words[0], words[1])
    key = tuple(words[:2])

    # Retargeting an existing PR is refused outright, whatever the
    # value: the runner owns the stack's shape, and a PR moved onto
    # another base is the state that left homelab#64 unmergeable. This
    # was a regex over the raw string until a flag placed between `pr`
    # and `edit` was found to defeat it.
    if key == ("pr", "edit") and _base_values(argv, "-B"):
        return Decision(False, "retargeting a PR's base")

    spec = BASE_FLAGS.get(key)
    if spec is None:
        return None
    short, noun = spec
    label = "gh " + " ".join(key)

    # Collect every occurrence rather than stopping at the first with a
    # value: gh takes the last spelling to appear, so `-B <good>
    # --base main` creates against main. Breaking early approved
    # exactly that, and a repeated flag is the obvious way to probe a
    # gate that reads only one. Any value that is not the integration
    # branch refuses, whichever position it is in -- stricter than gh's
    # last-wins, and the pod has no reason to pass the flag twice.
    values = _base_values(argv, short)
    seen = bool(values)
    for value in values:
        if value != INTEGRATION_BRANCH:
            return Decision(
                False, f"the only permitted {noun} is {INTEGRATION_BRANCH}")

    if not seen:
        return Decision(
            False,
            f"{label} without --base takes the repo default, which is "
            f"main; pass --base {INTEGRATION_BRANCH}")
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
    "fine. Separators inside quotes are data, not syntax, so "
    '`grep -n "a\\|b" f` and `sed -n \'1,5p;9p\' f` are single commands '
    "and pass. `$` and a backtick still count inside double quotes, "
    "because the shell expands them there. "
    "Write each command on ONE line: a backslash line continuation is "
    "refused, because bash joins the halves and the command that runs "
    "is then not the one that was checked. Long invocations are fine, "
    "just unwrapped."
)


def _unquoted(command: str) -> str:
    """The command with quoted spans blanked out, for metachar scanning.

    A metacharacter only does something - substitution, redirection,
    chaining - when the shell sees it OUTSIDE quotes. Inside quotes it is
    data: `grep -n "a|b" f` passes one literal pattern to grep and starts
    no pipeline. Scanning the raw string cannot tell those apart and
    refused the second, so ordinary greps came back as "command
    substitution, redirection or grouping".

    Quoted content is replaced with spaces rather than removed, so any
    offset reported against this string still lines up with the original.
    """
    out = []
    quote = None
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            out.append(" " if ch != "'" else ch)
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            # A backtick always expands inside double quotes, and so does
            # `$` when it introduces a name, a brace or a subshell -
            # "a $(whoami)" really does run whoami - so those must still
            # reach the metachar scan. Everything double quotes genuinely
            # neuters (`;`, `|`, `&`, redirection, grouping, newline) is
            # blanked. Verified against bash rather than assumed, in both
            # directions: `"a\\" $(whoami)"` substitutes, while a `$`
            # before the closing quote or before a space is literal - which
            # is why `grep -c "^ [A-Z]*: {$" f` is an ordinary command and
            # must not be refused.
            if ch == "`":
                out.append(ch)
                i += 1
                continue
            if ch == "$" and i + 1 < n and (
                command[i + 1].isalpha()
                or command[i + 1] == "_"
                or command[i + 1] in "{("
            ):
                out.append(ch)
                i += 1
                continue
            out.append(" " if ch != '"' else ch)
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            # An escaped metachar outside quotes is literal too.
            out.append("  ")
            i += 2
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _split_commands(command: str) -> list[str]:
    """Split a command on shell separators that are NOT inside quotes.

    A plain `re.split` is quote-blind, and that cost real work: an
    ordinary `grep -n "^import\\|^} from" file` was split mid-pattern
    into `grep -n "^import\\` and `^} from" file`, and the first
    fragment - an unterminated quote ending in a backslash - came back
    from shlex as `unparseable: No escaped character`. The agent's
    command was valid shell every time. One nightly run spent 15 of its
    29 denials this way (2026-11-14, report-20261114-0807.json), each
    one a wasted turn on a command that should simply have run.

    Quoting rules are the shell's, not Python's: inside single quotes
    nothing is special, including backslash; inside double quotes a
    backslash escapes the next character; outside quotes a backslash
    escapes the next character too. Separators are only separators when
    the scanner is outside both kinds of quote.
    """
    out: list[str] = []
    buf: list[str] = []
    quote: str | None = None
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            # Single quotes are literal; only the closing quote ends them.
            buf.append(ch)
            if ch == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                buf.append(ch)
                buf.append(command[i + 1])
                i += 2
                continue
            buf.append(ch)
            if ch == '"':
                quote = None
            i += 1
            continue
        # Outside quotes.
        if ch == "\\" and i + 1 < n:
            buf.append(ch)
            buf.append(command[i + 1])
            i += 2
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == ";":
            out.append("".join(buf))
            buf = []
            i += 1
            continue
        if ch in "|&":
            # `||` and `&&` are two-character separators; a lone `|` is a
            # pipe. A lone `&` is backgrounding, which SHELL_METACHARS
            # refuses on the whole command before this ever runs, but
            # splitting on it here keeps the scan honest either way.
            if i + 1 < n and command[i + 1] == ch:
                i += 2
            else:
                i += 1
            out.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
        i += 1
    out.append("".join(buf))
    return [c.strip() for c in out if c.strip()]


def _normalised(command: str) -> str:
    """The command with shell quoting resolved, for FORBIDDEN matching.

    FORBIDDEN is a list of regexes, and a regex sees text while bash sees
    words. `git push origin ma"in"` is one word, `main`, to bash - and to
    `\\bmain\\b` it is not a match at all, so the push-to-main guard let
    it through. Six of the seven git-push guards were evadable this way,
    including the one that exists because a merge to that repo's main
    reaches production. `gh pr merge` was NOT evadable, because the gh
    path checks parsed argv rather than trusting the regex - which is the
    argument for doing the same here.

    shlex does the unquoting, and the words are rejoined with single
    spaces so the patterns match words rather than whatever spacing the
    caller used. If it will not parse, the original is returned: an
    unparseable command is refused a few lines later anyway, and
    returning the raw text keeps the guards matching on something rather
    than nothing.
    """
    try:
        return " ".join(shlex.split(command))
    except ValueError:
        return command


def check_bash(command: str) -> Decision:
    command = command.strip()
    if not command:
        return Decision(False, "empty command")

    # A backslash-newline is a line continuation: bash DELETES it and
    # joins the halves, so `git push ori\<newline>gin main` runs as
    # `git push origin main`. Nothing else here can see that. The
    # metachar scan used to catch it only because `\n` is in
    # SHELL_METACHARS, and _unquoted now blanks any escaped pair before
    # that scan runs - which silently reopened every FORBIDDEN guard,
    # push-to-main included. shlex cannot stand in for this either: it
    # keeps the newline inside the word, so `ori\ngin` never matches
    # `origin` and the patterns look right past it. Checked against
    # bash, which reports argv as [push] [origin] [main].
    #
    # Refused outright rather than normalised away. A continuation is
    # only ever formatting, so nothing legitimate is lost, and
    # reconstructing what bash would join is one more place for this
    # file's idea of quoting to drift from the shell's.
    #
    # Deliberately quote-blind, which is the one thing this file
    # otherwise stopped being. Inside single quotes bash keeps
    # `a\<newline>b` literal rather than joining it, so this does
    # over-refuse a multi-line quoted pattern - but that shape was
    # already refused before this branch (the raw newline trips
    # SHELL_METACHARS), so the cost is a clearer message rather than a
    # new denial, and teaching a fourth scanner about quotes is the
    # drift this comment is about.
    if "\\\n" in command:
        return Decision(
            False,
            "line continuation - bash joins the halves, so the command "
            "that runs is not the one being checked; write it on one line",
        )

    # Matched against the normalised form, which resolves quoting so
    # `ma"in"` is the word `main` the patterns look for. An unparseable
    # command normalises to itself, so the raw text is still matched in
    # exactly the case where unquoting is impossible - no second search
    # needed, and the fallback is what makes that true.
    normalised = _normalised(command)
    for pattern, reason in FORBIDDEN:
        if pattern.search(normalised):
            return Decision(False, reason)

    clauses = _split_commands(command)
    if len(clauses) > 1:
        for clause in clauses:
            verdict = check_bash(clause)
            if not verdict.allow:
                return verdict
        return Decision(True, "pipeline, every clause allowed")

    if SHELL_METACHARS.search(_unquoted(command)):
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

    # gh's subcommand comes from the shared parse, which knows which
    # flags carry a value: taking the first non-flag argument read
    # `gh pr --repo <repo> merge` as the subcommand `<repo>`, so the
    # verb was never inspected and a squash-merge reached the allow
    # path. Other binaries keep the simple positional reading --
    # VALUE_FLAGS describes gh's surface, not theirs.
    if binary == "gh":
        words = _positionals(rest)
        sub = words[0] if words else None
        sub_at = rest.index(sub) if sub in rest else None
        if sub is not None and f"gh {sub}" in ALLOWED_SUB:
            verb, ambiguous = _verb_of(sub, words[1:])
            if ambiguous:
                return Decision(
                    False,
                    f"two subcommands named in `gh {sub}`: a flag's value "
                    f"and a verb are indistinguishable here, and gh would "
                    f"run the later one -- put the verb straight after "
                    f"`gh {sub}`")
    else:
        sub_at = next((i for i, a in enumerate(rest)
                       if not a.startswith("-")), None)
        sub = rest[sub_at] if sub_at is not None else None
    if sub is None:
        return Decision(True, f"{binary} with no subcommand")
    if sub not in subcommands:
        why = SUB_REASONS.get((binary, sub))
        if why:
            return Decision(False, why)
        return Decision(False, f"{binary} {sub} is not allowed for this pod")

    # A namespace that carries its own subcommands (`gh stack`) is
    # checked one level deeper, or the allowance above would admit
    # everything under it.
    nested = ALLOWED_SUB.get(f"{binary} {sub}")
    if nested is not None:
        tail = rest[sub_at + 1:] if sub_at is not None else []
        verb = (_positionals(tail)[0:1] or [None])[0]
        if verb is None:
            return Decision(False, f"{binary} {sub} needs a subcommand")
        verb = _canonical_verb(binary, sub, verb)
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
