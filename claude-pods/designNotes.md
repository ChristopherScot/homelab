# claude-pods design notes

Cross-cutting decisions whose reasoning spans several files, kept here so
no single function has to carry the project's history in its comments.
Functions keep the comments that state their *current* contract and link
here for the rest.

## Limit detection

`claude_rate_limited` in `lib/claude-account.sh` decides whether a failed
agent run failed because the account is out of quota. It is shared: the
desloppify image COPYs the library, so both pods depend on it.

### Why this is delicate

The two wrong answers cost different things, and neither is cheap:

- **A miss** parks the card and comments `@chris` — a human round trip,
  and the reserve account sits mounted and unused. This is what happened
  on 2026-11-14.
- **A false match** spends a second full agent run (up to an hour) on the
  reserve account for a run that was never limited.

The detector also has a self-referential hazard that most detectors do
not: these stages edit *this repository*, so the agent most likely to
print an exhaustion string is one working on this function or its tests.
Every prose alternate is therefore anchored to the start of a line — the
CLI prints these as its own message, so they begin a line, while an agent
quoting one does not.

### Three attempts, two wrong

Recorded because each failure looks reasonable in isolation, and the
third only makes sense against the first two:

1. **`limit[ ·]+resets`** — looked like a safe generalisation of the
   CLI's wording. Matched "the limit resets daily", "cache limit ·
   resets on deploy", "connection limit resets after timeout". Any agent
   discussing unrelated code could burn the reserve account.
2. **Enumerating the period** — first `[0-9]+-hour`, then
   `weekly|daily|monthly`. Both wrong, because the period is composed at
   runtime and the label set is far wider than any guess: the binary
   carries `hit your limit` (no period at all), `session`, `fast`, a
   model name (`Fable`), `monthly spend`, `channel's monthly spend`, and
   more. On 2026-11-14 the real message was `You've hit your weekly
   limit`, which no enumeration had.
3. **Port the CLI's own predicate** — the approach in use. Stop guessing
   what the CLI says and read what it actually tests.

The lesson that survives: *do not re-derive the wording; port it.*

### What was ported

From the binary (see the version note in the function — claims were
verified against 2.1.323, while the image pins a different version):

```js
function yvs(e){ return gvs.some(n => e.startsWith(n))
                     || _vs.some(n => n.test(e)) }
// gvs: 12 literal prefixes
// _vs: [/^(?:Fable|Haiku|Mythos|Opus|Sonnet)(?: [^·\n]{1,40})? requires usage credits\./]
```

and the message composer:

```js
function H(e,n,r,s){ let d = s?.progressSavedSuffix ? " · progress saved" : "";
                     return `You've hit your ${e}${n}${d}` }
```

Two deliberate differences from that source, both load-bearing:

- **`fast mode` added** to the model alternation. `Fast mode requires
  usage credits` is in the binary but in neither `gvs` nor `_vs`, so a
  faithful port missed it. The test's pinned-shapes loop caught this.
- **`startsWith` became a `^` anchor.** The CLI tests one message
  string; we search a 40-line transcript.

### Why the shape is incomplete by construction

The pattern matches `hit your <≤3 short words> (limit|shared budget)`.
That is derived from the *tail* of the sentence, whereas the CLI matches
the *prefix* and ignores what follows — so any new label whose sentence
ends differently will be missed. `team's shared budget` already was: it
comes from a literal `H()` call site rather than the label map, and
missing it was a false failure.

A bare prefix match would be faithful but too broad here: it also matches
an agent's own `You have hit your configured per-project eslint file
count limit`, which the test pins as a negative.

So treat a newly-seen terminator as **expected maintenance**, not a
surprise: add it to the alternation and add a pinned shape to
`tests/test-account-failover.sh`.

### Alternates deliberately excluded

`"status": 429` and a bare `api_error_429` were both removed. The binary
contains **zero** occurrences of either — `api_error_429` is composed by
our own `run.py`, not by the CLI — so neither could ever match real CLI
output, while both matched an agent writing a 429 test fixture. Every
genuine 429 arrives structured and is caught by
`claude_terminal_reason_limited`.

Keep this branch free of anything the CLI does not itself print. A token
that appears only in test data is not a weak signal here, it is an
inverted one.

### The detection window

Detection runs over `tail -40` of the captured output. Both extremes were
tried and both were wrong:

- **Whole transcript**: an hour of agent prose is mostly the agent's own
  words, and a ticket that merely edited `rate_limit.go` read as a
  limited account.
- **`tail -2`**: a real limit is not the last thing printed — the CLI
  appends `· progress saved`, and a `-p` run prints its own epilogue
  after. A real limit three lines from the end was missed entirely,
  reintroducing the 2026-11-14 failure.

Specificity therefore lives in the *pattern*, not the window; the window
only has to be wide enough that the message cannot fall outside it.
Which is why the test pins that *a* bound exists rather than the number.
