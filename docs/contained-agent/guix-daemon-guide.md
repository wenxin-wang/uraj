# Optional Guix daemon access

> 迁移自 `docs/contained-agent.org` 的 “Optional Guix daemon access”（2026-11-14，内容未改）。

## Optional Guix daemon access

The managed uraj entry includes `(guix-daemon)` so its sessions can run
`guix build`, `guix home/system build` and `guix time-machine`.  It may also
be added to host-private central configuration or an explicitly approved
project-local configuration:

```scheme
(project "~/src/another-project"
  (guix-daemon))
```

This enables `guix shell --nesting`, which provides the running Guix and
daemon socket.  Ordinary requests to mount the daemon socket directly remain
denied.  The wrapper then applies these mappings **after** the project's other
mounts:

- A persistent per-project cache under
  `~/.cache/contained-agent/guix<canonical-project-path>/cache` replaces
  `~/.cache/guix`.  If the host uses `XDG_CACHE_HOME`, that nesting cache path
  is covered too.  The first launch seeds the cache from the host with
  `cp -a --reflink=auto`, guarded by a lock; later launches retain the project
  copy.  Changes never copy back.  Without reflinks the initial copy can
  consume substantial disk space.
- The user's `/var/guix/profiles/per-user/USER/profiles` and `inferiors`
  directories are writable for registering cached profile GC roots.  They
  deliberately override uraj's read-only `/var/guix/profiles` mapping.  These
  are shared host metadata, not project-private copies.

Daemon access is an explicit relaxation: it exposes the daemon protocol,
allows store operations and resource consumption, and lets fixed-output
builds use the daemon's network outside the session's network policy.  The
cache isolation avoids direct writes to host channel checkouts; it does not
turn daemon access into a restricted build API.

`python3 test/python/uraj/guix/contained-agent/contained-agent-guix.py` verifies opt-in, approved local
configuration, one-time independent cache seeding, XDG cache coverage and
mount ordering with real bind mounts.  It does not require a daemon.
After deploying, verify in a new uraj session with:

```sh
guix build hello --dry-run
guix time-machine -C env/guix/channels-lock.scm -- describe
```
