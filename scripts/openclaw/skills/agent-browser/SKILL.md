---
name: agent-browser
description: Browse websites and manage this role's browser login through browser-profile.
---

# Browser tasks

Use only `browser-profile`; do not choose raw sessions/profiles or use
`--restore`. Consult `agent-browser --help` or `agent-browser skills get core`
for unfamiliar commands; this lifecycle overrides their generic examples.

Follow-ups and background completions continue the user's task. Inspect
relevant evidence when questioned, then act; explanation alone is not progress.

## Choose the right state

Each role's **identity** holds its persistent login. `publish` closes it and
saves a snapshot; `create` copies that snapshot. Copies never update identity
or each other. An old snapshot cannot verify a new login.

- Login and verification: `browser-profile login <url>`, then
  `browser-profile identity <command> ...`.
- Browsing: `browser-profile create`, then
  `browser-profile run <task-id> <command> ...`. Keep one ID per task,
  including after idle shutdown. `browser-profile finish <task-id>` deletes it;
  save deliverables outside its profile, e.g. `/workspace/.openclaw/tmp/`.
- Missing snapshot: inspect existing identity before assuming no login.
  `login about:blank` then `publish` initializes a snapshot without erasing it.
  Never copy running profiles or delete locks; close a legacy browser through
  its original session if migration requests it.

## Finish the login flow

If login is requested or blocks browsing, use identity throughout verification.
Inspect the page and screenshot, then send a fresh code through the permitted
conversation route.

For QR login, actually start a bounded wait: check the site's login state every
10–15 seconds for up to three minutes or until code expiry. A background wait
must resume and report on completion. Stop on success, expiry, site error or
cancellation; do not silently renew codes. "I'll wait" alone starts nothing.
After starting the wait, tell the user that checks and the result report are
automatic, with no confirmation reply needed. In a group task, ask them to
return to the original topic only if they need to report a problem.

On confirmed success, `browser-profile publish`, report success and resume
remaining work in a fresh task. Otherwise report the observed blocker and
needed user action. Do not replace requested logged-in work with generic
advice or other sources without agreement.

## Evidence

Configured browser: headed Debian Chromium in this role's sandbox, not the
user's browser. For diagnosis, verify the process and `AGENT_BROWSER`
environment. Check current evidence before asserting login state. A risk page
proves a blocked visit, not an IP, account or browser-mode cause.
