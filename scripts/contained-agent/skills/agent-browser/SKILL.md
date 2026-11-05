---
name: agent-browser
description: Browse websites using task profiles forked from the user's published logins, and let the user operate existing browser sessions through a dashboard.
---

# Browser tasks in contained agents

Read `agent-browser skills get core` for browser commands. The lifecycle rules
below override its generic session/profile examples for this environment.
Never invoke raw `agent-browser open`, choose your own session/profile, or use
`--restore`. Use `browser-profile` for all browser operations.

## Ordinary browsing

```
browser-profile create
# Save the returned task ID; use it for every operation of this task.
browser-profile run <task-id> open https://example.com
browser-profile run <task-id> snapshot -i
browser-profile run <task-id> screenshot /tmp/result.png
browser-profile finish <task-id>
```

Each task forks the logins the user last published on the host. Each
concurrent task must create its own task ID. `finish` closes the browser and
deletes that task's profile: save screenshots and outputs outside
`~/.browser-profile` first. Browser processes exit after 30 minutes idle;
reuse the task ID to resume. Forks live in this session's memory only:
nothing they change, including new logins, reaches the host or later
sessions. Do not copy profiles or cookies out of `~/.browser-profile`.

## Logins

Public sites need nothing from the user: browse them right away. `create`
returns `"logins": false` when the user has published no logins, and the task
starts with an empty profile.

You cannot log in persistently or refresh credentials yourself. Only when a site
actually requires a login the fork lacks, ask the user to run on the host:

```
browser-profile login https://example.com
# Sign in in the window that opens, then:
browser-profile publish
```

Then create a new task: running tasks keep their fork. Websites may expire or
rotate credentials; do not promise that forked credentials always work.

## Human control

When the user asks to take over the browser, start the dashboard yourself
inside the environment running that browser. Reuse this environment's existing
dashboard, or choose a free loopback port (4848 is a default, not a requirement)
and run `browser-profile dashboard start --port PORT`. If the installed wrapper
lacks this subcommand, use `agent-browser dashboard start --port PORT` in the
same environment, retaining its daemon socket directory.

Before handing over, poll `http://127.0.0.1:PORT/api/sessions` briefly with
`Origin: http://127.0.0.1:PORT` and confirm the intended session is listed
(`task-<task-id>` for managed tasks). A startup message alone does not prove
readiness. Report a startup failure instead of handing over an unverified
port; retry another free port
if occupied without stopping another environment's dashboard.

Give the user the actual dashboard port, session name, and connection command:

- On the same host, open `http://127.0.0.1:PORT` directly.
- For a remote host, run `ssh -N -L 4848:127.0.0.1:PORT HOST` locally and open
  `http://127.0.0.1:4848`. Fill in the known host and actual port; the local
  listening port can be changed independently. Contained agents share their
  host network, so they do not use the OpenClaw container-forwarding script.

Report the dashboard's listening port, not a session's stream port from the API.
Pause browser automation, including background polling, for the handoff.
Keep the browser, dashboard and task available until the user says to continue;
do not finish the task while they are operating it.
`browser-profile dashboard stop` stops only the dashboard. Human input in a
task still does not publish persistent logins.

## Evidence

Configured browser: headed Chromium on a private display in this container, not
the user's browser. Check current evidence before asserting login state. A
missing snapshot says nothing about the user's login, and a risk page proves a
blocked visit, not an IP, account or browser-mode cause.

To tell whether the GPU is used, read the page's `WEBGL_debug_renderer_info`,
not `/dev/dri`. A command sandbox of your agent, such as Codex's `read-only` and
`workspace-write`, builds its own `/dev` without the GPU. Without network access
the browser does not even start ("Daemon process exited during startup"); with
it, the browser runs on SwiftShader. Neither says anything about the host. Ask
to rerun outside that sandbox.
