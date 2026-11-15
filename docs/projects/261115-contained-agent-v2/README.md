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
- ~~网络？~~ 11/15 定：盒子不能访问主机回环；访问内网的限制以后再做。实测见
  [box-network-measure-20261115](box-network-measure-20261115.md)：默认 pasta 下
  主机回环连不到，但主机上监听所有地址的服务经 `169.254.1.2` 能连到，局域网也通。
- ~~盒子网络用 pasta 还是 bridge？~~ 11/15 定：pasta，加盒子 netns 里的 nftables
  （由盒子管理服务设，禁主机和内网、放行公网和 relay，运行中可改），不做 bridge。
  依据见 [grants-measure-20261115](grants-measure-20261115.md)。
- ~~审批卡片显示什么？~~ 11/15 定：事实（请求者、命令或摘要、内容 hash）加
  “agent 自述”；长脚本另开 PR，执行器只执行快照。
- ~~编排机制？~~ 11/15 定：这次不设计。
- ~~Paseo 怎么接盒子：路线 A（daemon 留主机，`podman exec`）、B（每盒一个 daemon，
  自写代理）、C（每盒一个 daemon，主机 daemon 用原生 connected hosts）？~~
  11/15 定：C。调研见 [paseo-route-design-20261115](paseo-route-design-20261115.md)。
- ~~走 C 的话，盒子在 app 里是单独的 host，新建 workspace 时要在 picker 里选，
  是否违背“不做人选 host”？~~ 11/15 定：可以接受。workspace 是动态创建的，名字有
  意义（对应任务或项目）且不重复，盒子 host 用同一个名字，人实际上不用“选”。
- ~~怎么创建 workspace？~~ 11/15 定：agent 代加；授权声明式，生命周期命令式。
  - 授权写成有名字的权限集（能 SSH 到哪、GitHub token 档位、额外挂载、设备），放在
    策略仓库；新增或修改权限集要 agent 用机器人账号提 PR，人批准合并。
  - workspace 只记录名字、仓库列表和引用的权限集，存在主机侧状态里，创建后一直存在，
    删除要显式执行（删前检查未推送的提交）。创建时 agent 发请求，人在手机上确认；
    以后可以给最低权限的 workspace 开免确认。
  - 不把 workspace 列表做成声明式：盒子里有未推送的提交、Podman 卷等状态，按声明
    对账容易误删；workspace 多且短命，每个都走 PR 太重。
- ~~workspace 是什么、文件怎么进盒子？~~ 11/15 定：
  - 创建 workspace 只考虑 Paseo；不用 Paseo、直接进盒子时，当前目录就是 workspace 根。
  - workspace 就是一个主机目录，默认取当前目录；单仓库、多仓库不用区分。
  - 盒子里沿用主机 layout：workspace 挂在和主机相同的绝对路径，HOME 也和主机一致
    （合成 HOME，只放 workspace 和声明过的东西）。
  - 内容是 workspace 根目录的递归 reflink 副本，`.git` 随便写，主机不受影响；主机上
    看不到盒子里的改动，靠 push/fetch 交换。
- ~~共享路径？~~ 11/15 定：workspace 可以声明一些子目录不拷贝，直接把主机原目录挂到
  同一路径，例如 traj-record 的 `instances`、`out`。要求下面没有 `.git`（创建时检查）；
  写在创建请求里，确认卡片单独列出；仓库里可以放默认清单，但只是建议；运行中追加走同样
  的挂载方式和确认。同一仓库的多个 workspace 共享同一份，要按 session 分子目录。
- agent 创建 workspace 的流程细节：发请求的接口（Paseo 里 agent 能调用的工具，背后是
  盒子管理服务的 socket）、请求内容（名字、主机路径、共享路径、引用的权限集、一句
  目的说明）、确认卡片、确认后由盒子管理服务建盒子、拷贝、起盒子 daemon、
  `host add`，删除前检查未推送的提交和 stash。这是建议，细节还没讨论完。
- ~~运行中怎么改授权？~~ 11/15 定：由用户级的盒子管理服务负责，不用 root：盒子创建时只挂声明
  过的东西；运行中增减挂载由它进入盒子的 mount namespace 完成（新 mount API），网络
  规则在盒子的 netns 里改，凭据走 socket、调用时查策略。agent 在盒子的 user
  namespace 里没有特权，所以自己改不了。已实测可行
  （[grants-measure-20261115](grants-measure-20261115.md)）；撤销挂载后已打开的
  文件描述符仍可用，彻底收回要杀进程或重建盒子。需要 root 的操作（sudo 加手机审批、部署）交给特权执行器，不由
  盒子管理服务做。
- ~~不用 Paseo 时怎么用？~~ 11/15 定：不单独保留旧体验。盒子是带 shell 的开发机，
  Paseo daemon 只是其中一个服务；提供一个进入盒子的入口（开 shell 或直接跑某个
  coding agent），背后是 `podman exec`。盒子分三层：盒子本身（生命周期和授权）、
  进入入口、Paseo daemon。v1 在 v2 稳定前照常可用。
- ~~设备怎么给？~~ 11/15 定：
  - 设备（GPU 渲染节点、`/dev/kvm` 等）是一种权限集，走策略仓库，确认卡片列出。
  - 运行中能加，做法和加挂载一样；撤销同样收不回已打开的 fd。
  - 进程要带上主机的 `kvm`、`render` 等附加组（crun 的 `keep-groups`），参考 v1 浏览器
    GPU 的做法。
  - 盒子有内存和 CPU 上限，沿用 `contained-podman` 的 cgroup 委托。
  - 调试 MAA 是 adb 连 storie 上的 redroid，不用本机设备，算网络授权。真实 USB 设备
    现在不设计。
  - 可行性要实测（TODO 第 9 步）。
- 策略仓库怎么设计？目录结构、权限集的语法、workspace 请求的格式、和 khalis 里策略
  仓库简报的关系。还没讨论。
- 盒子用容器还是 microVM？容器复用 `contained-podman` 服务、不需要 `/dev/kvm`、
  浏览器 GPU 照旧透传；microVM 隔离更强，但 virtiofs、GPU、Guix store 共享都要重做。
  建议先做容器，以后按需换实现。
- agent 进盒子后，原来由 `guix shell --container` 承担的隔离（synthetic HOME、
  隐藏路径、凭据挂载）怎么由盒子承担？还没列清单。已知一条：盒子 rootfs 里的
  `/etc/subuid`、`/etc/passwd` 等要归盒子里的 root，原型里归 UID 1000（agent 自己）。
- 需要 agent 帮忙部署时，走“agent 提请求、主机按 commit 构建、人确认后激活”的接口，
  凭据不进盒子。是否放进本子项目待定。

## 文档

- [TODO](TODO.md)：进度。
- [step-5-handoff](step-5-handoff.md)：第 5 步交接，继续讨论设计。
- [box-prototype-design-20261115](box-prototype-design-20261115.md)：Guix rootfs
  的盒子原型方案和实测结果。
- [paseo-route-design-20261115](paseo-route-design-20261115.md)：Paseo 接盒子的
  路线 A、B、C 调研和建议。
- [box-network-measure-20261115](box-network-measure-20261115.md)：盒子的网络
  可达性和 reflink 代价实测。
- [grants-measure-20261115](grants-measure-20261115.md)：不用 root 在运行中的盒子里
  改 nftables、增减挂载，agent 绕不过去。
- [pasta-zombie-debug-20261115](pasta-zombie-debug-20261115.md)：运行时留下
  zombie pasta 的原因；盒子的 PID 1 要用会回收孤儿的 init。
- [route-c-measure-20261115](route-c-measure-20261115.md)：路线 C 原型实测，
  app 经主机 daemon 用盒子里的 workspace、终端、文件。
- Paseo 0.15.4 源码调研，[paseo-route-design-20261115](paseo-route-design-20261115.md)
  的依据：
  - [paseo-protocol-review-20261115](paseo-protocol-review-20261115.md)：app 和
    daemon 之间的全部消息、路由分类、0.11 到 0.15 的变化。
  - [paseo-relay-review-20261115](paseo-relay-review-20261115.md)：daemon 身份、
    relay 配对、端到端加密、推送。
  - [paseo-host-exec-review-20261115](paseo-host-exec-review-20261115.md)：daemon
    在主机上执行的 git、终端、脚本，路线 A 要包装什么。
  - [paseo-connected-hosts-review-20261115](paseo-connected-hosts-review-20261115.md)：
    connected hosts 的发现、权限、隔离和缺口。
