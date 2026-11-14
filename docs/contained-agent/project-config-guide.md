# Project configuration

> 迁移自 `docs/contained-agent.org` 的 “Project configuration”（2026-11-14，内容未改）。

## Project configuration

Clauses, in both places below:

- `(expose PATH ...)`, `(share PATH ...)`: extra mounts, skipped when
  the source is missing. Each entry can also be `(SOURCE TARGET)` to mount
  at a different container path. Both source and target expand `~/`;
  relative paths are relative to the current worktree root, even when
  launched from a subdirectory or inheriting the main work tree's policy.
  A plain `PATH` still uses the same source and target. Both ends of a
  mapping are subject to the denied-path checks.
- `(preserve REGEXP ...)`: host environment variables passed through when
  set.
- `(guix-daemon)`: opt into Guix nesting and daemon access, with an isolated
  project cache (details below).
- `(git-hooks DIR)`: `core.hooksPath` in the session's own `~/.gitconfig`,
  so git inside the container runs the hooks in `DIR`, relative to the work
  tree, instead of `.git/hooks`.  The read-only `.git/hooks` cannot take
  them, and host-side git keeps its own hooks.  uraj uses
  `(git-hooks "scripts/coding_style/hooks")`.

Central configuration only: `(podman-remote)`, `(ssh-agent ...)` and the
credential clauses `(github TIER)`, `(git-credential URL FILE)` and
`(env NAME ...)`, described below.

Central: `projects.scm`, keyed by the current work tree's canonical root.
A linked worktree without an entry inherits the entries of the checkout
Paseo created it from, if that checkout has any, and otherwise the main
work tree's.  The source comes from Paseo's registry
(`$PASEO_HOME/projects/{workspaces,projects}.json`, default `~/.paseo`),
which no container mounts; it counts only when it is a work tree of the
same repository.  A missing or unreadable registry falls back to the main
work tree.  An explicit worktree entry in any central source replaces that
fallback across all sources; even an empty `(project "PATH")` disables
inheritance.
It reaches the program through Home, so the
agent cannot change it, and changing it takes a reconfigure.

```scheme
(project "~/src/uraj"
  (expose "/var/log" "/run/current-system" "/run/booted-system"
          "/var/guix/profiles" "~/.local/state/shepherd" "~/.guix-home"
          "~/.config/shepherd" "~/.config/guix"))
```

For example, share one ignored data directory across linked worktrees,
and expose reference data read-only at a worktree-relative location:

```scheme
(project "~/src/uraj"
  (share ("~/src/uraj/instances" "instances"))
  (expose ("~/datasets/reference" "data/reference")))
```

These are container mounts; they do not create host-side symlinks. The
target need not exist, and a mount hides existing target contents for the
session. Worktrees with their own explicit project entry must include any
desired mappings themselves.

#### Fixed worktrees as permission presets

Create a branch and a sibling worktree with the common shell helper:

```sh
fork-worktree ~/src/uraj maa
# Branch maa, directory ~/src/uraj-maa, starting at uraj's HEAD.
fork-worktree ~/src/uraj docs ~/workspaces/uraj-docs
# The optional third argument overrides the target directory.
git -C ~/src/uraj worktree list
```

After creating the worktree, the helper opens
`~/.config/contained-agent/projects.local.scm` with `$VISUAL`, then `$EDITOR`
as a fallback, or `vi` when neither is set.  Editor arguments are supported.
The file is created with private permissions if missing; existing content
is preserved.  A failed worktree creation does not open the editor.

Add an exact `(project "~/src/uraj-maa" ...)` entry on the host for its
required permissions instead of inheriting the main work tree's.  Subdirectory
launches use that worktree's root; symlink aliases resolve to the same root.
In Paseo, add this directory as a project and select `Local` to use it
directly.  `New worktree` in that project creates another path which
inherits this entry unless it has its own central entry.

Worktrees share Git objects and branches, but have separate working files
and indexes.  A branch normally cannot be checked out in two worktrees.
Remove a clean, unused worktree with `git -C ~/src/uraj worktree remove PATH`;
its branch remains.  Remove its host policy too when retiring the path.

Configure explicit entries for worktrees that need different permissions.
Run `contained-agent allow`
and `direnv allow` on the host in each worktree whose approvals it cannot
inherit (see [Inherited approvals](#inherited-approvals)); approvals of unrelated checkouts are
not reused.  Restart sessions to apply the new policy.  Shared Git metadata
and the normal base sandbox remain; local approvals remain recorded per
worktree.

#### Additional central configuration

Host-private additions: `~/.config/contained-agent/projects.local.scm`.
Create this file on the host, preferably with mode `0600`.  It uses the same
`(project ROOT CLAUSES ...)` syntax as the managed central file.  Matching
entries from both files are appended; neither replaces the other's entry.
If absent, it is skipped.  Edits are read on the next launch, without Home
reconfigure or `contained-agent allow`.

A host can also keep such additions encrypted in the repository, as
`secrets/hosts/HOST/contained-agent.yaml`, which SOPS decrypts to
`/run/secrets/contained-agent/projects.scm` (see
[docs/secrets/agent-secrets-guide.md](../secrets/agent-secrets-guide.md)).  It joins the other two
files with the same syntax and rules.  The launcher knows, from build time,
which hosts have one: there, it waits up to 10 seconds for the file, as an
agent may start at boot before SOPS is done, then fails rather than start
without it.

This is user-level central policy, **not** project-local configuration.  Keep
private paths, SSH identities and destinations here instead of in the public
repository.  The program reads it at runtime; Home does not import it into
the store.  Its parent directory is denied to container mount requests.
Only one `ssh-agent` clause per project is accepted across these files;
duplicates fail instead of silently overriding a policy.  Put that whole
clause in the private file when its contents are sensitive.

### Credentials

Central files alone may also hand credentials to a project.  Each names a
host file, read at every launch: one that appears later reaches the next
session without restarting anything.  A missing, unreadable or empty file is
skipped with a warning, and nothing of the host's stands in for it.  The
value never appears on a command line.  A project-local credential clause,
even approved, is a bad clause.

- `(github TIER)`: git over HTTPS and `gh` on github.com, with the token SOPS
  decrypts to `/run/secrets/github/TIER`.  Unlike other credential files,
  on Guix System, whose agent hosts all declare the tokens, a missing one
  is waited for, up to 10 seconds, and then fails the launch; on foreign
  distros, which have no SOPS service, the clause is skipped with a
  warning.  Tiers nest:

  | Tier | Token | Reaches |
  |---|---|---|
  | `public` | fine-grained, selected repositories | your public repositories |
  | `personal` | fine-grained, all repositories | all your repositories |
  | `world` | classic, `repo` and `workflow` scopes | every repository you can reach |

  All may push (including workflow files) and open pull requests;
  only `world` may fork, or open pull requests on repositories of others.
- `(git-credential URL FILE)`: git over HTTPS below `URL`, which must start
  with `https://`.  git matches it as a prefix of whole path segments, so
  `https://github.com/OWNER` covers that owner's repositories, while
  `…/REPO.git` misses a remote spelled `…/REPO`.  These come before the tier:
  give an isolated project only this clause, or narrow one owner of a tier.
- `(env NAME (file FILE))`: the variable `NAME` set to `FILE`'s contents.
  It overrides `preserve`, which passes the launcher's own environment: the
  host's value is dropped even when the file is missing.
- `(env NAME (value VALUE))`: the variable `NAME` set to `VALUE` as
  written.  Only in the private files, `projects.local.scm` and the
  SOPS-decrypted `projects.scm`; in the Home-managed `projects.scm`, which
  is in Git and the store, it fails the launch.  Like `(file FILE)`, it
  overrides `preserve` and never appears on a command line.

The token files of `github` and `git-credential` are each mounted alone,
read-only, at `/run/contained-agent/git-credential-N`.  The launcher
configures git through `GIT_CONFIG_COUNT`, read after `~/.gitconfig`: an
empty `credential.helper` drops the host's helpers (such as the one
`gh auth setup-git` installs), then each URL gets a helper that answers
`get` from its file and ignores `store` and `erase`.  The container's `gh`
is a wrapper that runs GitHub CLI with the token git gives for the current
repository's `origin`, or for github.com outside a repository.  An explicit
`GH_TOKEN` wins.  `gh -R OTHER/REPO` still uses the current repository's
token, which is the same one unless a `git-credential` clause applies.

Remotes must use HTTPS for these to apply; SSH remotes keep using the
`ssh-agent` clause, if any.  The tokens live inside a container with
network access: treat them as readable by anything the agent runs; their
scope is the protection.  [docs/secrets/agent-secrets-guide.md](../secrets/agent-secrets-guide.md) covers requesting and rotating
them.  uraj uses `(github "personal")`.

Central configuration can select a manifest for this worktree:

```scheme
(project "~/src/uraj-maa"
  (manifest ".guix/maa-manifest.scm"))
```

The `manifest` clause is accepted only in the managed or host-private
central project configuration.  Its path is relative to the worktree root,
not the launch directory.  Absolute paths, `.` or `..` components, symlinks,
missing files and multiple manifest clauses are errors, without fallback.
Both `contained-agent allow [DIRECTORY]` and session startup read the same
central selection.  Selecting a manifest does not approve its contents.

For a selection inside `.guix/`, approval still covers the whole `.guix/`
directory, including `contained-agent.scm` and sibling Scheme files, and
Guix uses the selected filename in the approved copy.  A selection elsewhere,
such as `(manifest "maa-manifest.scm")`, approves that file alone instead of
`.guix/`; it is copied to `manifest.scm` in the approval directory.  Any files
it loads are not covered by that approval.  Put related files under `.guix/`
when they need to be reviewed and copied together.

After editing the central selection, run `contained-agent allow` in that
worktree and restart the session.  Changed or unapproved contents are left
out with a warning; the launcher never falls back to the default manifest.

Without an explicit manifest selection, project-local files are
`.guix/contained-agent.scm` (same clauses at top level) and
`.guix/manifest.scm`, or a top-level `manifest.scm`.  The agent can write
them, and `guix shell` evaluates a manifest on the host, outside any
sandbox.  So they count only once approved:

1. `contained-agent allow` copies them to a staging directory, shows
   `git diff` against the last approved copy and asks on a terminal.
2. On `y` the copy is kept under its nar hash in
   `~/.local/state/contained-agent/approved/<encoded-worktree-path>/`.
3. A session hashes the current work tree's files and, on a match within
   that work tree's approval directory, loads the
   approved copy, never the work tree.  Otherwise it warns and starts
   without them.

The whole `.guix` directory is hashed, as a manifest may `load` its
siblings.  Links inside it are refused: they could reach unreviewed files.
A top-level `manifest.scm` is hashed alone, so anything it loads is not
covered.

<a id="inherited-approvals"></a>A new worktree takes over the approvals of a
checkout it inherits policy from: the one Paseo created it from, else the
main work tree, as for central entries.  Both registries are outside every
container.  It does so only when that checkout has approved, at its own
path, both the worktree's current project-local files (same nar hash) and
its current `.envrc` (as direnv names the approval), each where present.
Then the worktree's approval directory gets a link to the checkout's
approved copy, and the host's `~/.local/share/direnv/allow/` an approval of
the worktree's `.envrc`, so plain host shells load it too.  Nothing is taken
over otherwise, not even one of the two.

Sessions do this at startup; `contained-agent inherit [DIRECTORY]` does it
for host shells before any session, and reports what it found.

Requests never mount anything under these, nor any directory containing
one (such as `$HOME` or `/`): `~/.paseo`, `~/.paseo-password`, `~/.ssh`,
`~/.gnupg`, `~/.password-store`, `~/.config/contained-agent`,
`~/.local/state/contained-agent`, `~/.local/state/paseo-broker`,
`~/.local/state/agent-browser`, `/var/guix/daemon-socket`, `/run/secrets`,
`/run/user`.
