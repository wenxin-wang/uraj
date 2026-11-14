# contained-agent 的 Podman 运行时

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

让项目里的 agent 能跑 Docker/Podman 风格的任务（例如 Harbor 的 Compose 评测），又不把
主机的容器引擎或 Podman socket 交给 agent。现状见
[podman-guide](../../../contained-agent/podman-guide.md)。

## 背景

- 10/17 先把 rootless Podman 的系统配置在各系统角色间共用（75d10fe、#27）。
- 项目用中央配置里的 `(podman-remote)` 子句启用；agent 容器里只有 Podman 客户端和一个只读的
  socket 目录。
- OpenClaw 的嵌套 Podman 沙箱（#48，10/26）和这里共用 `container/seccomp.py`，属于
  [openclaw 模块](../../../openclaw.md) 的项目。

## 主要决定

- 10/26：每个项目（含有效挂载策略）一个持久的 rootless 运行时：外层 rootless 容器里跑内层
  Podman API，内层存储是主机 bind 挂载，用原生 overlay，`--storage-driver vfs` 可选；
  驱动是运行时身份的一部分（632d2d6，#20）。
- 10/26：同一个 PR 里从“每个会话自己启动外层引擎”改成主机上一个长驻的
  `podman system service`，会话只连 socket。原因是 broker 的 supervisor 在只映射本人 UID
  的用户命名空间里，`newuidmap` 失败，且它的 PID namespace 会在会话结束时杀掉运行时
  （632d2d6）。同一个服务按空闲时间（默认 30 分钟）回收运行时。
- 10/26：运行时镜像按 manifest list 的 digest 拉取并校验镜像 ID，因为主机服务的新存储拉到了
  已前进的 `:latest`（632d2d6）。见 [image-pin-design-20261026](image-pin-design-20261026.md)。
- 10/26：移除早先每项目一个 `agent-podman` SSH 账号的设计（632d2d6）。
- 运行时的 Harbor 验收见 [harbor-measure-20261025](harbor-measure-20261025.md)。

## 待定

无。验收记录里“并发和重启冒烟、真实 Harbor 试跑、Guix 构建的运行时镜像”当时列为后续，
没有单独的提交，状态未确认。

## 文档

- [TODO](TODO.md)：进度。
- [harbor-measure-20261025](harbor-measure-20261025.md)：Harbor 在运行时里的验收。
- [image-pin-design-20261026](image-pin-design-20261026.md)：运行时镜像为什么按 digest 固定。
- [storage-design-20261026](storage-design-20261026.md)：重启后的恢复和存储。
