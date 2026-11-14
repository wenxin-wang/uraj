# Paseo broker

> 迁移自 `docs/paseo-broker.org` 的 “开头”、“Implemented trial and lappie commands”、“Execution tiers”（2026-11-14，内容未改）。

## Implemented trial and lappie commands

| File | Role |
|---|---|
| `src/python/uraj/paseo/broker.py` | Unix seqpacket protocol, FD passing, provider clients, configuration switch/restore, status |
| `src/c/uraj/paseo/agent-supervisor.c` | Parent pidfd/PDEATHSIG links, user/PID/mount namespaces, trusted init, cancellation and exit status |
| `src/guix/uraj/home/paseo-broker.scm` | Guix build, standalone trial bundle, Home files and Shepherd service |
| `test/python/uraj/guix/contained-agent/paseo-broker.py` | Real-process integration tests with fake providers |

The broker accepts only same-UID peers for now.  It permits project cwd under
\~/src, \~/Projects and \~/.local/share/paseo/worktrees by default, plus a
no-project home cwd for probes.
Storie uses the same roots under /home/wenxin.  `--root` on the
server changes the roots.  Cwd is canonicalized, but concurrent host-path
rename/symlink attacks are not fully hardened; do not yet treat this as the
untrusted cross-UID/Paseo-container boundary described in the longer design.
It executes the existing installed contained-agent policy, including its
current optional SSH/Guix access settings; broker transport adds no new grant.

The supervisor records namespace init identity before releasing its launch
gate. Execution directories also record the boot ID so persistent records
from an earlier boot cannot match a reused PID. A broker restart checks
recorded PID/start-time identities with pidfds
and waits for old namespace teardown before removing execution temporary
directories.  SIGTERM cancellation allows two seconds; the broker additionally
escalates a stuck supervisor after five seconds.  Runtime files/socket are
user-private.  Status exposes metadata only, not argv or credentials.

In a host terminal on lappie, as wenxin (no sudo), build a GC-rooted trial:

```sh
cd ~/src/uraj
mkdir -p ~/.local/state
paseo_bundle=$(guix build -L src/guix -L src/guile \
  -r "$HOME/.local/state/paseo-broker-trial" \
  -e '((@ (uraj home paseo-broker) paseo-broker-bundle) (@@ (uraj home llm) contained-agent))')
herd load root "$paseo_bundle/share/paseo-broker/shepherd.scm"
herd start paseo-broker
"$paseo_bundle/bin/paseo-broker" status
```

These explicit trial commands load and start the service in the existing user
Shepherd.  Normal Home reconfiguration installs the profile clients and automatically
merges their commands into Paseo configuration. On Guix System the root
Shepherd owns the boot service; foreign Home registers user services. Do not
load a trial broker alongside either managed service.  Replacing a running broker
can end its executions; finish them before deploying a new service definition.

Managed brokers run Home's `~/.local/bin/contained-agent`, resolved for each
execution, so a Home reconfigure reaches new sessions without a broker restart;
running sessions keep their launcher.  Changes to the broker or supervisor still
need one.  So do changes to `contained-agent ssh-service`, which stays running
for the broker's lifetime, and new launchers must keep working with it until
then.  The trial bundle above keeps its own store launcher.

Switch only the two provider commands after successful version probes:

```sh
"$paseo_bundle/bin/paseo-broker" configure \
  --client-directory "$paseo_bundle/libexec/paseo-broker"
```

This reads existing \~/.paseo/config.json, probes both clients, writes a private
backup beside the file, preserves other provider/settings fields and replaces
the configuration atomically.  Managed symlink configs are refused.  It prints
the backup path.  No daemon restart is hidden in this command.

After allowing current sessions to finish, restart Paseo and create a new agent:

```sh
paseo daemon restart
"$paseo_bundle/bin/paseo-broker" status
```

Check a small prompt, interrupt a turn and continue, then close the session and
check its execution disappears.  Closing the app with daemon retained should
not remove it.  Provider sessions can remain idle between turns: idle does not
mean their process should have exited.  The restart can end the current agent,
so execute it only after this implementation conversation has finished.

Restore only provider command fields from the printed backup if needed:

```sh
"$paseo_bundle/bin/paseo-broker" configure --restore /path/to/printed/backup
paseo daemon restart
herd stop paseo-broker
```

Validated on 2026-10-09: Guix builds of native supervisor and bundle; ten
integration tests (streams, probes, numeric/signal results, detached child
cleanup, client/parent/broker death, restart, replacement barrier, config
backup/restore, status and malformed request); isolated Shepherd load/start/
status/stop using the exact trial file.  Real contained-agent version probes
returned Codex 0.155.0 and Claude Code 2.1.287.  Real Codex app-server initialize
and stdin-EOF exit passed through the full broker/Guix path with temporary
state and no credentials.  Codex warns about PATH helper creation with a
temporary CODEX_HOME; this test warning did not prevent the handshake.
Authenticated model turns and the actual lappie Paseo UI remain host-side tests.

### SSH passphrase prompts during broker startup

The broker preserves its own `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE`, `DISPLAY`,
`WAYLAND_DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` for the host-side launcher.  These are not accepted
from provider clients; in particular, a client cannot select an executable to
run on the host through `SSH_ASKPASS`.  The inner Guix container still applies
the separate contained-agent environment policy.

The broker must itself inherit working desktop/askpass settings.  Retaining
variables cannot recover settings missing from the service environment.
System boot services need explicit graphical/askpass environment configuration.
Version probes do not exercise encrypted SSH keys.  The regression test
`paseo-broker-askpass.py` unlocks a disposable encrypted key without a terminal,
using a fake askpass helper; it does not validate the user's graphical session.

Do not restart a live broker just to refresh these settings: stopping it ends
its active executions.  Wait for its executions to finish first.  A newly built
broker can then be run in the foreground from a desktop terminal to inherit
that terminal's environment, without restarting Paseo or changing provider
commands.  Existing clients use the same socket protocol.

### Broker sandbox policy (execution environment)

Provider clients forward only credential and terminal variables; the broker
contributes desktop/askpass settings from its own service environment. The
operator names further broker-environment variables for executions in
`~/.config/paseo/broker-sandbox.json`. Unlike the daemon's Guile-read
`sandbox.scm`, the broker policy is JSON, parsed by the broker itself:

```json
{"preserve": ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "CORP_.*"]}
```

`--policy` on the server selects another path. A missing file selects
nothing. The file must be a regular file owned by the broker user and not
writable by others; symlinks are refused. On boot services the preserved
values come from the service `environment` field; desktop Home services
inherit the session environment. Each preserve entry is a full-match
regexp against broker environment variable names; values are copied from
the broker's own environment at each start, never taken from provider clients.
The policy is read per start, so edits apply to new executions without a
broker restart. A malformed policy fails new starts with the diagnostic;
running executions and the broker itself continue. Status reports the policy
path, pattern count and last error.

A client-forwarded value still takes precedence when a name is also in the
client forwarding allowlist: `preserve` covers variables outside that
allowlist; it never overrides the credential channel. The contained-agent
launcher applies its own `preserve` policy afterwards, so a variable must be
kept there too (the common spec, the project central policy or a repo-local
`contained-agent.scm`) to reach the provider.

### Shared project SSH agents

The bundle enables `--shared-ssh`.  Before a project execution starts, the
broker asks a long-lived `contained-agent ssh-service` to prepare its SSH keys.
That service has its own supervised PID namespace, separate from every session:

```text
broker
  +-- supervisor -- SSH service -- per-project ssh-agent processes
  +-- supervisor -- session A -- Guix -- provider
  +-- supervisor -- session B -- Guix -- provider
```

The shared service reads central project policy, resolves linked worktrees to
the main repository, and serializes preparation requests.  Unchanged policy
reuses loaded keys; policy or known_hosts changes reload them with the existing
destination restrictions.  Session launchers check the prepared policy and
mount only their project's socket and snapshots.  They never interpret PIDs
from the shared service's namespace or start another SSH agent there.

Version and `auth status` probes skip SSH preparation.  A session exiting does
not clear shared keys.  Broker shutdown or death tears down the shared namespace
as well as its sessions; the next broker lifetime requires unlocking again.
The shared runtime tree is private and separate from direct terminal use, so
host `contained-agent ssh-start` does not preload this broker's cache.

To explicitly reload a project's shared keys and host-key snapshot, run on
the host (the project defaults to the current directory):

```sh
paseo-broker ssh-refresh ~/src/uraj
```

The broker uses its host askpass dialog and serializes refreshes with session
SSH preparation. This forces a reload even when policy and known_hosts have
not changed. A successful refresh preserves the socket and snapshot file
inodes, so existing sessions see the update without being restarted. New SSH
authentication may briefly fail while keys are being replaced; established
SSH connections remain alive. If unlocking fails, the command reports failure
and the project agent is stopped. Retry the command, then reopen affected
sessions because the replacement agent has a new socket inode.

Deploy the updated broker and contained-agent launcher together. An already
running older broker does not support this command; installing it requires a
broker restart when its sessions can be interrupted.

Status reports `ssh_preparation` as `not-started`, `unlocking`, or `ready`.
The broker remains responsive while askpass waits.  Canceling a waiting session
prevents that session from launching; an already-open shared unlock prompt may
finish and populate the cache for other sessions.  Cancel the dialog to reject
the unlock.  A rejected unlock fails that request without stopping the service.
The service's stderr goes to the broker log/terminal, never provider stdout.

Regression coverage in `paseo-broker-shared-ssh.py` uses real encrypted test
keys, SSH agents, and PID namespaces, with a fake askpass and Guix-shell probe.
It checks concurrent and later reuse, worktrees, separate projects, policy
reload, failed unlock/retry, cancellation, and broker death/restart cleanup.
It neither reads user credentials nor starts the user's Paseo installation.

The design/history sections below include future hardening and alternatives;
the implemented trial is narrower, notably no cgroup requirement, PTY support,
cross-UID peer authorization or hardened hostile path-race handling.

## Execution tiers

Provider clients now send `tier: daily|system|host` separately from
`provider: claude|codex|pi|opencode`. Missing tier means daily for old clients;
other values are rejected. `opencode` accepts only `host`: Paseo shares one
OpenCode server across workspaces, started in `~/.paseo/opencode-home`. That
directory is authorized as its cwd in addition to the usual roots; its client
ignores `PASEO_AGENT_CWD` and its executions skip branch GC. The broker status includes each execution's tier. Provider/agent
identity serializes replacements across tiers rather than allowing two copies
of the same agent to overlap.

Daily and system use the same contained-agent launcher, shared SSH preparation
and namespace supervisor. System is a named placeholder for future policy;
it currently adds no permissions. Existing project grants, including uraj's
Guix daemon and system log access, still apply to both.

Host requires a server-configured absolute `--host-codex`, `--host-claude`,
`--host-pi` or `--host-opencode` binary. Guix supplies package paths, never PATH-resolved terminal overrides.
It skips contained-agent and shared SSH preparation, retaining the broker's
host user/mount/PID namespaces and normal HOME-backed agent settings. It still
uses the broker's environment filtering and authorized cwd roots. It does not
acquire root or supplementary groups absent from the broker service, and it
does not turn off the agent's own sandbox/approvals.

The supervisor's `--host` mode uses a private cgroup v2 per execution.
`--host-cgroup-root` selects the writable delegated directory (default
`/sys/fs/cgroup`); its per-user, per-runtime subtree does not enable controllers
or set resource limits. Missing delegation or `cgroup.kill` rejects host launch.
The system broker waits for `cgroups2-fs-owner` and receives the `cgroup` group;
the Paseo daemon's supplementary groups remain unchanged. Apply the updated
system service configuration before deploying the broker on a boot-managed host.
Home/trial brokers require the same delegation through their login groups.

The broker records the cgroup before creation. The host guardian migrates a
trusted gated child before releasing it to exec the provider. The guardian
stays outside the group, acts as a subreaper, and monitors the outer supervisor
with a pidfd instead of dying with it. Agent exit triggers recursive
`cgroup.kill`; cancellation or owner death first gives the leader's process
group up to two seconds for graceful shutdown. Detached descendants are covered
by the final kill, including double forks and `setsid`. Completion waits for
`populated=0` and child reaping, preserving the provider's exit/signal status.
The `namespace.stat` identity names this guardian, not a new PID namespace.

If the guardian is killed, the surviving broker performs cgroup cleanup after
its outer supervisor exits. If both broker and guardian die, cleanup happens
on broker restart, before admission; no independent always-on system guardian
is installed. Until restart, descendants can remain in that simultaneous
failure case. Cleanup that cannot finish retains execution records and blocks
replacement (or startup during reconciliation). Status includes the execution's
cgroup path and cleanup-failure flag. Empty nested groups are removed after
recursive cleanup. The empty per-runtime parent remains for reuse.

This is lifecycle cleanup for cooperating same-user host programs, not a
security boundary: an unsandboxed provider with cgroup permissions can explicitly
migrate out. Work delegated to unrelated services is outside this execution's
cgroup. Kernel-stuck tasks can prevent teardown even after SIGKILL.

These labels select execution environments, not independently authenticated
roles. The same trusted daemon can request all configured tiers. Daily agents
must still not receive access to the broker socket. Wrapper placement alone is
not an authorization boundary; further separation of system operations needs
its own policy design.

`paseo-AGENT-{daily,system,host}` clients live in the Home and daemon profiles,
not in agent containers. Legacy `paseo-AGENT` clients still select daily.
The configure/restore trial command continues managing only legacy command
fields; Guix activation manages the labeled provider entries and overrides.
