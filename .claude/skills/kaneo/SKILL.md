---
name: kaneo
description: Work with the Kaneo board (the claude-pods work queue) — list the board, read/create cards, move them between columns, attach labels. Use whenever the user mentions kaneo, the board, cards/tickets, filing work for the pods, or moving something to to-do. Kaneo has NO MCP; its API is undocumented — never probe it by hand, use scripts/kaneo.
---

# Kaneo board

All operations go through `scripts/kaneo` (stdlib Python; works on the
workstation via kubectl and inside the pods via their secret mount):

    scripts/kaneo board                      # columns and cards
    scripts/kaneo show <taskId>              # one card + labels
    scripts/kaneo create --title "..." --description-file f.md --repo homelab
    scripts/kaneo move <taskId> to-do        # dispatches! see below
    scripts/kaneo label <taskId> repo:homelab

## The columns are an automation surface, not just a board

Moving a card to `to-do`, `in-review` or `mergeable` fires a webhook
that dispatches real work to a session pod (author, test, merge
respectively — see claude-pods/dispatcher/dispatch.mjs ROUTES), waking
the claude-session StatefulSet from 0 if asleep. `backlog`,
`in-progress`, `needs-human-review` and `done` are inert.

A dispatched card needs exactly one `repo:<name>` label or the
dispatcher skips it with only a log line to show for it. `create
--repo <name>` attaches it; `move` refuses a dispatching move on a
card without one (override with `--force` only when you mean it).

## Writing cards the pods can act on

The card description is the ENTIRE brief an author pod gets. Write it
self-contained: goal, the why (incidents, links), file-by-file plan,
validation steps, gotchas, and what done means. A one-liner card
produces a one-liner's worth of work.

## When something fails

Error output includes the API's own message. The script is the single
home of the route knowledge (full-body PUT with nulls stripped, label
workspaceId, create's unusual path) — fix it there rather than probing
the API ad hoc.
