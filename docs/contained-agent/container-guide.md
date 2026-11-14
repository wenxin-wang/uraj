# The contained-agent container

## The container

- `--container --no-cwd --network --expose=/gnu/store`.  The whole store is
  read-only, so store links in configuration (MCP servers, skills) resolve.
- `/usr/bin/env` links to the profile's `env` (`--symlink`), as on Guix
  System, so `#!/usr/bin/env` scripts run.
- The environment is cleared; agent specs and projects list what to keep
  (`--preserve`).  `SSL_CERT_FILE` and friends point at the profile's
  `nss-certs`.
- Packages: `%agent-tool-packages` in `llm.scm` is shared with Home and
  currently includes `agent-browser`.  The launcher imports a manifest of
  these exact package builds, so the CLI matches the Home-installed skill
  without depending on the runtime Guix channels.  Add shared agent tools
  to this list.  `%contained-agent-packages` adds the container's base tools,
  alongside an approved project manifest.  The defaults include Python,
  Perl, `bc`, `curl`, `wget`, `jq`, `file` and common archive tools, alongside
  Git, `fd` (so Pi need not download it each session) and shell utilities.
  `bubblewrap` provides `bwrap`, needed by Codex's
  own command sandbox and by the overlays below.  Changes to the default package list
  take effect after Home reconfigure and starting a new agent session.
- The network is still the host's (`--network`).  An allowlisting proxy is
  future work; see [Open items](../archive/contained-agent/open-items-design-20261012.md#open-items).
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
  sessions. Activation and daemon startup create the directory before agents
  launch; new uploads remain visible through the directory mount.
- Clone temporary reference code into `/tmp/reference-code/`, or use an
  ignored `.reference-code/` directory in the current work tree to retain it.
  Read access to `~/src` does not grant permission to clone into it.

### Working directory

Paseo starts `codex app-server` from its own working directory, `$HOME`,
and tells Codex the session directory over JSON-RPC.  Claude and Pi are
started with
the session directory as working directory.  All get `PASEO_AGENT_CWD`.
Every process below an agent inherits that variable, so it is trusted only
when the working directory is `$HOME`.

A working directory of `$HOME` or `/` shares no project at all: Paseo's
helper app-servers (model lists...) run that way.

Projects are mounted at their host path.  A fixed path such as `/work/proj`
does not work: Paseo passes host paths to the agent.

### Git

The work tree and the repository's common git directory are separate
read-write mount points.  Read-only mount points on top cover what makes
host-side git run code or read other files:

- `hooks/` and `config` of the common directory;
- a linked worktree's `.git` file;
- `worktrees/` as a whole, then the session's own worktree directory
  read-write again, with its `commondir` and `gitdir` read-only.

A mount point cannot be renamed or removed (`EBUSY`).  The rule that makes
this hold: every directory from a protected path up to the root of the
writable share containing it must itself be a mount point.  That is why
`.git` is a share of its own.  See [Pitfalls](pitfalls-guide.md#pitfalls) for the tests behind it.

The main work tree of a linked worktree is automatically exposed read-only,
even outside `~/src`, subject to the usual denied-path rules.  Bare
repositories have no main work tree to expose.  Commits land in the shared
`.git` and show up on the host at once.
If `git worktree list` cannot identify the main work tree (for example with
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

A `git-hooks` clause (see [Project configuration](project-config-guide.md#project-configuration)) sets `core.hooksPath`
in the same file, as hooks cannot be installed in the read-only `hooks/`.
uraj's host-side hook, which `scripts/coding_style/install-hooks` links
into the main work tree, is a deliberate exception to the read-only
`hooks/`: host-side commits run the work tree's check, which agents can
change.

With `push.default=current`, a bare `git push` pushes the current branch to
its namesake on `origin`, and `@{push}` resolves, without any upstream.

### direnv

`direnv` is among the container packages.  Its approvals live in the
tmpfs home, so they start empty; the launcher carries over a single one,
for the work tree's top-level `.envrc`, only when the host approved that
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

direnv 2.37 honours `DIRENV_LOG_FORMAT` only when it has a configuration
file, so the session gets an empty `~/.config/direnv/direnv.toml`.
