# Acceptance before enabling the broker

> 旧文档：只读，不再更新。验收已完成，broker 已长期使用；现状见 [broker-guide.md](broker-guide.md)。

## Acceptance before enabling the broker

Use fake providers and temporary state first; then real Paseo/provider smoke
tests.  Successful dialogue alone is not acceptance.  For every termination
case assert that the execution cgroup becomes empty (or the selected namespace
boundary is completely torn down), owned children are reaped,
stdio closes, and no execution resources remain.  Exercise both machines.

| Test | Required observation |
|---|---|
| Version/auth/catalog without project | Correct protocol/result, no unintended project mount |
| Streaming, stderr and output backpressure | Byte-preserving pipes, no control/log data on stdout |
| Exit 0, nonzero and signal | Correct result after descendant cleanup |
| App quit with daemon retained | Agent continues; no cleanup triggered |
| Turn interrupt then next turn | Same usable session; container not destroyed |
| Close, archive, reload, daemon stop | Old execution fully cleaned; replacement does not overlap writers |
| Kill client with SIGKILL | Disconnect cleanup works without client signal handler |
| Kill daemon with SIGKILL | Orphan client detects death; host execution is cleaned |
| Stop/restart Paseo container | Host executions cleaned despite PID namespace separation |
| Provider ignores TERM; forks/setsid | Escalation clears all descendants, including concurrent forks |
| Leader exits leaving background children | Result is not reported until descendants are cleared |
| Cancel during each launch stage | No unowned launch or half-created execution |
| Kill broker during launch/run/cleanup | Parent-death teardown works; restart reconciles before admission |
| Kill namespace init; stop host service | Namespace teardown and replacement barrier work |
| Artificial cleanup failure | Visible failure, no false success or unsafe replacement |
| Repeated create/close/reload cycles | No growth in processes, cgroups, file descriptors or temp resources |

Also test broker failure while the client is blocked on I/O, client-parent death
before monitoring is armed, leaked-FD prevention, malformed/oversized requests,
unauthorized peers, cwd symlink races, and attempts to override host policy.

The design can match Paseo's normal exit semantics, but that is not yet a
verified property of an implementation.  Provisioning the selected ownership
boundary, crash cleanup and the tests above are release requirements, not later
reliability enhancements.
