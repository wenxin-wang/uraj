# Codex 首次启动的 backfill

On first startup, Codex indexes the shared active and archived rollouts into
the contained database before showing the trust screen.  Let this finish.  An
interrupted worker holds its backfill lease for 15 minutes, while a new process
waits only 30 seconds.  During that interval startup may report that the
database appears damaged.  After the worker has stopped and the lease expires,
start one instance and let it complete the import.  Do not delete the database
or mark an unfinished import complete.  The `~/.codex` path in the diagnostic
names the rollout source; the database remains in `contained-sqlite/`.
