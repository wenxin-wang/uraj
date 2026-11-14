# contained-agent overview

> 迁移自 `docs/contained-agent.org` 的 “开头”、“Components”、“Use”、“What agents cannot do”（2026-11-14，内容未改）。

`contained-agent` runs a coding agent (Codex, Claude Code, OpenCode, Pi) inside
`guix shell --container`.  The container shares only the current project
and the parts of the agent's own state that must persist.  The same command
serves interactive use in a terminal and Paseo, which launches agents
remotely.

The threat model is an agent that follows instructions it reads in logs,
web pages or third-party code (prompt injection), or that makes a well-meant
destructive change.  The sandbox has to hold without the agent's
cooperation.

## Components

| Path | Role |
|---|---|
| `src/guile/uraj/bin/contained-agent.scm` | The program: plain Guile, no `(guix ...)` modules |
| `src/guile/uraj/bin/contained-ssh.scm` | Host-side per-project ssh-agent lifecycle and key loading |
| `src/guix/uraj/home/llm.scm` | Agent specs, package list, `program-file`, Home files |
| `env/dotfiles/llm/contained-agent/.config/contained-agent/projects.scm` | Per-project clauses, owned by the user |
| `~/.local/state/contained-agent/` | Approved copies of project-local files |
| `~/.config/contained-agent/projects.local.scm` | Optional host-private central additions, never Home-managed |
| `/run/secrets/contained-agent/projects.scm` | Optional host-private central additions, decrypted by SOPS |

The program calls the `guix` command (`guix shell -C ...`) rather than Guix
modules.  `llm.scm` generates the entry point with `program-file` and passes
in everything known only at build time: store paths of the real `codex`,
`claude`, `opencode` and `pi`, of `git`, the agent specs and the package
list.  Home installs:

- `~/.local/bin/contained-agent`
- `~/.local/bin/codex`, `~/.local/bin/claude`, `~/.local/bin/opencode`
  and `~/.local/bin/pi`: store items that are
  themselves links to `contained-agent`, made with `computed-file`.
  An app-managed Paseo (no broker) omits the `opencode` link: see below.

The program dispatches on the name it was invoked as (minus a store hash
prefix).  Under an agent's name it takes exactly that agent's arguments;
as `contained-agent` the first argument names the agent, or is `allow` or
`inherit`.

## Use

- Terminal: `~/.local/bin` comes first in `PATH` (`.profile.d/61-paths.sh`),
  so `codex`, `claude`, `opencode` and `pi` are the contained ones.
  The originals remain at `~/.guix-home/profile/bin/`.
- Paseo: Home activation configures daily broker clients in `~/.paseo/config.json`
  (see [daemon service](../paseo/daemon-guide.md)):
  ```json
  "agents": { "providers": {
    "codex":  { "command": ["/home/wenxin/.guix-home/profile/bin/paseo-codex-daily"] },
    "claude": { "command": ["/home/wenxin/.guix-home/profile/bin/paseo-claude-daily"] },
    "pi":     { "command": ["/home/wenxin/.guix-home/profile/bin/paseo-pi-daily"] } } }
  ```
  Paseo's OpenCode runs on the host only (`opencode-host`): one shared
  server handles all workspaces, which no project container can hold.
  Where Paseo is app-managed (`%paseo-setup` is `#f`), no broker provides
  that host tier, so Home omits `~/.local/bin/opencode` and the app's
  built-in provider starts `~/.guix-home/profile/bin/opencode` from `PATH`
  instead.  Keeping the wrapper there would confine the shared server to
  one project and make every other workspace unreachable.
  Restart the daemon after a change: it caches the provider version probe.
- Approve a project's own files: `contained-agent allow [DIRECTORY]`.
- Approve a new worktree as its source checkout (see [Inherited approvals](project-config-guide.md#inherited-approvals)):
  `contained-agent inherit [DIRECTORY]`.

## What agents cannot do

- Use SSH by default.  The optional central `ssh-agent` clause below grants
  access to a project's dedicated agent, not the host's normal agent or
  private key files.  GPG remains unavailable.
- Use `gh` or HTTPS git credentials by default, or ever with the host's
  login: `~/.config/gh` is not mounted and the host's credential helpers are
  dropped.  The optional central `github` clause above grants a tier.
- Reach the Guix daemon by default.  Projects opting into `(guix-daemon)`,
  including uraj, can build and use nested Guix environments.
- Control the user's Shepherd (`/run/user/UID`) or see host processes
  (separate PID namespace; mounting the host's `/proc` would expose other
  processes' environments).
- Read `/var/log/debug`, `secure` or `guix-daemon.log`: those are root-only
  even for the user; only `messages` is in `log-readers`.
