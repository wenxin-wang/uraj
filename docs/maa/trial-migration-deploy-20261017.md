# MAA: move from the trials to production

> 旧文档：只读，不再更新。现状见 [redroid-guide.md](redroid-guide.md)。

> 迁移自 `docs/maa.org` 的 “Move from the trials to production”（2026-11-14，内容未改）。

## Move from the trials to production

The tested, logged-in instance at `.5` uses
`redroid-waydroid-houdini-test-data`. Before reconfiguring, copy that stopped
instance's complete data, including resources and account state, into the
new production directory. Never open the Android 11 directory with Android
13. On hypie:

```sh
sudo sh scripts/redroid/migrate-houdini-data
sudo herd stop redroid-maa
# Reconfigure/deploy hypie from this revision using the usual deployment tool.
sudo herd start redroid-maa
sudo docker exec redroid-maa getprop sys.boot_completed
sudo docker exec redroid-maa getprop uraj.houdini.linker.ready
```

The migration refuses an existing destination and retains the source volume
on any copy failure. The old Android 11 directory stays intact for rollback.
After confirming login on `10.203.0.2:5555` and restarting the production
service once to check the persistent namespace hook, retire the trials:

```sh
sudo sh scripts/redroid/retire-trials
```

This checks the migration marker, production data mount, boot completion,
Houdini selection and namespace readiness before stopping/removing the four
named trial containers and their named volumes (`.3` through `.6`). It never
uses `docker prune`, and keeps production and the old Android 11 data.
The local trial image tags are removed when no container references them;
shared base image caches remain. These host actions require Docker/root
access; they are not performed by reconfiguration itself.
