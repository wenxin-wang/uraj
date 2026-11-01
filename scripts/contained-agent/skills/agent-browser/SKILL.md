---
name: agent-browser
description: Browse websites, take screenshots, and interact with web pages using browser task profiles forked from the user's published logins.
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

You cannot log in persistently or refresh credentials yourself. When
`browser-profile create` reports no snapshot, or a site needs a login the fork
lacks, ask the user to run on the host:

```
browser-profile login https://example.com
# Sign in in the window that opens, then:
browser-profile publish
```

Then create a new task: running tasks keep their fork. Websites may expire or
rotate credentials; do not promise that forked credentials always work.

## Evidence

Configured browser: headed Chromium on a private display in this container, not
the user's browser. Check current evidence before asserting login state. A
missing snapshot says nothing about the user's login, and a risk page proves a
blocked visit, not an IP, account or browser-mode cause.
