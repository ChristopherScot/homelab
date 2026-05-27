---
name: kernel
description: >-
  Get a real browser in THIS pod via kernel.sh (cloud browser-as-a-service).
  Use whenever a task needs a browser — opening sites, filling forms, clicking,
  screenshots, scraping, testing/QA/dogfooding a web app — because this pod has
  NO local Chrome, NO display, and NO root to install one. The browser runs in
  Kernel's cloud; you drive it with agent-browser over CDP. Triggers: "open a
  website", "take a screenshot of", "test/QA this web app", "scrape", "log in to
  a site", "automate the browser", or any agent-browser use in this pod. Run
  `kbrowser up` FIRST. Add `--headed` for a live-view URL the user opens on their
  laptop to watch in real time.
allowed-tools: Bash(kbrowser:*), Bash(agent-browser:*)
---

# kernel — remote browser for this pod

This pod is headless and rootless: there is **no local Chrome, no display
server, and no way to apt-install one**. So `agent-browser install` (which
downloads a local Chrome) **cannot work here — never run it.** Instead the
browser runs in **Kernel's cloud** (kernel.sh) and `agent-browser` connects out
to it over the Chrome DevTools Protocol.

```
this pod                         Kernel cloud (kernel.sh)
┌────────────────────┐  CDP wss  ┌──────────────────────┐
│ agent-browser CLI  │──────────▶│ headless/headful     │
│ (driver)           │           │ Chrome (the browser) │
└────────────────────┘           └──────────────────────┘
        ▲ kbrowser provisions the session   │ --headed → live-view URL
        │ (create/connect/delete)            ▼ opened in the USER's laptop browser
```

## Workflow — always start with `kbrowser`

```bash
kbrowser up                 # create a HEADLESS Kernel browser (~$0.06/hr) + connect agent-browser
kbrowser up --headed        # HEADFUL (~$0.48/hr) + prints a LIVE VIEW url the user opens on their laptop
agent-browser open <url>    # then drive normally (connection is persistent across shells)
agent-browser snapshot      # accessibility tree with @eN refs — read this to find elements
agent-browser screenshot /tmp/x.png   # PNG you can send to the user
kbrowser status             # show session_id, headless, cdp_ws_url, live-view url
kbrowser down               # DELETE the Kernel session — ALWAYS do this when finished (stops billing)
```

For the full driver command set, load the bundled agent-browser guide:
`agent-browser skills get core --full`.

## Rules

- **Provision before driving.** If `agent-browser` errors with no connection,
  you forgot `kbrowser up`.
- **Never `agent-browser install`** — there is no local browser to install.
- **Tear down when done.** Headful billing is ~$0.48/hr; `kbrowser down` (idle
  sessions also auto-close after 5 min). Free tier = **$5/mo credits, 5
  concurrent browsers** — don't leave sessions running.
- **Headed = let the user watch.** `--headed` returns a `browser_live_view_url`;
  surface it to the user so they can watch/interact from their laptop. (Headless
  has no live view — use screenshots instead.)

## Not locked into agent-browser

Kernel exposes a **standard CDP endpoint**. `kbrowser status` prints
`cdp_ws_url` — any CDP client (Playwright, Puppeteer, browser-use, raw CDP) can
attach to that same URL. `kbrowser up/status/down` is driver-agnostic;
only `kbrowser run -- …` and the `agent-browser` commands above assume
agent-browser. We use agent-browser by choice (accessibility snapshots + `@ref`
targeting are ideal for an agent), not by lock-in.

## API key

`kbrowser` reads `KERNEL_API_KEY` from the environment (set from a Vault-backed
secret in the deployed pod), falling back to `~/.config/kernel/api-key`
(chmod 600) for local/manual use.
