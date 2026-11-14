# guix

System/Home 骨架、主机配置、部署和主机上的基础服务。

## 用法手册

- [deploy-guide](guix/deploy-guide.md)：部署命令速查（storie、hypie、本机 System 和 Home）、首次启用和回滚。
- [home-only-deploy-guide](guix/home-only-deploy-guide.md)：Home-only 部署。
- [runtime-modules-guide](guix/runtime-modules-guide.md)：gexp 里使用 uraj 模块的约定。
- [logs-guide](guix/logs-guide.md)：rsyslog、按服务的日志目录和读取权限。
- [crate-mirrors-guide](guix/crate-mirrors-guide.md)：crates 下载镜像。
- [iso-substitutes-guide](guix/iso-substitutes-guide.md)：Live ISO 使用内网 substitutes。
- [storie-network-guide](guix/storie-network-guide.md)：storie 的 host macvlan 和 NFS 共享。
- [immich-guide](guix/immich-guide.md)：storie 上的 Immich。
- [strongswan-guide](guix/strongswan-guide.md)：strongSwan VPN（lappie 手动启动，hypie 开机连接）。

## 过程文档

- [known-problems-debug-20261004](guix/known-problems-debug-20261004.md)：2026-10-04 对 Guix System 已知问题（以 lappie 为主）的排查记录，此后未复核。

## 历史项目

- [260921-storie-server](archive/projects/260921-storie-server/README.md)：storie 上线、Immich、首次 `guix deploy`。
- [261003-strongswan-vpn](archive/projects/261003-strongswan-vpn/README.md)：strongSwan 的 fwd2home 和开机连接。
- [261007-hypie-onboard](archive/projects/261007-hypie-onboard/README.md)：hypie 的 ZFS、NVIDIA 和部署。
- [261021-nfs-lan-shares](archive/projects/261021-nfs-lan-shares/README.md)：NFS 共享和客户端自动挂载。
