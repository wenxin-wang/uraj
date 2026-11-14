# 游戏资源下载的 fsync 问题

The game's resource download calls fsync after every 8 KiB write.  On
storie's Btrfs each takes 5–17 ms, capping the download at 1–4 MB/s with
11–20 times write amplification; without it the download reached about
20 MB/s, limited by CPU.  The game's anti-cheat exits once it is traced, so
strace fault injection is out; Docker ignores seccomp profiles for this
`--privileged` container; and `wrap.<package>` with LD_PRELOAD bypasses
Houdini, so the ARM libraries fail to load.  `hack-fsync` instead preloads
a libc-free shim into zygote, from which every app forks: a wrapper
bind-mounted over `/system/bin/app_process64` sets `LD_PRELOAD`, then
zygote restarts.  This also closes the game.  `install` and `upgrade` turn
it on for the installation unless it already is.
