# 重启后的恢复和存储

After reboot, the next session recreates the service, socket and cgroup using
the persistent storage; cached images remain available.  It does not resume
old tasks automatically.  Old task metadata may remain and cause name conflicts.
An interrupted startup is retried on the next attachment when no session holds
a lease.  There is no automatic storage purge; unused policy versions retain
their own caches.  The host service and each inner engine use native rootless
overlay storage; the inner graphroot is a host bind mount, so no overlay is
stacked on another.  Startup fails unless the inner engine reports the
selected driver.  `--storage-driver=vfs` selects VFS for the inner engine; the
driver is part of the runtime identity, so switching selects separate storage.
All runtimes share the host service's copy of the pinned runtime image.  Inner
storage is shared only by clients of the same runtime, not by other runtimes
or the user's ordinary host Podman.  No shared read-only image library is
used.
