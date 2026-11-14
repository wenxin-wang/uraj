# 早期踩过的坑

Each of these was hit or tested while building this.

### Paseo
- Codex is launched without a working directory; the session directory comes
  over JSON-RPC and in `PASEO_AGENT_CWD`, which children inherit.  An early
  test run from inside a Paseo session therefore ran in the wrong
  repository and committed there.
- Paseo kills agents with `tree-kill`, which reaches processes inside the
  container; `SIGTERM` to the `guix` process alone does nothing.

### Guix
- `home-dotfiles-service-type` imports files with `local-file`, which
  follows links: a link in the dotfiles tree becomes a copy.  Use a
  `computed-file` that is itself a link.
- Invoked through a store path the program name is `HASH-codex`; the hash
  is stripped before dispatching.
- `guix shell -C` mounts options in command-line order; a later mount covers
  an earlier one.  User mappings come after `--nesting`'s.
- Inside the container `HOME` comes from `passwd`, not the caller's
  environment: tests with a fake `HOME` must use absolute paths.
- `execlp` replaces the process before Guile flushes the error port:
  warnings need `force-output`.
- `--nesting` shares the host's `~/.cache/guix` read-write: the channel
  checkouts that host-side `guix pull` and `time-machine` evaluate.  The
  optional `guix-daemon` clause covers this with a project-specific cache,
  mounted after nesting's mappings.  See [Optional Guix daemon access](../../../contained-agent/guix-daemon-guide.md) for
  the remaining tradeoffs.

### Mounts
- Guix's synthetic home tmpfs can start with mode `1777`.  OpenSSH rejects
  this when discovering `~/.ssh/config` by default.  The container bootstrap
  changes only that synthetic home directory to `0700` before starting the
  agent; it does not recursively chmod mounted host data.  An explicit
  `ssh -F FILE` test does not cover this permission check, so the regression
  test also exercises default config discovery.
- A read-only mount point inside a writable share can be escaped by
  renaming its parent: `mv .git .git.x` and recreate `.git` with a
  malicious `config` or hook.  Directories created by Guix for mount points
  live in the container's tmpfs and are harmless.
- Mounts follow links, so a link cannot be pinned read-only.
  `~/.claude/settings.json` is a link: the link itself could be replaced
  even though its target was read-only.  Hence the overlay for `~/.claude`.
- An overlay's lower directory must hold no mount points, or the mount fails
  with `EINVAL` (tmpfs and btrfs alike).  Hence `persist` paths mounted
  aside and bound back.
- A single-file mount cannot be renamed over.  Claude's atomic writes fall
  back to writing in place; tools without such a fallback fail.
- SQLite creates and deletes `-wal`, `-shm` or `-journal` files next to the
  database.  Persisting the database file alone leaves those in the
  overlay: committed data is lost, and concurrent sessions each get their
  own `-shm`, which breaks locking and can corrupt the database.  A database
  must persist with its whole directory.

### Agents
- Codex's own `workspace-write` sandbox (Paseo's `auto` mode) makes `.git`
  entirely read-only.  Failures there do not say whether our layer would
  have stopped them; test with `full-access` to see our layer alone.
- `node_repl` processes from the `codex-desktop` store item are MCP servers
  that `config.toml` points at, started by contained Codex sessions; they
  do not mean the desktop app is running.
- Plugin caches in an overlay: a marketplace update is downloaded again by
  every session until a host-side Codex syncs it.
