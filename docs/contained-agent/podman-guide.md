# Local Podman runtime

The central `(podman-remote)` clause starts or reuses a project-owned rootless
Podman runtime next to the Guix agent container, reached through a filesystem
Unix socket.  It needs no SSH identity, extra account or ACLs, and is
independent of SSH clauses.

```scheme
(project "~/Projects/20260929-traj-generation/traj-record"
  (podman-remote (tmpdir "~/.cache/harbor/tmp"))
  (share "~/.cache/harbor"))
```

The normal worktree/Git mounts, project share/expose clauses and explicit TMPDIR
are mounted at the same absolute paths in the runtime.  Nested Git protections
remain read-only mounts.  Agent state, credential mounts, SSH sockets and broad
common agent mounts are not implicitly passed to the runtime.  Missing paths
follow the ordinary project-clause rules; explicit TMPDIR is created before
launch.  Changes apply to new sessions: an existing runtime is never expanded
in place to pick up a different project's permissions.

The runtime receives the Podman API's full execution authority, but its outer
filesystem view limits available bind sources.  A request to bind / exposes
that runtime's root, not the host root.  Shared files use the host user's mapped
identity, so no ACLs or group permission changes are needed.  Paths
overlapping runtime infrastructure and host runtime state are rejected, and
agents can never mount runtime state or the host service's socket.
Mapped share/expose clauses bind their source at the mapped target, so the
runtime sees the paths the agent sees.  Both ends are checked; paths
containing =, colon, comma or newline are rejected instead of guessing how the
engine will parse them.

The agent manifest must supply podman and its chosen Compose provider.  The
launcher sets CONTAINER_HOST and DOCKER_HOST to
`unix:///run/contained-agent/podman/podman.sock` after direnv initialization,
installs a wrapper that selects remote mode, and mounts only the API socket
folder read-only into the agent.  There is no listening TCP port or SSH key.

### Host prerequisites and initialization

Home reconfiguration installs the Python supervisor and pins its Podman
executable through the Guix package closure.  The host needs the existing
`rootless-podman-service-type` setup: subordinate IDs, mapping helpers,
/dev/fuse, /dev/net/tun and permission to create a child of /sys/fs/cgroup with
cpu, memory and pids already enabled.  It does not request sudo or alter global
controller settings when those prerequisites are missing.

### Host Podman service

The outer engine of every runtime is one long-running rootless
`podman system service`, outside any agent session.  Sessions reach it through
its socket and never start Podman themselves.  This is required under the
Paseo broker: its supervisor runs the launcher in a user namespace mapping only
the user's own ID, where the subordinate-ID helpers cannot work, and its PID
namespace would kill a runtime started from a session when that session ends.

| Deployment | Started by |
|---|---|
| Guix System with `paseo-service-type` | Root Shepherd service `contained-podman`, as the Paseo user, at boot |
| Home with Paseo autostart | User Shepherd service `contained-podman` |
| Otherwise | `contained-agent podman-service` in a host terminal |

The service has its own `containers.conf`, overlay storage and pause process
under `~/.local/share/contained-agent/podman/host/`, apart from the user's
ordinary Podman, so pruning or resetting that never reaches project runtimes.
Its socket is `RUNTIME_ROOT/host/podman.sock` and is never mounted into an
agent.  `RUNTIME_ROOT` is `/run/contained-podman/UID` when the system service
has created it at boot, before any login and unaffected by logout; otherwise
`$XDG_RUNTIME_DIR/contained-podman`.  A session fails with a hint when the
service is not running.  Stopping the service leaves running runtimes alone;
each is owned by its own conmon.

The same service stops idle runtimes.  Every minute it checks each runtime
without blocking: one is stopped, as by `podman-stop`, only when no startup
or session holds its locks, its last session left at least 30 minutes ago
(`--idle-minutes`), and its inner engine reports no running containers.
Detached tasks therefore keep a runtime alive; an unresponsive inner API does
not.  Images, volumes and storage are always retained.

Each runtime creates a dedicated host cgroup subtree.  The outer runtime is
rootless, uses a private cgroup namespace and a custom seccomp profile, and
does not use --privileged.  Its brief namespace-UID-0 bootstrap delegates only
the private cgroup management files to UID 1000, then drops UID/GID and clears
supplementary groups before starting the API.  Startup checks the service UID,
rootless status and active seccomp filter.  Service and task cgroups are separate.

The runtime image is pulled by the digest of a pinned `quay.io/podman/stable`
manifest list and must match a verified image ID before it is executed.  Both
are constants in `src/python/uraj/contained_podman.py`.  A mismatch fails
closed; it never silently upgrades the runtime.  The supervisor accepts
explicit image/reference and expected-ID arguments for a reviewed update.  The
pin is a compatibility pin, not signature or provenance verification.

### Lifecycle and storage

The host supervisor connects the Guix agent to a persistent runtime, retaining
stdin, stdout, stderr and the agent exit status.  Sessions with the same project
and effective mount policy reuse one runtime and its writable image store.
The identity also includes the verified runtime image, host Podman executable,
user/subordinate IDs and mount source identities.  Different worktrees or
changed read/write permissions can therefore select different runtimes.  An
existing session's authorization is not revoked by changing new-session policy.

Sessions sharing a runtime share the full Podman API: container names, networks,
volumes and images are common, and one session can stop another's task.  Use
unique Compose project names for simultaneous Harbor runs.  This is one project
trust boundary, not isolation between agents authorized for that project.

Persistent state and logs live under
`~/.local/share/contained-agent/podman/<runtime-id>/`.  Socket and transient
engine state live under `RUNTIME_ROOT/<runtime-id>/` (see above).  Both
directories must be private to the user.  The outer container is named
`contained-agent-runtime-<runtime-id>` in the host service.
Startup prints the runtime ID and log location.  `contained-agent podman-list`
lists every runtime with its ID, whether its container is running, how many
sessions hold it, when it was last used, its project and writable mounts.  A startup lock serializes
creation/recovery; shared session locks prevent an ordinary stop while another
supervised agent session is attached.

Leaving a session does not stop the runtime; the host service stops it after
the idle period.  To stop it earlier, after all sessions exit:

```sh
contained-agent podman-stop RUNTIME_ID
```

This stops its tasks and removes transient state and the private cgroup, while
retaining images, volumes and writable storage.  It refuses while a session
supervisor holds a lease.  Detached tasks do not hold session leases: stopping
an otherwise idle runtime also stops those tasks.  It waits up to 30 seconds
for conmon's cleanup to leave the private cgroup and otherwise reports the
remaining processes, never killing them; rerun it once they exit.  SIGKILL of a supervisor can
release its lease before a surviving agent exits; close such orphaned agents
before explicitly stopping the runtime.

After reboot, the next session recreates the service, socket and cgroup using
the persistent storage; cached images remain available.  It does not resume
old tasks automatically, and old task metadata may remain and cause name
conflicts.  An interrupted startup is retried on the next attachment when no
session holds a lease.  Nothing is purged automatically.  Storage is native
rootless overlay; `--storage-driver=vfs` selects VFS for the inner engine and
is part of the runtime identity, so switching selects separate storage.

Agents' Podman is a remote client, so the inner engine resolves image names.
Its only short-name search registry is docker.io, as with Docker: references
such as `alexgshaw/fix-git:20251031` in task definitions resolve without the
TTY that enforcing mode needs to choose among several registries.  The
image's short-name aliases still apply.  The client's and the host's
registries.conf have no effect here.

### Harbor

Share `~/.cache/harbor` and its TMPDIR, as in the example above, so relative
Compose binds resolve to the same files from the agent and the runtime.  Use
project-local output paths and the configured TMPDIR for generated bind
sources; the synthetic HOME and private `/tmp` files are not runtime bind
sources.  Default privileged tasks are not promised: the tested privileged
variant explicitly binds `/sys` read-only.

### Self-check

```sh
contained-agent podman-check RUNTIME_ID
```

This attaches to the runtime like a session, starting it if needed, so idle
collection cannot stop it meanwhile.  Through its inner API it then checks,
printing PASS or FAIL for each:

- that docker.io is the only short-name search registry;
- a build whose context the client uploads;
- a write through a same-path bind of the first writable directory mount,
  in a temporary `.contained-podman-check-*` directory removed afterwards;
- that every read-only mount refuses writes and a writable remount, in
  ordinary and privileged (read-only /sys) tasks.  Files are probed by opening
  them for append, so nothing changes even if the protection were missing;
- that binding / exposes the runtime's root, not the host's runtime state;
- service name resolution on a user network, which Compose relies on;
- memory, PID and CPU limits as the kernel reports them.

It pulls `docker.io/library/busybox:1.37` into the runtime's storage, and
removes its image tag, containers and network.  It exits non-zero when any
check fails; commands and output are in the runtime's `commands.log`.
