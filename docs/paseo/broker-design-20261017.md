# Paseo broker design: host execution and container cleanup

> 旧文档：只读，不再更新。现状见 [broker-guide.md](broker-guide.md)。

## Status and scope

The broker is integrated with the boot service described in
[Paseo application container and boot service](daemon-guide.md). Guix System starts it as
the daemon's host user; the daemon itself runs in a Guix application container.
Foreign Guix Home uses user Shepherd. This extends
[contained-agent](../contained-agent/overview-guide.md) without replacing its mount, state-overlay, Git protection
or approved-manifest implementation. Existing direct terminal use stays as is.
The deployment still needs the host-side cutover described in that document.

Paseo still owns conversations, provider protocols and session restoration.
The broker owns execution lifetime and cleanup, not conversation history.
Python's standard library is the proposed control-protocol implementation;
reuse the existing Guile launcher rather than duplicate its sandbox policy.
The native C helper implements the Linux lifecycle boundary.
The preferred first implementation uses a trusted outer namespace init with
PDEATHSIG and a pidfd startup check. Host executions use cgroups as described
in the tier section below.
For sandboxed executions, keep cgroups as an alternative and possible
future resource-control facility, not a prerequisite for the first broker.

Paseo receives \~/src, \~/Projects and its worktree root
\~/.local/share/paseo/worktrees at their host absolute paths, plus its
own state.  New projects below these roots need no remount.  Adding another
root requires updating the Paseo container.  Extra agent-only mounts are
resolved on the host for each execution and need no Paseo restart.

## Observed Paseo contract

Source inspection targets the repository's packaged Paseo v0.10.3, not an
assertion about every running installation or provider.  Relevant upstream files:

- [Desktop quit lifecycle](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/desktop/src/daemon/quit-lifecycle.ts): keepRunningAfterQuit can leave the daemon running.
- [Daemon bootstrap/stop](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/server/src/server/bootstrap.ts): normal shutdown calls closeAllAgents.
- [Claude provider](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/server/src/server/agent/providers/claude/agent.ts) and [Codex transport](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/server/src/server/agent/providers/codex/app-server-transport.ts): closing a session terminates provider processes;
  normal turn interruption is a provider-protocol operation.
- [Agent manager](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/server/src/server/agent/agent-manager.ts): passes PASEO_AGENT_ID and PASEO_AGENT_CWD.
- [Provider command configuration](https://github.com/getpaseo/paseo/blob/v0.10.3/packages/server/src/server/agent/provider-launch-config.ts): supports replacing the launch command.

Claude and Codex use pipes here, not interactive PTYs.  Restoring their
conversation starts a provider runtime using persisted session/thread identity;
it is not a promise to reattach to the same surviving OS process.

| Event | Required broker behavior |
|---|---|
| App disconnects; daemon remains alive | Leave execution running |
| User interrupts a turn | Pass provider protocol unchanged; do not destroy the container |
| Provider exits normally or fails | Save result, clean all remaining execution processes |
| Paseo closes/reloads/archives a session | Terminate that execution and clean descendants |
| Client receives TERM/INT/HUP | Request termination; await cleanup within a bounded deadline |
| Client is killed, or control socket closes | Terminate execution even without a final message |
| Daemon dies but its client survives | Client detects parent death and closes the execution |
| Paseo container stops | Client disappears; host cleans its execution |
| Broker stops or crashes | Parent-death link tears down each outer execution namespace |
| Broker restarts | Reconcile execution records and cleanup before replacements |

Daemon-crash cleanup is an explicit fail-closed policy, not a claim that
upstream gracefully handles SIGKILL.  Do not automatically restart a provider
or replay a prompt.  Paseo remains responsible for conversation recovery.

## Launch and transport

```text
Paseo app -> Paseo daemon (container)
                 -> codex / claude broker client
                      == Unix control socket + SCM_RIGHTS ==>
                 host broker -> trusted outer namespace init
                                  -> contained-agent -> Guix container -> provider
```

Install a separate client entry point named codex and claude in the Paseo
container and configure each provider command to that single executable.
Do not depend on a prefix such as ["agent-client", "codex"]: the existing
contained-agent investigation found version probes that use COMMAND[0] only.
Support version, authentication and catalog probes without an agent ID/cwd;
these use a minimal no-project policy and have normal execution ownership.

The client sends a bounded, versioned start request containing provider, argv,
requested cwd, optional agent ID and an allowlisted environment.  It transfers
exactly stdin/stdout/stderr using SCM_RIGHTS.  The broker closes its duplicate
stdio descriptors after handing them to the owned launcher.  Only the control
socket remains in the client/broker; it must be close-on-exec and absent from
agent and helper children.  Output flows directly through the original pipes.
Diagnostics never go to protocol stdout.

Control messages: start, started(execution-id), terminate, exited(code/signal),
and error.  Termination is idempotent.  An execution ID is generated by the
broker, never reused, and is distinct from Paseo's optional agent ID.  One
connection owns one execution; disconnect is a cancellation, not detachment.
No reconnect, output replay, terminal emulation or arbitrary host exec API in v1.

The client must monitor its daemon parent as well as the control socket.
Use a verified Linux parent-death/pidfd mechanism with the startup race handled;
do not depend solely on stdin EOF (it may close intentionally, or remain held
by another process).  A client orphaned by daemon SIGKILL must not keep its
control connection and agent alive forever.  The exact helper and namespace
behavior are implementation prerequisites to test, not assumptions.

On normal completion, exited is sent only after cleanup is confirmed, and the
client reproduces the provider exit code or terminating signal where possible.
A transport or cleanup failure produces a distinct nonzero infrastructure
failure, never a synthetic provider success.  A client killed by Paseo cannot
wait for this acknowledgement; the host supervisor must still finish cleanup.
Serialize replacement launches for the same authenticated owner/agent ID behind
the previous execution's cleanup barrier, including when Paseo observed only
the client's early death.  Do not globally serialize unrelated agents.  Verify
auxiliary calls using the same ID separately so probes cannot accidentally
terminate or masquerade as the main session.

## Host policy and integration

- Authenticate socket peers with permissions and kernel peer credentials;
  explicitly account for Paseo's user-namespace UID mapping.  Mount the socket
  directory only into Paseo, never into an agent.  Neither agent ID nor cwd is
  an authorization credential.
- Permit only installed Claude/Codex entry points.  Forward argv as data to
  those programs inside the container; never interpolate a host shell command
  or accept Guix flags, executable paths or mount lists from the client.
- Resolve cwd against host-authorized roots.  Canonicalization alone leaves
  symlink/rename races: mount-source resolution must resist concurrent mutation
  or fail closed.  Include this in validation before granting sensitive mounts.
- Read the installed host policy for each start and record its version.  Keep
  existing approved-copy manifest semantics; the broker does not grant approval
  or evaluate unapproved project code.  A changed installed configuration affects
  new executions, not existing mounts.  Home-managed policy still needs a Home
  reconfigure to install changes, but not a broker/Paseo process restart.
- Add an explicit validated workdir input to the host launcher integration.
  Do not depend on its current "$HOME cwd means trust PASEO_AGENT_CWD" heuristic.
  Codex receives project cwd via context/RPC, not necessarily its process cwd.
- Construct the host launch environment from trusted defaults.  Do not accept
  client CONTAINED_AGENT_PROJECTS, GUILE_LOAD_PATH, PATH or loader settings as
  host configuration.  Preserve only approved provider values into the sandbox.
  Extra host variables are named by the operator in the broker sandbox policy,
  never accepted from clients.
- Preserve the current state/overlay and Git rules.  Network isolation and
  access to injected Paseo tools remain separate work: today's launcher uses
  host networking.  Adding a broker does not fix that exposure.

## Cleanup boundary: invariant and alternative cgroup implementation

Reliable cleanup is mandatory.  The parent-death/PID-namespace implementation
below is now preferred after primitive-level testing.  This section retains
the alternative cgroup design and its provisioning requirements for comparison;
it is not a requirement to deploy an extra cgroup guardian in the first broker.

Paseo's tree-kill only sees the local client after this split.  It cannot clean
the host execution tree.  Existing notes also report that SIGTERM to the outer
Guix process alone is insufficient.  Process groups and --die-with-parent are
useful secondary measures, not the ownership boundary: descendants can detach.

Require a private cgroup v2 subtree with cgroup.kill support.  Each execution
gets a child cgroup covering the launcher, Guix setup and all container
descendants, including double-forked or setsid children.  Agent containers must
not receive writable cgroup controls or another route to migrate out.
[Linux cgroup v2 documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html) specifies recursive cgroup.kill and the
populated field of cgroup.events; these provide the final kill and emptiness
checks.  Process names and stale numeric PID files are not cleanup authority.

This needs deliberate host provisioning on Guix.  A Home service does not
automatically get cgroup delegation.  A narrowly scoped system service must
provision ownership/cleanup, or a trusted system guardian must manage the
subtree.  Never run manifests or providers as root to solve this.  On either
machine, absent delegation/guardian support must reject launch, with no silent
fallback to kill-the-wrapper.  Deployment details remain to be implemented.
Guix daemon build workers are owned by the Guix daemon, not this execution
cgroup.  Closing the client connection may not immediately stop shared build
work; do not kill system-wide build workers as if they were leaked agents.

Launch sequence:

1. Guardian allocates and records an execution cgroup before code can execute.
2. Place a gated trusted child in that cgroup before releasing it to exec the
   launcher.  Do not spawn Guix and migrate it afterwards: it could already fork.
3. Record ownership and arm broker-death cleanup, then release the launch gate.
   Cancellation at any intermediate step follows the same cleanup path.
4. Report started as launcher ownership established, not provider-protocol
   readiness.  Paseo's own initialization handshake establishes readiness.

Cleanup state machine:

```text
allocated -> starting -> running -> stopping -> empty -> reported/released
                                  | timeout/error
                                  -> force-kill -> empty
                                               -> cleanup-failed (visible)
```

On stop, allow a short bounded graceful interval (initial target: two seconds),
then invoke cgroup.kill for remaining processes.  Normal leader exit also
triggers descendant cleanup.  Confirm populated=0, reap owned children, remove
the empty cgroup and release execution resources before reporting completion.
Use subreaper/wait handling where appropriate; cgroup emptiness alone does not
reap zombie children.  Preserve the leader's result separately from cleanup
status.  PID-directed graceful signals require stable handles, not unchecked
reused PID numbers.

The guardian lives outside execution cgroups and independently of the broker's
failure domain.  Its broker-liveness channel must not leak into children.
Broker EOF/death causes cleanup even if the broker cannot run finally blocks.
An outer Shepherd service must also clean the dedicated subtree when the
guardian fails or the service stops, and on startup before opening admission.
Simply setting respawn? on the broker is insufficient.  If the entire supervisor
is unavailable, immediate cleanup cannot be guaranteed; startup reconciliation
must still recover the subtree rather than forget it.

Startup reconciliation enumerates the exclusively owned subtree, including
cgroups whose metadata write was interrupted; it kills stale executions rather
than trying to reconnect them.  Enforce single ownership so two broker instances
cannot clean each other's live work.  Do not adopt arbitrary PID-file processes.

SIGKILL cannot promise a hard exit deadline for a kernel-stuck task.  After the
cleanup deadline, retain the execution as cleanup-failed, expose the cgroup and
reason, and block replacement for that execution/agent.  Failed reconciliation
blocks new service admission.  Never delete the record and report success while
processes remain.  Log metadata and lifecycle transitions, not raw argv, prompts
or credentials; expose status including cgroup population and cleanup failures.

### What cgroups add in concrete cases

A cgroup is persistent kernel membership, inherited by new children, rather
than a snapshot of parent/child PIDs.  Reparenting, setsid and a double fork do
not themselves change it.  Membership is only useful as a cleanup boundary if
the workload cannot migrate out.  Killing the broker does not automatically
kill its cgroups: a surviving supervisor must invoke cleanup.

- Agent starts an MCP server and a detached test server: both stay in its
  execution cgroup and are included in final cleanup, even after the agent
  exits.  Guix PID-namespace teardown already covers these **inside** the container.
- Cancellation during profile preparation, before there is a container PID 1:
  the cgroup already owns the launcher and its local helpers.  There is no need
  to wait for the PID namespace to exist.  Guix daemon workers remain outside
  this scope, as explained above.
- Paseo tree-kills the client or escalates straight to SIGKILL: broker socket
  EOF initiates cleanup of the host cgroup without needing a client handler.
- Broker crashes after creating descendants: the guardian can enumerate the
  reserved execution subtree without reconstructing vanished parentage.  It
  can clean even a group whose metadata transaction was interrupted.
- Old execution exits while a descendant still holds files/pipes: populated
  and child-reaping checks prevent admitting the replacement prematurely.

Optional future controllers can cap memory, CPU bandwidth and process/thread
count per execution.  These need explicit limits and controller delegation;
creating a cgroup alone imposes none.  Cgroups do not provide file or network
access isolation, undo writes, or automatically remove temporary directories.

### Parent-death signal: preferred implementation direction

PR_SET_PDEATHSIG with SIGKILL can link the broker's lifetime to a trusted
execution supervisor.  Combine that with an outer PID namespace containing
the entire contained-agent/Guix launch, not merely the final provider:

```text
broker
  -> trusted namespace init (parent-death SIGKILL armed)
       -> contained-agent -> guix preparation -> inner container -> provider
```

Broker death then kills the outer namespace init, and the kernel tears down
its namespace descendants.  Keep init as a trusted reaper/supervisor rather
than exec the provider as PID 1; normal completion preserves the provider's
result, and normal cancellation can attempt a bounded graceful stop before
namespace teardown.  This is a candidate to replace the separate cgroup
guardian for process cleanup, pending tests.

The startup race is real: parent death before prctl does not generate a
retroactive signal.  Before spawning, obtain a stable pidfd for the intended
parent and pass it to the child.  After namespace/credential setup, arm
PDEATHSIG, then check that pidfd for parent exit before releasing any workload.
Parent death before arming is caught by the check; death afterwards is caught
by the signal.  Check all syscall errors and fail closed.  A simple getppid
comparison is not sufficient across PID namespaces: a child whose parent is
outside its namespace sees getppid()==0 even while the parent is alive.

Each actual fork/clone child must arm its own parent-death signal; the setting
is not inherited by fork.  Credential changes and privileged exec can clear
it.  Any intermediate launcher must have its own verified lifetime link, and
the parent thread creating children must remain alive: PDEATHSIG tracks that
thread, not just the last thread of the parent process.  A native helper can
keep these operations explicit rather than relying on Python preexec_fn.

util-linux unshare --kill-child already implements a related child-death link;
the inspected upstream implementation uses PDEATHSIG plus a parent pidfd check.
It only links unshare to its child, not the broker to unshare, so composing it
still requires a verified outer link.  It is reference material, not evidence
that an untested shell command handles all our races.

References: [PR_SET_PDEATHSIG](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html),
[PID namespaces](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html), and
[util-linux unshare source](https://github.com/util-linux/util-linux/blob/master/sys-utils/unshare.c).
The following experiment covers the deliberately paused startup race and
broker death after workload readiness.  Full broker integration is still untested.
