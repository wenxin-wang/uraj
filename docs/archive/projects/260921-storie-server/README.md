# storie 上线

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

把 storie（J6412 小主机）从零配成家里的服务器：ZFS 数据盘、Immich、Paseo
relay 等容器服务，并能从开发机用 `guix deploy` 日常更新。现状见
[deploy-guide](../../../guix/deploy-guide.md)、
[immich-guide](../../../guix/immich-guide.md)、
[storie-network-guide](../../../guix/storie-network-guide.md)、
[iso-substitutes-guide](../../../guix/iso-substitutes-guide.md)。

## 背景

- storie 此前的 NFS 服务跑在一个容器里（`storie.scm` 的注释写 container 100、
  172.31.255.6）；迁移前的整体形态未确认。
- 构建放在 lappie，storie 信任 lappie 的签名公钥并从它取 substitutes。

## 主要决定

- 09/21：`env/guix/os/storie.scm` 骨架（73a071c）；09/29 拆出共享的
  `base`、`server`、`storage`、`zfs` 系统模块（91bb23c）；09/30 风扇控制（cc4992a）。
- 09/29：Live ISO 同时发布 substitutes（ea0a92a）；10/02 storie 信任 lappie 的
  签名公钥，首次启用时手工 `guix archive --authorize` 并显式指定发布端
  （bd2bec0，见 [trust-lappie-substitutes-deploy-20261002](trust-lappie-substitutes-deploy-20261002.md)）。
  现在由系统配置声明式信任，不再需要这一步。
- 10/02：Immich 以 Compose 形式由 Shepherd 管理，数据库密码用 SOPS（db94041）；
  首次部署的取舍见 [immich-first-deploy-20261002](immich-first-deploy-20261002.md)。
- 10/04：Paseo relay 容器（062e053）；`guix deploy` 入口、`guix-deploy` 用户和
  sudoers 白名单（1034115）；`build-locally? #t`，开发机构建，storie 只激活。
- 10/05：new-api、Paseo daemon 上 storie（d805fb9、9cdfaea）。
- 10/09：host macvlan，让宿主能访问 relay 所在的 macvlan（5af0b24，见
  [macvlan-switch-deploy-20261009](macvlan-switch-deploy-20261009.md)）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [immich-first-deploy-20261002](immich-first-deploy-20261002.md)：Immich 首次部署时的取舍。
- [trust-lappie-substitutes-deploy-20261002](trust-lappie-substitutes-deploy-20261002.md)：storie 首次信任 lappie 的 substitutes。
- [macvlan-switch-deploy-20261009](macvlan-switch-deploy-20261009.md)：切换到 host macvlan 的步骤。
