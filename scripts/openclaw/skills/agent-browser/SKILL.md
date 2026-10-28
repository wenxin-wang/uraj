---
name: agent-browser
description: Browse websites, log in, take screenshots, and interact with web pages using isolated browser task profiles in the OpenClaw sandbox.
---

# OpenClaw browser tasks

Read `agent-browser skills get core` for browser commands. The lifecycle rules
below override its generic session/profile examples for this environment.
Never invoke raw `agent-browser open`, choose your own session/profile, or use
`--restore`. Use `browser-profile` for all browser operations. Each role has its
own persistent identity; ordinary tasks receive independent copies.

## Login and refresh identity

Only when the user asks to log in or refresh credentials:

```
browser-profile login https://www.xiaohongshu.com
browser-profile identity snapshot -i
browser-profile identity screenshot /workspace/login.png
```

Send the screenshot to the user for QR login. Continue using
`browser-profile identity <command> ...` to check completion. Once login is
confirmed, run `browser-profile publish`. This closes the identity browser and
publishes a consistent snapshot. Do not publish halfway through user login.
Never delete Chromium locks or copy a running profile. If migration reports a
running legacy browser, close its original session first.

## Ordinary browsing

```
browser-profile create
# Save the returned task ID; use it for every operation of this task.
browser-profile run <task-id> open https://example.com
browser-profile run <task-id> snapshot -i
browser-profile run <task-id> screenshot /workspace/result.png
browser-profile finish <task-id>
```

Each concurrent task must create its own task ID. `finish` closes the browser
and deletes that task's profile: send screenshots/save outputs outside the task
directory first. Login changes in a task are NOT merged back. If no snapshot
exists, initialize one with `login about:blank` then `publish`, or ask the user
to log in if required. Browser processes exit after 30 minutes idle, but task
files remain until `finish`. Reuse the task ID to resume after idle shutdown.

Publishing a new snapshot only affects subsequently created tasks. Websites may
expire or rotate credentials; if a task loses its login, refresh the identity
and create a new task. Do not promise that copied credentials always work.
