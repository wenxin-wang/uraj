# OpenClaw 的 Podman 执行沙箱

已完成的历史项目，按 `git log` 重建；时间线以提交日期为准，没有提交可查的事实写
“未确认”。

## 目标

OpenClaw 的 exec、process 和文件工具原先在 Gateway 容器里运行，能读到 Gateway 的凭据、
改写它的配置。把这些工具挪进每个 agent 一个的 rootless Podman 沙箱，沙箱由一个不带
凭据的“引擎容器”提供，Gateway 不接触主机 Docker socket。现状见
[sandbox-guide](../../../openclaw/sandbox-guide.md)、
[images-guide](../../../openclaw/images-guide.md) 和
[deploy-guide](../../../openclaw/deploy-guide.md)。

## 背景

- 引擎的放宽参数沿用 contained-agent Podman 运行时的经验，见
  contained-agent 的历史项目 `261017-contained-podman`；那是在 rootless Podman
  外层验证的，Docker 外层要另做一次，所以先有一个一次性探针。
- 探针记录见 [engine-params-debug-20261024](engine-params-debug-20261024.md)。

## 主要决定

- 10/24（`d419d4f`，在 #48 的分支上）：先加 Docker 里跑 rootless Podman 的探针
  `check-docker-engine.py`，逐项验证最小放宽参数；把嵌套 seccomp 的改写抽成
  contained-agent 也能用的共享模块。
- 10/25–10/26（#48）：Gateway、引擎和沙箱都以专用账号 `openclaw`（UID/GID 2010）运行；
  引擎接新的 `sandboxed-agents` 受限网络，沙箱够不到 Gateway 和 new-api；工作区经 ACL
  给 `log-readers` 读取；原来的配置改写入口换成 Gateway 侧工具 `openclaw_config_set`。
  旧数据布局不迁移，按清空处理，见
  [old-layout-migration-deploy-20261026](old-layout-migration-deploy-20261026.md)。
- 10/29（#64）：沙箱镜像在服务启动时由引擎里的 Podman 构建，不再手工构建和导入；
  显式配置 `sandbox-image` 仍可跳过构建。
- 10/29（#70）：沙箱镜像加 `python` 和 `node`，依据是已有对话记录里反复出现
  `python: not found`。
- 10/30（#73）：服务启动时为每个工作区建属主 2010 的 `.openclaw/tmp`，因为 crun 为
  挂载 skill 创建 `.openclaw` 时属主是沙箱 root 映射的子 UID。
- 11/10（#92）：`herd restart openclaw TAG` 在 reconfigure 后带上参数。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [engine-params-debug-20261024](engine-params-debug-20261024.md)：引擎容器参数逐项验证。
- [old-layout-migration-deploy-20261026](old-layout-migration-deploy-20261026.md)：旧数据布局的清空迁移。
