# Guix 的 crates 下载镜像

## Guix 的 crates 下载镜像

共享 `base-services` 为 Guix daemon 设置
`GUIX=/etc/guix-daemon-command`。该程序只包装 `perform-download`，
将 crates.io API 和 static.crates.io 的 crate 地址展开为
`rsproxy → SJTUG → 原站`；其他命令原样交给系统配置选定的 Guix。
实现位于 `(uraj services guix-mirrors)` 和 `(uraj build crate-mirrors)`。

这是 daemon 端的策略：普通 `guix build`、`guix time-machine`、
`maak system-reconfigure` 都沿用原有命令。无需修改 channel、shikanox
包或 Cargo 配置。原始 derivation、预期哈希和 store 输出路径不变，
下载仍由 Guix 的 `url-fetch` 完成。

文件在系统 reconfigure 的激活阶段生成，不需要重启系统。
使用顶层路径以避免覆盖 Guix 自己维护的可变目录 `/etc/guix`。
若运行中的 daemon 仍使用旧服务定义，待现有构建结束后执行
`sudo herd restart guix-daemon` 即可。正在运行的旧 daemon 不会因仓库
文件改动自动启用镜像；首次 reconfigure 的构建阶段也仍使用旧 daemon。
镜像下载可在构建日志的 `From https://rsproxy.cn/...` 中确认。

覆盖范围是本机 daemon 的 `builtin:download`。远程 offload 的构建机
需独立配置；旧式自行调用下载程序的 builder、Cargo 自行联网不受此
包装影响。它使用 Guix 已有的 `GUIX` helper 入口和内部 `url-fetch`
绑定，升级系统 Guix 时需重跑测试；不需要维护 Guix fork。

```sh
guix time-machine -C env/guix/channels-lock.scm -- \
  repl -L src/guix test/guix/uraj/build/crate-mirrors.scm
```
