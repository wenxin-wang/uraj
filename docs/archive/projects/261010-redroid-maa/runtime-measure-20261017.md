# MAA production recipe checks

## Production recipe checks, 2026-10-17

The Guix Houdini package, static BusyBox (including its upstream tests), and
Docker build context were built successfully. Both Houdini library hashes
match the earlier runtime-tested payload, and the Android helper retains its
`/system/bin/sh` interpreter. The static build helper was executed inside an
empty chroot on the test instance: it removed only the NDK fixtures, inserted
both startup hooks and removed its own temporary tools. The service suite
passed 42 checks. Run the helper/retirement checks with:

```sh
sh test/redroid/houdini-linker.sh
sh test/redroid/retire-trials.sh
```

Full Docker build of this Guix-produced recipe, migration, production restart
and retirement of the trial containers require the host deployment steps
in [trial-migration-deploy-20261017](trial-migration-deploy-20261017.md). They were not executed from the agent's restricted environment.
