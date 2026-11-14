# 日常任务在 hypie 上的实测

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

The operator also reported a successful manual test on hypie on 2026-10-20,
using the built command without system reconfiguration.
