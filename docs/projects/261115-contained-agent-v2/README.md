# contained-agent-v2

## 目标

每个 area 一个盒子：coding agent 和它用的 Podman 在同一个容器里，
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

- ~~盒子的单位？~~ 11/16 改定：area（space 里 PARA 的 area，持续维护的长期事务），
  不再是 Paseo workspace（11/15 的决定作废）。一个盒子长期存在，盒子 daemon 里可以有
  多个 Paseo workspace，一个 project 或任务一个；同一盒子里的 agent 彼此不设防，
  不同 area 和不同 space 用不同盒子。授权按盒子（area）给，写在盒子策略里：
  - 要人确认的只有：新建盒子（新 area）、改盒子策略（加授权或共享路径）、把新的主机目录
    拷进盒子。在已有盒子里新建 workspace 用同一套权限，agent 自己建，不用确认。
  - 生命周期长了，要另外设计：升级盒子里的 profile 和 Paseo（重建盒子、保住状态和
    serverId）、开机自动起盒子（主机侧 Shepherd 服务）、worktree 和 Podman 镜像卷的
    空间回收。删除流程照旧，只是少用。
  - 下面各条里写“创建 workspace”“workspace 的权限”的地方，凡涉及确认、拷贝和授权的，
    按“盒子”理解；还没逐条改写。
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
  - 授权写成声明式（能 SSH 到哪、GitHub token 档位、额外挂载、设备；11/16 起是 area
    文档里的盒子策略）；改动要 agent 用自己的 GitHub 身份提 PR，人批准合并（见“agent 的 GitHub 身份”）。
  - workspace 只记录名字、仓库列表和引用的授权，存在主机侧状态里，创建后一直存在，
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
- agent 创建 workspace 的流程细节（建议，部分已定）：
  - 确认必须走盒子外面的通道：盒子里的 Paseo 确认框 agent 能伪造。11/15 定：和特权
    执行器共用一个审批通道，这个通道人还有别的想法，合在一起慢慢排；做好之前先用主机
    终端命令确认。
    11/16：审批通道和 sudo 分级一起在 [sudo-tiers](../261116-sudo-tiers/README.md)
    里讨论；方向是批准即签名，只靠 Paseo 权限框不够安全，但 agent 的请求经 Paseo
    推送通知是合理的。
  - 请求经盒子里盒子管理服务的 socket 发出，来源 workspace 由 socket 决定；内容是
    新 workspace 名、topic id、主机路径（默认发请求的 workspace 根）、共享路径、授权、
    一句目的说明；每个盒子待确认的请求有上限。
  - 卡片分两部分：盒子管理服务核实过的事实（来源 workspace 和 topic、名字、路径的文件数
    和大小及各仓库分支和未提交改动、共享路径及其下没有 `.git`、授权按当前生效策略展开
    成实际授权并标出 commit、请求 id 和有效期），和标明未核实的“agent 自述”。只有批准
    和拒绝，要改就重新请求。
  - 批准后盒子管理服务依次：reflink 拷贝（跳过共享路径）、起盒子、设 nftables 和挂载、
    起盒子 daemon、`host add`（`sourceKey` 用 workspace 名），把结果回给发请求的 agent。
    人在主机终端里 `new` 不需要手机确认。运行中追加授权或共享路径走同样的请求和卡片。
  - 11/15 定：删除先进回收站，停盒子、`host rm`，状态目录保留一个月再删，期间可恢复；
    检查干净（盒子里跑 git：未推送提交、stash、未提交改动、未跟踪文件；非空 Podman
    卷；运行中的 agent）就一键确认，不干净就在卡片上列出，照样可删。
  - 11/15 定：盒子里的 agent 只能请求删除自己所在的 workspace，删别的只能人在主机上做。
  - 收尾：app 里残留的盒子 host 在 Paseo 0.15.4 上清不掉，app 只增不删经中转的连接
    （`packages/app/src/runtime/host-runtime.ts` 的 `syncHostDiscovery`），要改上游。
    topic 里的 workspace 属性建议由 agent 在发删除请求前提 PR 去掉，卡片显示 PR 链接；
    人在主机上删的，由盒子管理服务在通知里提醒去掉哪个 topic 的属性。
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
  - 设备（GPU 渲染节点、`/dev/kvm` 等）是盒子策略里的一类授权，确认卡片列出。
  - 运行中能加，做法和加挂载一样；撤销同样收不回已打开的 fd。
  - 进程要带上主机的 `kvm`、`render` 等附加组（crun 的 `keep-groups`），参考 v1 浏览器
    GPU 的做法。
  - 盒子有内存和 CPU 上限，沿用 `contained-podman` 的 cgroup 委托。
  - 调试 MAA 是 adb 连 storie 上的 redroid，不用本机设备，算网络授权。真实 USB 设备
    现在不设计。
  - 实测（[devices-measure-20261115](devices-measure-20261115.md)）：render node
    运行中挂进盒子可用，附加组能带进盒子；`/dev/kvm` 挂上了但用户不在 `kvm` 组，
    打不开。要在盒子里用 KVM，先在主机配置里把用户加进 `kvm` 组（人定）。
- ~~策略放哪、怎么写？~~ 11/16 改定（11/15 的 `.agent/policy/` 目录作废）：
  - 盒子策略写在 area 文档里：一个带 `:box <盒子名>` 参数的 yaml 代码块，写这个盒子
    的 SSH 目标、GitHub token 档位、设备、网络放行、共享路径等。人打开 area 文档就能
    看到它的 agent 能做什么。
  - 不另建目录：程序按 PARA 已有的 `:area:` 文件标签找文档，只认 `#+filetags:`、
    文件开头的 `:ID:` 和 `:box` 代码块，不需要完整的 org 解析器。area 在哪个 space
    仓库，策略就跟着在哪（个人机器 khalis，单位电脑单位的 space 仓库），暴露范围自然
    对齐；每台主机的策略同步只读它该读的仓库。
  - 暂不做有名字的共用授权和主机设定文件：每个盒子把授权直接写在自己的块里；设备路径
    由盒子管理服务在主机上自己查（策略里只写 `gpu` 这类名字）。真需要复用时再加一个
    “共用授权”的 org 文档。没有一处能看到全部盒子的权限，由策略同步生成汇总。
  - 块里的语法：YAML 最小子集，只有字符串、字符串列表和固定的键，一律按字符串解析；
    严格校验，未知键或类型不对就报错，策略同步时校验不过保留上一版；khalis 里加 CI 跑
    同一个校验，PR 上直接看到对错。手机上主要是审 agent 提的 diff，不是手写。
  - 策略改动可能夹在大 PR 里被一起批准。11/16 定：khalis 的 CI 在 PR 上标出盒子策略
    的变化（例如“盒子 X：新增 ssh Y”），批准前就能看到；生效时策略同步再推通知。
    不再要求“只改策略的 PR 才生效”（会拦住新建 area 文档这类正常 PR）。
  - 策略同步：每台主机上的一个程序，由 Shepherd 定时器和手动命令触发。它 fetch space
    仓库的 `main`，确认最新提交来自人批准的 PR，提取所有盒子策略块并校验，通过后原子
    替换主机上的生效副本，有变化就推通知；任何一步不过就保留上一版并报错。盒子管理
    服务只读生效副本，不读人的工作 clone（里面可能有没合并的改动）。
- ~~topic 和 workspace 怎么对应？~~ 11/16 改定：盒子用 area 的名字，写在 area 文档
  盒子策略块的 `:box` 参数里；盒子里的 Paseo workspace 用 project 或任务的名字，project 文档里加
  属性写它的 workspace。新建盒子的请求带 area 的 id，确认卡片显示 area。同一个主机
  目录可以拷进多个盒子，各自是独立的 reflink 副本，权限跟着盒子。Paseo 有没有
  打开某个 workspace 的深链接没查过。
- ~~盒子策略和 khalis 里“机器人账号加私有明文策略仓库”简报的关系？~~ 11/15 定：
  只在 v2 实现，v1 不动，继续用现有三处来源。
- ~~怎么访问盒子里的服务？~~ 11/16 定：按需转发。盒子里用 socat 把端口转成
  `/run/box/` 下的 unix socket（同路线 C 暴露 `paseo.sock`），盒子管理服务在主机
  上把它接到 `127.0.0.1:<端口>`，端口号尽量和盒子里相同，冲突时另分；只在主机回环上，
  不算授权，agent 可以自己开。HTTP 以后可加按 `*.localhost` 分发的反向代理；
  从别的机器访问以后再说。pasta 新版本带 `pesto`，能经控制 socket 运行中增删转发，
  但 Guix 的 passt 是 2024_12_11、没有它，Podman 也不暴露这个 socket，所以现在不用；
  创建时 `-p` 发布和 `-t auto` 不采用（不能运行中加、多盒子端口冲突）。
- ~~agent 的 GitHub 身份？~~ 11/16 定：agent 不再用人的 token，换独立身份；改
  secrets 只在 v2 里做，v1 的三级 token 不动。
  - 现在 agent 和人同一个 GitHub 账号：分支保护分不出是谁合的；`world` 是带 `repo`
    scope 的 classic token，能改掉分支保护。所以“禁止 agent 合 PR”和策略同步的
    “最新提交来自人批准的 PR”在 v1 下都核实不了。
  - `public`、`personal` 两级换成 GitHub App：装在人的账号上，只勾 agent 用的仓库，
    权限 Contents、Pull requests、Workflows 写；私钥进 SOPS，盒子管理服务按盒子策略
    现签一小时的 installation token，签时可再缩小仓库范围，经凭据 socket 给盒子。
  - `world`（fork、给别人的仓库提 PR）换成机器账号的 classic token：App 做不了用户
    身份的操作。
  - 人的仓库 `main` 开 ruleset：必须 PR、1 个批准，绕过名单只有人。agent 能推分支、
    开 PR、合到非 `main` 分支（堆叠 PR），合不进 `main`。以后要开放，可以另建组织把
    App 装进去给管理权限，或者单独加一个特权级别，盒子策略里写明哪个盒子能用。
  - App 不装到审批页的 `arbiter` 仓库（见 [sudo-tiers](../261116-sudo-tiers/README.md)）。
  - 没实测：机器账号的 fine-grained token 能否访问人的仓库（预计不能）；ruleset 的
    绕过名单对 App 和 token 的实际效果。
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
- [devices-measure-20261115](devices-measure-20261115.md)：运行中给盒子加、撤
  GPU render node 和 `/dev/kvm`。
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
