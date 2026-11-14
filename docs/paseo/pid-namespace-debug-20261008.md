# Investigation: Guix PID namespace versus cgroup

> 迁移自 `docs/paseo-broker.org` 的 “Investigation: Guix PID namespace versus cgroup (2026-10-08)”（2026-11-14，内容未改）。

## Investigation: Guix PID namespace versus cgroup (2026-10-08)

Source inspected: installed Guix 90d978cb9a60a3ea5bf676c9637ae2f718304a31,
plus installed 1.5.0-6.64d4de2.  In gnu/build/linux-container.scm both list a
cgroup namespace but leave "TODO: Initialize cgroups" in run-container.
CLONE_NEWCGROUP virtualizes the cgroup view; it does not allocate a separate
execution group.  See [cgroup_namespaces(7)](https://man7.org/linux/man-pages/man7/cgroup_namespaces.7.html).

guix shell uses call-with-container with child-is-pid1? #f.  An intermediate
PID 1 forwards selected signals and reaps children.  It exits when the main
child exits; the kernel then kills remaining namespace processes, including
detached descendants.  See [pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html).  setsid is not an escape from
this boundary either.

Controlled experiment used guix repl to call this actual Guix primitive with
namespaces '(user pid), child-is-pid1? #f and a process-spawned-hook capturing
PID 1's outer PID.  The Python payload forked a setsid/double-fork background
child ignoring TERM.  The driver was a subreaper and explicitly killed/reaped
all test children.  No real providers, credentials or project writes were used.

| Action | Observation |
|---|---|
| Main payload exits normally | PID 1 and detached background child also exit; wrapper code 0 |
| TERM directly to main payload | Entire namespace exits; wrapper code 143 |
| TERM to outer wrapper or namespace PID 1 | Did not finish within three seconds in this harness |
| Payload ignores TERM; then KILL to PID 1 | All namespace processes stop; wrapper code 137 |
| KILL outer Guix wrapper | PID 1, payload and background child remain alive |
| Subsequently KILL that namespace's PID 1 | All remaining test processes stop |

These are primitive-level tests, not a full guix shell/Paseo integration test.
Full guix shell was blocked by the current sandbox's denied Guix daemon socket;
the test did not mount a new root/proc or exercise bubblewrap.  The unexpected
TERM forwarding behavior needs investigation before choosing grace deadlines.
No cgroup creation/kill experiment was possible in this environment, where
/sys/fs/cgroup is not exposed.  Cgroup behavior above is based on kernel docs.

The source handshake closes after container setup, with no continuing
parent-death channel on this path.  call-with-container offers a
process-spawned-hook, but guix shell does not expose it in this launch path.
guix system container scripts do offer --pid-file; that is a different launcher.
The hook also runs after setup and release of the child, so it alone does not
close the startup ownership race.

A viable non-cgroup alternative therefore needs a trusted per-execution
supervisor holding a stable handle to namespace PID 1, a launch gate, and a
broker-death cleanup channel, plus ownership of all pre-container helpers.
Consider an outer PID namespace around the entire launcher/preparation phase:
its init could provide the wider cleanup boundary, without cgroup delegation.
That option needs tests for parent-death races, nested Guix user namespaces,
signal permissions, result forwarding and temp-directory cleanup.  A wrapper
that merely kills the outer Guix PID is demonstrably insufficient.

Decision remains provisional: compare this supervised outer-PID-namespace
approach with cgroup provisioning on both hosts.  The no-orphan acceptance
criteria remain mandatory regardless of which mechanism is selected.
