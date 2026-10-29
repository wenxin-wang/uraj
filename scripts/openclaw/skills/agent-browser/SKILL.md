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

When the user asks to log in or refresh credentials, or a task needs a login
this identity lacks:

```
browser-profile login https://www.xiaohongshu.com
browser-profile identity snapshot -i
browser-profile identity screenshot /workspace/login.png
```

Send the screenshot to the user for QR login, following this conversation's
rules for where login codes may go. Continue using
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
exists, initialize one with `login about:blank` then `publish`. Browser
processes exit after 30 minutes idle, but task files remain until `finish`.
Reuse the task ID to resume after idle shutdown.

If a site the task needs shows a login wall, the task is blocked: finish the
task, ask the user to log in through the flow above, and resume with a new task
after publishing. Do not first answer from other sources unless the user agrees.

Publishing a new snapshot only affects subsequently created tasks. Websites may
expire or rotate credentials; if a task loses its login, refresh the identity
and create a new task. Do not promise that copied credentials always work.

## Reporting what happened

The browser is headed Debian Chromium inside this sandbox, using this role's
identity; it is never the user's own browser or profile. When asked about the
browser, check (`printenv | grep AGENT_BROWSER`, `ps -eo args`) instead of
inferring from tool names.

"No snapshot" only means this role never published one; the identity may still
hold a login, and `login about:blank` then `publish` keeps it. Check the site's
own login state before telling the user they are logged out.

A risk-control, captcha or "security restriction" page proves only that the
site blocked this visit. Quote what the page says and report it as blocked; do
not name a cause (IP, login state, browser mode) without evidence. If you fall
back to other sources, say so and keep their results separate from the site
the user asked for.
