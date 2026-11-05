---
name: agent-browser
description: Browse websites, manage this role's browser login through browser-profile, and let the user operate existing browser sessions through a dashboard.
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

## Human control

When the user asks to take over the browser, start the dashboard yourself in
this sandbox. Reuse its existing dashboard, or choose a free loopback port
(4848 is a default, not a requirement) and run
`browser-profile dashboard start --port PORT`. If the installed wrapper lacks
this subcommand, use `agent-browser dashboard start --port PORT` in the same
environment, retaining its daemon socket directory.

Before handing over, poll `http://127.0.0.1:PORT/api/sessions` briefly with
`Origin: http://127.0.0.1:PORT` and confirm the intended `role-identity` or
`task-<task-id>` is listed. A startup message alone does not prove readiness.
Report a startup failure instead of handing over an unverified port; retry
another free port if occupied without stopping another dashboard.

Give the user the actual dashboard port, session name and sandbox identity.
Report the dashboard's listening port, not a session's stream port from the API.
Report `hostname` as a matching hint if the runtime container name/ID is not
known; do not assume that a custom hostname is a valid container ID. The user
can find the container with the repository script's `--ssh storie --list`.
Provide the forwarding command with the actual port substituted:

```sh
python3 scripts/openclaw/browser-dashboard.py --ssh storie \
  --dashboard-port PORT --port 4848 CONTAINER
```

`--dashboard-port` is the port reported by the agent inside the sandbox.
`--port` is the forwarding listener on the user's machine and the storie host;
the user opens `http://127.0.0.1:4848`. These ports can differ. The script reuses
an already-running dashboard at the specified sandbox port and prompts for
sudo in the user's terminal. The sandbox's loopback URL alone is not reachable
from the user's machine. Use the actual deployment host if it is not storie.

Pause browser automation, including background login polling, for the handoff.
Keep the browser, dashboard and profile available until the user says to
continue; do not publish or delete the task while they are operating it.
Dashboard input does not automatically pause agent commands.

## Evidence

Configured browser: headed Debian Chromium in this role's sandbox, not the
user's browser. For diagnosis, verify the process and `AGENT_BROWSER`
environment. Check current evidence before asserting login state. A risk page
proves a blocked visit, not an IP, account or browser-mode cause.
