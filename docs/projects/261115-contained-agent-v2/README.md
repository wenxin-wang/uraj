# contained-agent-v2

## 目标

每个 Paseo workspace 一个盒子：coding agent 和它用的 Podman 在同一个容器里，
权限只描述盒子的边界（挂载、网络、设备、凭据 socket）。agent 看到的是一台普通
开发机，不需要知道 Podman 运行时在哪、端口怎么转。

现有的 [contained-agent](../../contained-agent.md) 保持现状，不再为 v2 改动。

## 背景

现在 agent 容器和 [Podman 运行时](../../contained-agent/podman-guide.md)
是主机上并列的两个容器，靠一个 API socket 相连：

- 网络不通：运行时里 `-p` 发布的端口和 `podman inspect` 给的 IP 都在运行时
  的网络 namespace 里，agent 访问 `127.0.0.1:PORT` 不通。
- `/tmp`、bind 源路径要两边对齐，挂载策略写两份。
- 拆开的原因是 Paseo broker 的 user namespace 只映射用户自己的 ID，agent
  容器里起不了嵌套 Podman，见 podman-guide 的 Host Podman service 一节。

另外，现有 contained-agent 和 Paseo daemon 共享网络；daemon 没设密码时 HTTP API
不鉴权，能建 agent、开终端、回答任意 agent 的权限请求。这个问题由 v2 解决，不单独
抢修。

盒子由 `contained-podman` 服务创建。原型和实测见
[box-prototype-design-20261115](box-prototype-design-20261115.md)：rootfs 可以完全由
Guix profile 提供，嵌套 Podman 跑得起 Postgres，盒子里访问发布的端口是透明的。

## 待定

- ~~盒子的单位？~~ 11/15 定：Paseo workspace。workspace 可以是非 git 的顶层目录，
  下面放多个仓库；同一 workspace 的 agent 共用一个盒子，彼此不设防；不同 workspace
  和不同 space 用不同盒子。按目的授权就是按 workspace 授权。
- ~~仓库怎么进盒子？~~ 11/15 定：`.git` 可写，仓库用 reflink（不支持时完整拷贝）
  放进盒子；submodule、worktree 由盒子里的 agent 处理，和外界只经远端 push/fetch
  交换。主机不在盒子里的仓库上运行 git。
- ~~agent 建的 worktree 放哪？~~ 11/15 定：按约定由 agent 自己建，不放在 Paseo 的
  worktree 根目录下；回收由盒子负责。
- ~~盒子里有什么？~~ 11/15 定：默认有 Podman 和主机的 Guix daemon，接受 Guix daemon
  绕过盒子网络策略的风险，不做单独的 store。agent 在盒子里装包、重新加载 manifest
  不需要 `contained-agent allow`。
- ~~网络？~~ 11/15 定：盒子不能访问主机回环；访问内网的限制以后再做。现状见
  第 2 步的实测。
- ~~审批卡片显示什么？~~ 11/15 定：事实（请求者、命令或摘要、内容 hash）加
  “agent 自述”；长脚本另开 PR，执行器只执行快照。
- ~~编排机制？~~ 11/15 定：这次不设计。
- Paseo 怎么接盒子：路线 A（daemon 留主机，`podman exec`）、B（每盒一个 daemon，
  自写代理）、C（每盒一个 daemon，主机 daemon 用原生 connected hosts）。调研见
  [paseo-route-design-20261115](paseo-route-design-20261115.md)，建议 C。
- 走 C 的话，盒子在 app 里是单独的 host，新建 workspace 时要在 picker 里选。这和
  “不做人选 host”是否冲突？可选：接受（host 由主机侧按约定创建和登记，人只选不配）；
  不接受则在 C 之上给 app 加一层或回到 B。建议接受。
- 盒子用容器还是 microVM？容器复用 `contained-podman` 服务、不需要 `/dev/kvm`、
  浏览器 GPU 照旧透传；microVM 隔离更强，但 virtiofs、GPU、Guix store 共享都要重做。
  建议先做容器，以后按需换实现。
- agent 进盒子后，原来由 `guix shell --container` 承担的隔离（synthetic HOME、
  隐藏路径、凭据挂载）怎么由盒子承担？还没列清单。
- 需要 agent 帮忙部署时，走“agent 提请求、主机按 commit 构建、人确认后激活”的接口，
  凭据不进盒子。是否放进本子项目待定。

## 文档

- [TODO](TODO.md)：进度。
- [box-prototype-design-20261115](box-prototype-design-20261115.md)：Guix rootfs
  的盒子原型方案和实测结果。
- [paseo-route-design-20261115](paseo-route-design-20261115.md)：Paseo 接盒子的
  路线 A、B、C 调研和建议。
