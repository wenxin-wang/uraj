# MAA scheduled daily tasks

The installed hypie and storie systems include `%maa-services` from
`src/guix/uraj/services/maa.scm`; the live installer does not. Reconfigure
the host to activate it. mcron uses the base system's `Asia/Shanghai`
timezone and runs at minute zero of each configured hour (02:00, 05:00,
11:00, 14:00 and 21:00); missed runs are not replayed.  Each run first tries
a TCP connection to the Android instance's ADB port and skips the run (exit
0) unless it connects within 5 s, so a host whose `redroid-maa` is stopped
does nothing; see the [storie standby](redroid-guide.md#storie-standby).

`env/maa/tasks/daily.toml` holds the daily configuration:
Official client login, 3/4-star recruitment (leave 5/6-star tags for manual
handling), preset base rotation and clues, friend visits and credit shopping,
rewards, depot recognition, then close the game. There is no `Fight` task
and `credit_fight` is false, so this round does not spend sanity. Base rotation uses the game's
existing preset queues; keep those configured in-game. Drones accelerate
Pure Gold production (`drones = "PureGold"`).

The dedicated `maa` system account keeps state under `/var/lib/maa`, with
ADB server port 5038 separate from interactive clients. A nonblocking lock
prevents overlapping runs, and a two-hour timeout bounds a stuck run.
Start the ADB server explicitly before MaaCore; if MaaCore spawns it, a
communication pipe stays open in the background server and delays the
connection by about a minute. Both startup and MAA run inside the lock and timeout.
The command's `PATH` includes both ADB and `bash-minimal`: MaaCore's
PosixIO invokes `sh -c` through `execlp`. An ADB-only `PATH` lets the
absolute-path server startup succeed but makes subsequent device commands
fail with `exec failed: No such file or directory`.
Configuration and the pinned MAA 6.21.1 package are immutable store files;
resource updates and logs go to the account's writable data/cache/state
directories. CLI logs are under `/var/lib/maa/state/maa/debug/`; scheduler
output is in `/var/log/mcron.log`. Inspect upcoming runs with
`sudo herd schedule mcron 8`.

Each successful daily run atomically replaces
`/var/lib/maa/state/maa/depot.json` (owned by `maa`, mode 0600).
It contains `updated_at` (UTC ISO 8601) and `items`, a mapping of MAA item
IDs to integer quantities. Recognition runs after rewards so it includes
this round's purchases and collections. This is the scope recognized by
MAA's Depot task (materials and supported basic currencies), not every
category in the game's inventory; missing IDs must not be treated as zero.
The snapshot replaces the previous mapping rather than merging old items.

`env/maa/run-daily.py` reads this invocation's CLI output and requires a
final `DepotInfo` callback, `Depot Completed` and a successful CLI exit.
Failed, interrupted or lock-skipped runs retain the last successful file
and its timestamp; before the first successful scan the file is absent.
The wrapper runs inside the existing lock and timeout. Its parser follows
the pinned [CLI callback output](https://github.com/MaaAssistantArknights/maa-cli/blob/v0.7.5/crates/maa-cli/src/run/callback/mod.rs) and
[MaaCore DepotInfo format](https://github.com/MaaAssistantArknights/MaaAssistantArknights/blob/v6.21.1/src/MaaCore/Task/Miscellaneous/DepotRecognitionTask.cpp);
recheck these when upgrading. Test locally with
`python3 test/maa/depot.py`.

maa-cli 0.7.5 also performs a mandatory API hot update before task parsing,
including during `--dry-run`; this needs outbound HTTPS. The optional
MaaResource Git update warns on failure, but an API update failure aborts
that run. See the [pinned CLI run implementation](https://github.com/MaaAssistantArknights/maa-cli/blob/v0.7.5/crates/maa-cli/src/run/mod.rs).

The scheduled command sets `SSL_CERT_DIR` to the `nss-certs` store
directory and clears `SSL_CERT_FILE`. This package contains individual
certificates, not `etc/ssl/certs/ca-certificates.crt`. Interactive
validation does not exercise the scheduler's certificate environment.
