# The contained-agent container

- `--container --no-cwd --network --expose=/gnu/store`.  The whole store is
  read-only, so store links in configuration (MCP servers, skills) resolve.
- `/usr/bin/env` links to the profile's `env` (`--symlink`), as on Guix
  System, so `#!/usr/bin/env` scripts run.
- The environment is cleared; agent specs and projects list what to keep
  (`--preserve`).  `SSL_CERT_FILE` and friends point at the profile's
  `nss-certs`.
- Packages: `%agent-tool-packages` (shared with Home, so the CLI matches the
  Home-installed skill) plus `%contained-agent-packages` (the container's base
  tools, including `bubblewrap` for Codex's own sandbox and the overlays), both
  in `llm.scm`, alongside an approved project manifest.  Changes take effect
  after Home reconfigure and a new agent session.
- The network is the host's (`--network`): agents reach the Paseo API on
  port 6767 and the LAN.  There is no egress filtering.
- All agents can read `~/src` when it exists, including other repositories
  and their uncommitted files.  Common mounts come first; the current work
  tree is then mounted read-write, followed by its Git protections.  Other
  projects remain read-only unless separately granted write access.
- All agents can read `~/.cache/paseo-tmp` when it exists. Paseo uses it as
  `TMPDIR` so Codex's `localImage` paths work across container boundaries.
  This includes other sessions' attachments and temporary files; see
  [image attachments](../paseo/daemon-guide.md#image-attachments) for setup and cleanup.
- All agents can also read `~/.paseo/uploads`, where Paseo stores file
  attachments such as PDFs. Only this subtree is exposed read-only; the
  remaining Paseo state stays private. This includes uploads from other
  sessions.
- All agents can read `~/.agents` and `~/.local/share/agent-policies` when they
  exist.  Both are read-only, like long-term memory, so a session cannot
  plant instructions that later sessions load.  Codex and Pi still get a
  session-only writable overlay of `~/.agents/skills`.
- Clone temporary reference code into `/tmp/reference-code/`, or use an
  ignored `.reference-code/` directory in the current worktree to retain it.
  Read access to `~/src` does not grant permission to clone into it.

### Working directory

Paseo starts `codex app-server` from its own working directory, `$HOME`,
and tells Codex the session directory over JSON-RPC.  Claude and Pi are
started with the session directory as working directory.  All get
`PASEO_AGENT_CWD`.
Every process below an agent inherits that variable, so it is trusted only
when the working directory is `$HOME`.

A working directory of `$HOME` or `/` shares no project at all: Paseo's
helper app-servers (model lists...) run that way.

Projects are mounted at their host path.  A fixed path such as `/work/proj`
does not work: Paseo passes host paths to the agent.

### Git

The worktree and the repository's common git directory are separate
read-write mount points.  Read-only mount points on top cover what makes
host-side git run code or read other files:

- `hooks/` and `config` of the common directory;
- a linked worktree's `.git` file;
- `worktrees/` as a whole, then the session's own worktree directory
  read-write again, with its `commondir` and `gitdir` read-only.

A mount point cannot be renamed or removed (`EBUSY`).  The rule that makes
this hold: every directory from a protected path up to the root of the
writable share containing it must itself be a mount point.  That is why
`.git` is a share of its own.  A read-only mount point inside a writable share
could otherwise be escaped by renaming its parent (`mv .git .git.x`, then
recreating `.git` with a malicious `config` or hook).

The main worktree of a linked worktree is automatically exposed read-only,
even outside `~/src`, subject to the usual denied-path rules.  Bare
repositories have no main worktree to expose.  Commits land in the shared
`.git` and show up on the host at once.
If `git worktree list` cannot identify the main worktree (for example with
`--separate-git-dir`), expose it explicitly in project configuration.

Because `config` is read-only, commands writing it fail: `git push -u` pushes
but warns `could not write config file`, and `git remote add` or
`git branch -u` fail outright.  Making `config` writable is not an option:
`core.fsmonitor`, `core.sshCommand`, filters and aliases there make host-side
git, such as shell prompts and editors, run commands.

The host's Git configuration stays outside, but for the identity in
`~/.gitconfig.local`, exposed read-only.  Its managed part,
`~/.config/git/config`, holds preferences (aliases, `core.fsmonitor`, whose
daemon socket lives in the shared `.git`, `status.aheadBehind = false`), and
applications write `~/.gitconfig`.  The container's `~/.gitconfig` is its own
instead, written at startup in the session's tmpfs home and dropped on exit:
it includes `~/.gitconfig.local` and sets `push.default=current` and the
Git LFS filter.  The agent may change it, and git reads `branch.*` and
`remote.*` from any scope, so it stands in for the repository's file for the
session:

| Instead of | Run |
|---|---|
| `git push -u origin B` | `git push origin B`, then `git config --global branch.B.remote origin` and `branch.B.merge refs/heads/B` |
| `git remote add R URL` | `git config --global remote.R.url URL` and `remote.R.fetch '+refs/heads/*:refs/remotes/R/*'` |
| `git config KEY VALUE` | `git config --global KEY VALUE` |

A `git-hooks` clause (see [project-config-guide](project-config-guide.md)) sets `core.hooksPath`
in the same file, as hooks cannot be installed in the read-only `hooks/`.
uraj's host-side hook, which `scripts/coding_style/install-hooks` links
into the main worktree, is a deliberate exception to the read-only
`hooks/`: host-side commits run the worktree's check, which agents can
change.

With `push.default=current`, a bare `git push` pushes the current branch to
its namesake on `origin`, and `@{push}` resolves, without any upstream.

### direnv

`direnv` is among the container packages.  Its approvals live in the
tmpfs home, so they start empty; the launcher carries over a single one,
for the worktree's top-level `.envrc`, only when the host approved that
exact path.  Linked worktrees need an approval of their own path, which
they may inherit, see [Inherited approvals](project-config-guide.md#inherited-approvals); otherwise run `direnv allow`
in each worktree.

The approval is written as direnv records it, under
`~/.local/share/direnv/allow/`, and is dropped on exit; one the agent adds
stays inside the session.

The environment loads automatically:

- at startup, in the working directory, for the agent itself, so its own
  processes (MCP servers, Codex's app-server) and shell snapshots see it.
  A slow `.envrc` delays the agent's start; a blocked one only logs an
  error;
- again before each command, which may run in another directory or after
  `.envrc` changed.  Claude Code sources `$CLAUDE_ENV_FILE` after its shell
  snapshot, which would otherwise reset `PATH`; other agents' `bash -c` or
  `bash -lc` reads `BASH_ENV`, which steps aside when `CLAUDECODE` is set.
  Both run `direnv export bash` with status messages off; errors, such as
  a blocked `.envrc`, still show.  `sh` does not read `BASH_ENV`.

The session gets an empty `~/.config/direnv/direnv.toml`, without which direnv
ignores `DIRENV_LOG_FORMAT`.

### Mount rules

- `guix shell -C` mounts options in command-line order; a later mount covers
  an earlier one.  User mappings come after `--nesting`'s.
- `--nesting` shares the host's `~/.cache/guix` read-write; the optional
  `guix-daemon` clause covers it with a project cache, see
  [guix-daemon-guide](guix-daemon-guide.md).
- Mounts follow links, so a link cannot be pinned read-only.
  `~/.claude/settings.json` is a link: the link itself could be replaced
  even though its target was read-only.  Hence the overlay for `~/.claude`.
- An overlay's lower directory must hold no mount points, or the mount fails
  with `EINVAL` (tmpfs and btrfs alike).  Hence `persist` paths are mounted
  aside and bound back.
- A single-file mount cannot be renamed over.  Claude's atomic writes fall
  back to writing in place; tools without such a fallback fail.
- SQLite creates and deletes `-wal`, `-shm` or `-journal` files next to the
  database, so a database must persist with its whole directory: persisting
  the file alone loses committed data and breaks locking across concurrent
  sessions.
- Guix's synthetic home tmpfs can start with mode `1777`, which OpenSSH
  rejects when it discovers `~/.ssh/config`.  The container bootstrap changes
  only that directory to `0700`; it does not chmod mounted host data.
