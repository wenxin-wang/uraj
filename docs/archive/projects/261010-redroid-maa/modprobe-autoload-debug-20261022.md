# Android 清空 modprobe 导致主机模块无法加载

The container is privileged, as in the upstream deployment recipe.  The
`modprobe` sysctl is global: Android's `init.rc` sets it to an empty string at
early-init, which disables module autoloading on the host too (upstream
[issue #932](https://github.com/remote-android/redroid-doc/issues/932)).  On hypie that broke the boot VPN: charon could not load `esp4`,
and failed with `Requested type not found (93)`.  The host's `fuse` module,
which Android needs, was never loaded either: vold aborted on the missing
`/sys/fs/fuse/connections`, and Android rebooted in a loop.  The service now
loads `fuse` at boot.
