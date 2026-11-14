# Parent-death experiment results

## Parent-death experiment results (2026-10-09)

Reproducible harness:
[parent-death-namespace.py](../../../../test/python/uraj/guix/contained-agent/parent-death-namespace.py).
Run with Linux Python 3.9+, an installed Guix, user/PID/mount namespaces,
and pidfd support:

```sh
GUIX=/run/current-system/profile/bin/guix python3 \
  test/python/uraj/guix/contained-agent/parent-death-namespace.py --repeat 3
```

All eight cases passed in three consecutive cycles (24 cases), using installed
Guix 90d978cb9a60a3ea5bf676c9637ae2f718304a31 in this agent environment.
The single-threaded fake broker prepares a user namespace and creates a child
PID namespace.  Its trusted init arms PDEATHSIG=SIGKILL, then polls the original
broker's inherited pidfd before launching work.  The test driver is a subreaper
that outlives the fake broker, deliberately exercising reparenting as well.

| Case | Assertion/result |
|---|---|
| Broker killed before prctl | Original pidfd reports death; init exits without launching any work |
| Broker killed after arming | Init exits without launching work |
| Broker killed during preparation | Detached pre-container helper exits |
| Broker killed during nested Guix | Init, payload and detached inner/outer helpers all exit |
| Main exits 0 or 7 | Correct numeric result; background descendants cleaned |
| Main killed by SIGKILL | Guix's numeric result 137 preserved; descendants cleaned |
| Cancel with TERM-ignoring workload | Init's bounded grace expires; namespace teardown cleans descendants |

The nested workload calls Guix's real call-with-container with '(user pid)
and child-is-pid1? #f.  Both inner and pre-container background helpers double
fork, setsid, and ignore TERM.  Assertions use pidfds to check process exit;
the driver reaps **all** remaining children before returning from each case and
checks that its open descriptor count returns to baseline.  All test-owned
processes and temporary directories were cleaned.  No real agents were launched.

An initial nested attempt failed writing UID maps because /proc still described
the test driver's PID namespace.  Mounting a matching /proc inside the outer
execution namespace fixed it.  This is a deployment requirement for nested
Guix, not an optional cosmetic mount.  The harness keeps an additional old
proc mount solely for test observation; do not expose it in production agent
containers.  init sees getppid()==0, confirming why the pidfd check is necessary.

Limits and next integration work:

- This tests the kernel mechanism plus nested Guix's container primitive, not
  full guix shell, state overlays, manifests, socket/FD transport or real Paseo.
  It has not been run independently on both hosts.
- The mock broker changes its own namespaces for the experiment.  A real
  long-lived broker needs a native per-execution clone/setup path with parent
  UID/GID mapping and a launch gate; never change the shared broker namespaces.
  Audit any extra helper's lifetime link rather than assuming this prototype
  proves a differently shaped production process tree.
- The harness represents signaled Guix results numerically (SIGKILL -> 137).
  Exact signal-vs-exit-code fidelity needs explicit status transport/instrumentation
  in the real launcher; do not infer a signal from every 128+N exit code.
- Normal cancellation is a test supervisor with a 250 ms grace deadline.  Actual
  provider shutdown timing, output draining, reap/exit acknowledgement and the
  replacement-session barrier still need integration tests.
- Kernel process cleanup does not run Python/Guile finally blocks.  Temporary
  host directories, records and GC roots still need cleanup/reconciliation after
  crashes.  This prototype's driver cleans its own fixtures externally.
- Process/resource limits and cgroup accounting are outside this mechanism;
  add cgroups separately if those become requirements.

The result supports choosing a small trusted PID-namespace supervisor instead
of a separate cgroup guardian for initial process cleanup.  It does not claim
that the entire broker is implemented or ready to deploy.
