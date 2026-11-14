# MAA scheduled daily tasks

> 迁移自 `docs/maa.org` 的 “Scheduled daily tasks”（2026-11-14，内容未改）。

## Scheduled daily tasks

The installed hypie system includes `%maa-services` from
`src/guix/uraj/services/maa.scm`; the live installer does not. Reconfigure
hypie to activate it. mcron uses hypie's inherited `Asia/Shanghai` timezone
and runs at minute zero of each configured hour; missed runs are not replayed.

`env/maa/tasks/daily.toml` restores the previous daily configuration:
Official client login, 3/4-star recruitment (leave 5/6-star tags for manual
handling), preset base rotation and clues, friend visits and credit shopping,
rewards, depot recognition, then close the game. There is no `Fight` task
and `credit_fight` is false, so this round does not spend sanity. Base rotation uses the game's
existing preset queues; keep those configured in-game. Drones accelerate
Pure Gold production (`drones = "PureGold"`).

The dedicated `maa` system account keeps state under `/var/lib/maa`, with
ADB server port 5038 separate from interactive clients. A nonblocking lock
prevents overlapping runs, and a two-hour timeout bounds a stuck run.
Start the ADB server explicitly before MaaCore: in the first live test,
letting MaaCore spawn it left a communication pipe open in the background
server and delayed connection by a minute. Prestarting it connected in one
second. Both startup and MAA run inside the lock and timeout.
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
[MaaCore DepotInfo format](https://github.com/MaaAssistantArknights/MaaAssistantArknights/blob/v6.19.0/src/MaaCore/Task/Miscellaneous/DepotRecognitionTask.cpp);
recheck these when upgrading. Test locally with
`python3 test/maa/depot.py`. This persistence path has fixture-based tests.
The operator also reported a successful manual test on hypie on 2026-10-20,
using the built command without system reconfiguration.

maa-cli 0.7.5 also performs a mandatory API hot update before task parsing,
including during `--dry-run`; this needs outbound HTTPS. The optional
MaaResource Git update warns on failure, but an API update failure aborts
that run. See the [pinned CLI run implementation](https://github.com/MaaAssistantArknights/maa-cli/blob/v0.7.5/crates/maa-cli/src/run/mod.rs).

The scheduled command sets `SSL_CERT_DIR` to the `nss-certs` store
directory and clears `SSL_CERT_FILE`. This package contains individual
certificates, not `etc/ssl/certs/ca-certificates.crt`. The 2026-10-17
21:00 scheduled run pointed at that nonexistent bundle and aborted with
`No CA certificates were loaded from the system`. Interactive validation
does not validate the scheduler's certificate environment; after deploying
the fix, check the dedicated account's scheduled invocation as well.

Live validation on hypie on 2026-10-17, 16:20–16:25 Asia/Shanghai, used
the Guix store MAA/ADB binaries and this task/profile/CLI configuration
against production `10.203.0.2:5555` (game 2.7.81), with temporary writable
state and ADB port 5038. All six tasks reported `Completed`, followed by
`AllTasksCompleted` and exit status 0. One recruitment was started; base,
mall and rewards tasks completed, and the game was closed. No combat task
was configured. This validates the controller and saved game login; the
dedicated system account and scheduled invocation still await deployment.
An earlier attempt failed during the mandatory API update before entering
the game; the retry succeeded. MaaResource download is MAA recognition
data, not a reinstall or download of the game's data.
