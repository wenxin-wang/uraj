# Paseo daemon 进 Guix 容器

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

Paseo daemon 作为 Guix 容器里的服务在 lappie、hypie、storie 上运行，relay 自建在
storie 上，coding agent 不在 daemon 容器里跑。现状见
[daemon-guide](../../../paseo/daemon-guide.md) 和
[relay-guide](../../../paseo/relay-guide.md)。

## 背景

- Paseo 先以桌面应用的形式装在 lappie 上（10/04，c198420）。要在 storie 上常驻、
  手机通过私有 relay 连接，就要有一个不依赖登录的 daemon。
- daemon 能读写项目目录和凭据，所以放进容器限制它能看到的东西；agent 的隔离由
  contained-agent 负责，启动 agent 的部分归 [paseo-broker](../261008-paseo-broker/README.md)。

## 主要决定

- 10/04：relay 用官方 Dockerfile，固定到一个 commit，跑在 storie 的 `docker_lan`
  macvlan 上，地址 172.31.0.8:4000（062e053）。
- 10/05：storie 上的 daemon 先做成一个独立的 Guix 系统容器：自己的 macvlan 接口
  `paseo0`、固定地址 172.31.0.7、专用 `paseo` 账号（UID/GID 1100）和 `/data/paseo`
  下的家目录（9cdfaea）。
- 10/09：改成不带客户机系统、客户机 Shepherd 和独立 IP 的方案：Shepherd 服务里跑
  `guix shell --container --network`，用目标用户自己的 Home 和 `~/.paseo`，开机或随会话
  启动（272f58d）。旧的 `paseo` 账号和 `/data/paseo` 不再使用，也不迁移。
- 10/09：storie 加 `host0` macvlan 子接口，让主机能访问 relay 所在的 macvlan
  （5af0b24）。
- 10/10：Paseo worktree 目录移到 `~/.local/share/paseo/worktrees`，不再占用
  `~/Projects`（889b2df）。
- 10/16：配置分公共层 `env/paseo/config.yaml` 和 SOPS 解密的私有层，在 Home 激活时
  合并写入 `~/.paseo/config.json`（#19）。
- 10/20：系统服务等 Home 激活成功才启动 broker 和 daemon（#33）。
- 10/21：`~/.paseo/uploads` 只读挂给 contained agent，附件才读得到（#36）。

## 待定

无。后续的版本升级（0.11.4 #30、0.15.4 #95）和 relay 重启参数（#92）没有并入本项目。

## 文档

- [TODO](TODO.md)：进度。
- [lappie-migration-deploy-20261009](lappie-migration-deploy-20261009.md)：lappie 从旧系统服务迁到 Home 服务时的步骤。
- [storie-cutover-deploy-20261009](storie-cutover-deploy-20261009.md)：storie 从旧 `paseo` 账号切到 wenxin 的 Home 的说明。
- [daemon-cutover-deploy-20261015](daemon-cutover-deploy-20261015.md)：第一次切换到系统服务的操作。
- [attachments-host-transition-deploy-20261009](attachments-host-transition-deploy-20261009.md)：附件目录在 daemon 仍跑在主机上时的过渡做法。
- [relay-docker-lan-deploy-20261004](relay-docker-lan-deploy-20261004.md)：relay 上线时对 `docker_lan` 的接管说明。
