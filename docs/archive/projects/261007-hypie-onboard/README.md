# hypie 上线

已完成的历史项目，按 `git log` 重建；时间线以提交日期为准，没有提交可查的事实
写“未确认”。hypie 上的 redroid 和 MAA 见 [maa 索引](../../../maa.md)。

## 目标

把 hypie（GTX 1080）配成 Guix System：ZFS 数据池、NVIDIA 驱动、
开机连 VPN、Paseo，并能从开发机 `guix deploy`。现状见
[deploy-guide](../../../guix/deploy-guide.md)。

## 背景

- hypie 此前跑 Arch；装 Guix 后 Arch 仍留在另一块盘的 legacy 启动项里
  （`env/guix/os/hypie.scm` 的安装注释）。
- 部署方式沿用 [260921-storie-server](../260921-storie-server/README.md) 的
  `guix-deploy` 用户。

## 主要决定

- 10/07：hypie 的系统配置、ZFS、NVIDIA、SOPS 的 age 公钥和 VPN 密文（4c6dce8）；
  hypie 信任 storie 的签名公钥。
- 10/10：`env/guix/os/deploy/hypie.scm`（7334ffb）。`authorize? #f`：首次部署由 hypie
  自己协调，使用自己的 daemon 和 store；换别的机器部署前，hypie 要先信任它。
- 10/14：不再用 `nonguix-transformation-nvidia` 嫁接整个系统（`guix deploy` 评估时
  OOM，约 19GB），直接用 `nvidia-service-type`（88254a4）。
- 10/15：hypie 通过 Avahi 发现局域网内的 substitute 服务器（c428e7a，#16）。
- 10/21：hypie 按需挂载 storie 的 NFS（见
  [261021-nfs-lan-shares](../261021-nfs-lan-shares/README.md)）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
