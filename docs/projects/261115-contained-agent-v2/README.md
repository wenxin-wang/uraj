# contained-agent-v2

## 目标

每个项目一个盒子：coding agent 和它用的 Podman 在同一个容器里，权限只描述
盒子的边界（挂载、网络、设备、凭据 socket）。agent 看到的是一台普通开发机，
不需要知道 Podman 运行时在哪、端口怎么转。

现有的 [contained-agent](../../contained-agent.md) 保持现状，不再为 v2 改动。

## 背景

现在 agent 容器和 [Podman 运行时](../../contained-agent/podman-guide.md)
是主机上并列的两个容器，靠一个 API socket 相连：

- 网络不通：运行时里 `-p` 发布的端口和 `podman inspect` 给的 IP 都在运行时
  的网络 namespace 里，agent 访问 `127.0.0.1:PORT` 不通。
- `/tmp`、bind 源路径要两边对齐，挂载策略写两份。
- 拆开的原因是 Paseo broker 的 user namespace 只映射用户自己的 ID，agent
  容器里起不了嵌套 Podman，见 podman-guide 的 Host Podman service 一节。

盒子由 `contained-podman` 服务创建，agent 由主机侧 exec 进去，和盒子里的
Podman 共享网络和文件系统。原型方案和实测见
[box-prototype-design-20261115](box-prototype-design-20261115.md)：盒子的
rootfs 可以完全由 Guix profile 提供，嵌套 Podman 跑得起 Postgres，盒子里
访问发布的端口是透明的。

## 待定

- 盒子用容器还是 microVM？容器复用现有的 `contained-podman` 服务、不需要
  `/dev/kvm`、浏览器 GPU 照旧透传；microVM 隔离更强、网络可以直接接受限网络，
  但 virtiofs、GPU、Guix store 共享都要重做。建议先做容器，对上层暴露同一个
  盒子抽象，以后按需换实现。
- agent 进盒子后，原来由 `guix shell --container` 承担的隔离（synthetic
  HOME、隐藏路径、凭据挂载）怎么由盒子承担？还没列清单。
- 盒子出网要不要接受限网络？接的话需要 root 侧把 veth 接进盒子的 netns；
  不接则出网仍走 pasta。
- agent 在会话中途加包：给每个项目一个 agent 自有的 Guix profile，放进
  `PATH`，在盒子里求值，不需要 `contained-agent allow`。具体形态待定。
- 需要 agent 帮忙部署时，走“agent 提请求、主机按 commit 构建、人确认后激活”
  的接口，凭据不进盒子。是否放进本子项目待定。

## 文档

- [TODO](TODO.md)：进度。
- [box-prototype-design-20261115](box-prototype-design-20261115.md)：Guix rootfs
  的盒子原型方案和实测结果。
