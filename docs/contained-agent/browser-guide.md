# Browser tasks

Agents browse with the same `browser-profile` design as the OpenClaw sandbox
(see [OpenClaw browser-guide](../openclaw/browser-guide.md)): the user
keeps one login identity on the host and publishes snapshots of it; agents
fork tasks from those and can neither log in persistently nor write back.

- Host: Home installs `browser-profile` with its state in
  `~/.local/state/agent-browser` (denied to project requests).  Log in in a
  window of the desktop, then publish:
  ```sh
  browser-profile login https://www.xiaohongshu.com
  browser-profile publish
  ```
  `publish` closes the identity browser and atomically points
  `published/current` at a new copy.  Tasks created afterwards, in running
  sessions too, fork the new one.  Old snapshots are kept; remove those no
  task is copying by hand.
- Container: the launcher creates `published/` (mode 0700) and exposes it
  read-only at `/run/contained-agent/browser`, never `identity/`.  The
  container's `browser-profile` refuses `login`, `identity` and `publish`
  with a hint for the user, and copies tasks into `~/.browser-profile` in the
  session's tmpfs home: they end with the session and changes, logins
  included, never reach the host.  The agent-browser skill in Home
  describes this flow.  With nothing published, `create` starts an empty
  profile, as public sites need no login.  An agent can still read the forked cookies, and
  could copy them into the work tree; publish only logins agents may use.
- Both sides run agent-browser's Chromium with `--password-store=basic`:
  cookies encrypted with the host's keyring would be unreadable inside.
- GPU: the launcher exposes each `/dev/dri/renderD*` with `/sys/dev/char`
  and the device's own `/sys/devices/...` directory, which Mesa reads to
  find it; `--network` keeps the host's network namespace, so Guix mounts
  no `/sys`.
  Every session gets this, in every project, with no opt-out: any agent,
  including a prompt-injected one, can issue ioctls to the kernel's GPU
  driver and submit GPU work.  That widens the kernel attack surface, and
  a runaway or hung job can disturb the desktop.  This is accepted on
  single-user hosts.  Sessions get no `/dev/dri/card*`, debugfs or writable
  sysfs.
- Display: as in the OpenClaw sandbox, Chromium runs headed in a private
  cage on wlroots' headless backend, one per browser, which exits with it:
  headless mode changes what sites see, and Xvfb cannot use the GPU.  Without
  a render node it uses pixman and SwiftShader; a broken GPU path shows as
  missing WebGL.  Their stderr goes to
  `~/.browser-profile/runtime/browser-PID.log`.  Fonts are Noto (including
  CJK and emoji) and Liberation.  Podman runtime sessions get neither the
  snapshots nor the GPU.

`scripts/contained-agent/try-browser` checks all of this on a desktop host
with this checkout's code.

### Operate an agent's browser yourself

agent-browser 0.38.2 includes a dashboard with live page views, mouse/keyboard
input, navigation and tabs. It controls the existing sessions, including
`browser-profile` tasks; no VNC server or compositor change is needed.
In the contained agent session whose browser you want to use, run:

```sh
browser-profile dashboard start --port 4848
```

You can ask the agent to start and verify the dashboard and report its port
and session name. The browser skill includes this handoff. Use the reported
port in the URL or SSH destination below; 4848 is only the default.

Open `http://127.0.0.1:4848` in your own browser and select `task-ID`.
The Guix container shares the host network, so the URL works on the host.
For a remote host, run `ssh -N -L 4848:127.0.0.1:4848 HOST` locally first.
Use a different port for each concurrent contained-agent environment.
The dashboard lists sessions in its own daemon socket directory, so start
it inside the agent environment, not in an unrelated host terminal.
Raw `agent-browser` sessions in that same directory also appear.

`browser-profile dashboard stop` stops the dashboard without closing the
browsers.  If clicks land at shifted coordinates, choose `Fit` in the
dimensions menu at the bottom right; the skill also syncs the viewport before
handing over.  On the host, the same commands view the host's login identity
and tasks.

Ask the agent to wait while you operate the page; dashboard input does not
pause its automation. Resume it afterwards. Input keeps the browser's idle
timer alive. Task logins still remain temporary; persistent logins use the
host's `login` / `publish` flow above. The dashboard shows web content, not
Chromium's native menus or operating-system dialogs.
