# Harbor acceptance

> 迁移自 `docs/contained-agent.org` 的 “Harbor acceptance”（2026-11-14，内容未改）。

## Harbor acceptance

The worktree already includes jobs/, instances/ and the apt-cacher files.
Sharing \~/.cache/harbor and its TMPDIR lets relative Compose binds resolve to
the same files from the agent and runtime.  No extra /jobs mount is needed.
Use project-local output paths and the configured TMPDIR for generated bind
sources; synthetic HOME and private /tmp files are not runtime bind sources.

A disposable host experiment (2026-10-25, lappie, overlay storage) passed the
same checks, plus Compose itself, before the host service replaced its local
outer engine; `podman-check` now covers them on the deployed path.  The
persistent runtime still needs concurrency/reboot smoke tests and a real
Harbor trial in traj-record.  Default privileged tasks are not promised: the
tested privileged variant explicitly binds /sys read-only.  A Guix-built
runtime image remains follow-up work.
