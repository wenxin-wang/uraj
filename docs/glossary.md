# 术语表

一个东西只有一个名字，一个名字只指一个东西。新词先在这里登记再用；
编号前必须带语义名。中文文档用中文名，英文文档用英文名，二者都登记。

“代码里”一列写对应的标识符，代码标识符跟着术语走。标 **待改** 的是代码和术语
还不一致的地方，在代码下次改到时跟着改。

## 文档和协作

| 术语 | 含义 | 代码里 |
|---|---|---|
| 模块（module） | 模块表里登记的一块功能；也是 `docs/<module>.md` 的名字和 PR topic | `AGENTS.md` 模块表 |
| 子项目（project） | `docs/projects/<yymmdd>-<project>/` 下推进的一件事。不叫“项目”，免得和 contained-agent 的项目条目混；目录在 `docs/projects/` | |
| 步（step） | 子项目 `TODO.md` 里的一条，带编号和语义名 | |
| 交接（handoff） | `step-<n>-handoff.md`，第 n 步交给下一个 session 的文档 | |
| 用法手册（guide） | `<topic>-guide.md`，不带日期，描述 `main` 上的现状 | |
| 过程文档 | `<topic>-<kind>-<yyyymmdd>.md`，带日期，写完不改 | |

## 主机和部署

| 术语 | 含义 | 代码里 |
|---|---|---|
| 主机（host） | 一台机器：lappie、hypie、storie。中文不再用“宿主机” | `env/guix/os/<host>.scm` |
| lappie | 笔记本，日常开发和构建，Guix publish 的来源 | `env/guix/os/lappie.scm` |
| hypie | 台式机，跑 redroid 和 MAA，开机连 fwd2home | `env/guix/os/hypie.scm` |
| storie | 家用服务器和 NAS：Immich、new-api、OpenClaw、NFS、Paseo relay、MAA 备用 | `env/guix/os/storie.scm` |
| System 部署 | 按主机配置激活整个操作系统，本机用 `uraj-system-reconfigure`，远程用 `uraj-deploy`，见[命令速查](guix/deploy-guide.md#命令速查) | `maak` 任务 `system-reconfigure`、`deploy`；`env/guix/os/deploy/` |
| Home-only 部署 | 只激活主机配置里内嵌的 Guix Home | `OS_DEPLOY_TARGET=home`；`uraj-home-reconfigure` |
| Guix Home（Home） | Guix 管理的用户环境。首字母大写，与 `$HOME` 区分 | `src/guix/uraj/home/` |
| Live ISO | 用主机配置构建的安装镜像；与之相对的是“已安装系统” | `TO_ISO`；`src/guix/uraj/system/iso.scm` |
| guix-deploy 账号 | 远程部署用的受限 SSH 账号 | `env/guix/os/deploy/storie.scm` |
| maak | 包装 Guix 命令的任务工具 | `env/guix/maak.scm`、`env/guix/os/maak.scm`；`src/guile/uraj/maak/` |
| channels 锁 | 固定版本的 Guix channels | `env/guix/channels-lock.scm` |

## contained-agent

| 术语 | 含义 | 代码里 |
|---|---|---|
| contained-agent | 在 `guix shell --container` 里运行 coding agent 的程序 | `src/guile/uraj/bin/contained-agent.scm`；`~/.local/bin/contained-agent` |
| agent 容器 | contained-agent 一次运行创建的容器。不单说“沙箱” | |
| coding agent | Codex、Claude Code、OpenCode、Pi 这几种被包装的程序 | |
| agent spec | contained-agent 对一种 coding agent 的挂载和状态定义 | `codex-spec` 等，`src/guile/uraj/bin/contained-agent.scm` |
| 挂载子句 | `share`、`expose`、`overlay`、`persist`、`seed`、`preserve` | 同名 spec 键 |
| 项目条目 | `(project ROOT ...)`，以 worktree 顶层为键的配置 | `central-entries` |
| 中央配置 | agent 改不到的项目条目来源：Home 部署的 `projects.scm`、主机私有的 `projects.local.scm`、SOPS 解密的 `/run/secrets/contained-agent/projects.scm` | `CONTAINED_AGENT_PROJECTS` |
| 项目内配置 | worktree 里的 `.guix/contained-agent.scm`、`.guix/manifest.scm`、`manifest.scm`，批准后生效 | |
| 批准副本 | `contained-agent allow` 保存的项目内配置副本 | `~/.local/state/contained-agent/approved/` |
| 继承批准 | 新 worktree 沿用来源 worktree 的批准，`contained-agent inherit` | |
| GitHub token 级别 | `(github LEVEL)` 的 `public`、`personal`、`world`。不叫 tier | `(github TIER)` **待改** |
| 项目 SSH agent | 每个项目一个、带目标限制的主机 `ssh-agent` | `src/guile/uraj/bin/contained-ssh.scm`；`ssh-start` 等子命令 |
| Podman 运行时 | 项目专用的 rootless Podman API 容器，经 `CONTAINER_HOST` 访问 | `src/python/uraj/contained_podman.py`；Shepherd 服务 `contained-podman` |
| 版本探测 | Paseo 运行 `COMMAND --version`，不进容器 | `--version` 特判 |
| 盒子（box） | contained-agent-v2 里每个 area 一个的长期容器，coding agent、它用的 Podman 和盒子 daemon 都在里面；盒子 daemon 里可以有多个 Paseo workspace | 未实现；原型 `exp/contained-agent-v2-box_20261115/` |
| 盒子策略 | contained-agent-v2 里一个盒子的授权（SSH 目标、GitHub token 档位、设备、网络放行、共享路径），写在 area 文档里带 `:box <盒子名>` 参数的 yaml 代码块；YAML 最小子集，人批准的 PR 合并后由主机同步生效。不叫“权限集”“策略目录” | 未实现 |
| 策略同步 | contained-agent-v2 里每台主机上的程序：从 space 仓库的 `main` 取人批准过的提交，提取并校验盒子策略，原子替换主机上的生效副本，有变化就通知。不叫“同步程序” | 未实现 |
| 盒子管理服务 | contained-agent-v2 里以用户身份运行的主机服务，建、删盒子，运行中按策略增减盒子的挂载、网络规则和凭据 | 未实现 |
| 特权执行器 | 替 agent 执行要 root 的操作（部署、sudo 一类）的主机程序：agent 提请求，人经审批通道批准后执行请求的快照，凭据不进盒子。分级和审批通道在 sudo-tiers 子项目里设计 | 未实现 |
| 审批通道 | 人批准特权执行器和盒子管理服务请求的途径，在盒子外面；方向是“批准即对请求内容 hash 的签名”。不叫“确认通道” | 未实现 |
| arbiter | 审批通道的静态页，单独的公开仓库 `arbiter`，域名 `arbiter.wenxinwang.me`；读 URL fragment 里的请求，用 passkey 签名后发到 ntfy | 仓库外（`wenxin-wang/arbiter`） |
| agent 的 GitHub 身份 | contained-agent-v2 里 agent 用的 GitHub App（替代 `public`、`personal`）和机器账号（替代 `world`），与人的账号分开 | 未实现 |
| space | 人的私有仓库，存想法、计划和状态描述，按暴露范围一个范围一个（个人技术是 khalis，单位另有一个）。uraj 是代码，不是 space | 仓库外 |
| area | space 里按 PARA 带 `:area:` 标签的文档或 heading，持续维护的长期事务；有终点的叫 project。contained-agent-v2 一个 area 一个盒子 | 仓库外（space） |

## worktree

| 术语 | 含义 | 代码里 |
|---|---|---|
| worktree | Git 工作目录。统一写 worktree，不写 work tree | |
| worktree 顶层 | 当前 worktree 的根目录，相对路径以它为基准 | `git rev-parse --show-toplevel`，`project-mounts` |
| 主 worktree | 仓库的主工作目录。不叫 main repository | |
| 链接 worktree（linked worktree） | `git worktree add` 建的工作目录 | |
| 来源 worktree | 继承批准时的来源，Paseo 建 worktree 时的那个 checkout；不一定是主 worktree | |
| 固定 worktree | 在中央配置里有自己项目条目的 worktree，用 `fork-worktree` 建 | `env/dotfiles/common/shell/.local/bin/fork-worktree` |
| Paseo worktree 目录 | Paseo 放 worktree 的目录 `~/.local/share/paseo/worktrees` | `WORKTREES`，`src/python/uraj/paseo/service.py` |
| Paseo 工作区 | Paseo 应用里登记的项目/工作区。不叫“项目” | `$PASEO_HOME/projects/workspaces.json` |

## Paseo

| 术语 | 含义 | 代码里 |
|---|---|---|
| Paseo daemon | `paseo daemon run`，管理会话的服务 | Shepherd 服务 `paseo` |
| daemon 容器 | Paseo daemon 运行所在的 Guix 容器。不叫“Paseo 沙箱” | `src/guix/uraj/services/paseo.scm`、`src/guix/uraj/home/paseo.scm` |
| 应用自管的 Paseo | 桌面应用自带 daemon，没有 broker | `%paseo-setup` 为 `#f` |
| 开机模式 / 会话模式 | daemon 由系统 Shepherd 开机启动，或由用户 Shepherd 随会话启动 | `paseo-at-boot?`；`paseo-setup-autostart?` |
| Paseo broker（broker） | 主机上替 daemon 启动 provider、负责其生命周期和清理的服务 | `src/python/uraj/paseo/broker.py`；Shepherd 服务 `paseo-broker` |
| broker 客户端 | Paseo provider 命令指向的转发程序 `paseo-<agent>-<层>` | `src/guix/uraj/home/paseo-broker.scm` |
| provider | Paseo 对一个 agent 后端加执行层的配置条目，例如 `claude-system` | `PROVIDERS`、`PROVIDER_TIERS` |
| 执行（execution） | broker 的单位：一次 provider 进程树，带 broker 生成的 ID | broker 的 execution 记录 |
| 执行层（execution tier） | `daily`、`system`、`host`：用哪种 agent 容器，或直接在主机上跑 | `TIERS`；`TIER_LABELS`（日常沙箱、系统沙箱、宿主）**待改** |
| 执行 supervisor | 每次执行外层 PID namespace 的 init，带 PDEATHSIG；`--host` 模式下管 cgroup | `src/c/uraj/paseo/agent-supervisor.c` |
| broker 共享 SSH 服务 | broker 里常驻的 `contained-agent ssh-service`，为所有会话准备项目 SSH agent | `serve-project-ssh`；`--shared-ssh` |
| daemon 独立 SSH agent | daemon 容器自己的 SSH agent，由 daemon 策略配置 | `~/.local/state/paseo-sandbox/` |
| daemon 策略 | daemon 容器的挂载和凭据子句 `sandbox.scm` | `src/guile/uraj/bin/paseo-sandbox.scm` |
| broker 环境策略 | broker 传给执行的额外环境变量 `broker-sandbox.json` | broker `--policy` |
| 公共层 / 私有层 | Paseo 配置的两层 YAML：仓库里的 `env/paseo/config.yaml` 和 SOPS 解密的主机层 | `public_layer`、`private_layer` |
| 分支清理（branch GC） | 删除 Paseo 留下的已合并本地分支 | `src/python/uraj/paseo/branch_gc.py`；`paseo-branch-gc` |
| Paseo relay | storie 上的私有 relay | `src/guix/uraj/services/paseo-relay.scm` |
| connected hosts | Paseo 0.13 起的功能：一个 daemon 登记另一个 daemon，把它的会话路由给 app | 上游 `docs/connected-hosts.md`；`paseo host add` |
| 盒子 daemon | contained-agent-v2 路线 B、C 里跑在盒子里的 Paseo daemon；与之相对的是主机 daemon | 未实现 |

## OpenClaw

| 术语 | 含义 | 代码里 |
|---|---|---|
| OpenClaw | storie 上的飞书 bot 平台 | `openclaw-service-type`；Shepherd 服务 `openclaw` |
| Gateway | OpenClaw 持有凭据的主容器 | compose 服务 `gateway`；`env/docker/openclaw-gateway/` |
| 引擎容器（engine） | 跑 rootless Podman API、创建执行沙箱的容器。不叫“Docker engine” | compose 服务 `engine`；`env/docker/openclaw-sandbox-engine/` |
| 执行沙箱 | 引擎容器为每个角色创建的 Podman 容器，跑 exec、文件工具 | `env/docker/openclaw-sandbox/`；`sandbox-image` |
| 角色（persona） | 有独立身份、工作区和记忆的 OpenClaw agent | `scripts/openclaw/config-plugin/persona*.mjs` |
| 共享角色 | 群聊默认角色 `household-shared` | 同名常量 |
| 私人角色 | 每个私聊用户的默认角色 | |
| 命令管理员 | 允许执行内置命令和群命令的飞书用户 | `commands.ownerAllowFrom` |
| 话题 | 话题群里的一个 thread | `thread_id`、`topic_group` |
| 对齐（reconcile） | 启动时把运行配置对齐到 Guix 声明的基线 | `config.mjs reconcile` |
| 浏览器主登录 / 任务副本 | 角色的长期登录状态，和每个任务从它复制出的副本 | `env/docker/openclaw-sandbox/browser-profile` |

## 网络

| 术语 | 含义 | 代码里 |
|---|---|---|
| 受限网络（restricted-network） | 管理 nft 表和 Docker 网桥、限制容器出站的 Guix 服务 | `src/guix/uraj/services/restricted-network.scm`；nft 表 `restricted_network` |
| `static-agent` | OpenClaw Gateway 所在的受限网络 | `br-static-agent` |
| `sandboxed-agents` | OpenClaw 执行沙箱所在的受限网络 | `br-sbx-agents` |
| `redroid` 网络 | MAA 的 Android 实例所在的受限网络 | `%redroid-network`，`br-redroid` |
| `docker_lan` | storie 上 Immich、relay、new-api 共用的 macvlan 网络 | `docker-lan-service-type` |
| host macvlan | storie 本机用来取 DHCP 的 macvlan 子接口 `host0` | `host-macvlan-service-type` |
| fwd2home | strongSwan 全隧道 VPN 连接 | Shepherd 服务 `vpn-fwd2home`、`strongswan-charon` |
| VPN 绕行 | 在 VPN 规则之前让指定子网走主路由表的规则 | `vpn-bypass-priority` |
| 网关地址 | 网络的网关 IP。不单说“网关”，以免和 Gateway、new-api 混 | `(gateway ...)` |
| log-readers | 不用 sudo 即可读日志和工作区的用户组 | 同名组 |

## MAA

| 术语 | 含义 | 代码里 |
|---|---|---|
| MAA | 明日方舟日常任务自动化（maa-cli + MaaCore） | `src/guix/uraj/services/maa.scm`；`env/maa/` |
| 日常任务 | MAA 按时刻表跑的一轮任务 | `%maa-daily-job` |
| redroid | 上游的容器版 Android 项目 | `(uraj packages redroid)` |
| Android 实例 | hypie 上跑 MAA 的 redroid 容器 `redroid-maa` | `redroid-name`；`redroid-service-type` |
| ARM 转译（Houdini） | 在 x86 上跑 ARM 应用的 native bridge | `redroid-houdini` |
| storie 备用 | storie 上手动启动的 MAA 备用实例 | storie 配置里 `auto-start? #f` |
| remote-maa | 经 SSH 转发使用 adb/scrcpy 的脚本 | `env/dotfiles/desktop/apps/.local/bin/remote-maa` |

## 其他

| 术语 | 含义 | 代码里 |
|---|---|---|
| new-api | storie 上的模型 API 网关，记录 Claude Code 轨迹 | `src/guix/uraj/services/new-api.scm` |
| SOPS 密文 | 以 SOPS 加密进仓库、在主机上解密到 `/run/secrets/` 的秘密 | `sops-secrets-service-type`；`host-sops-services` |
| rsyslog | 替代 Shepherd 内置日志的系统日志服务，Shepherd 服务名 `syslogd` | `src/guix/uraj/services/rsyslog.scm` |
| 网络锚点容器 | 持有共享网络 namespace 的 compose 服务 `network`。不叫 pause container | |
| 镜像 ID / tag / digest | 本地不可变的 `sha256:` ID、可变的 tag、registry 的 manifest digest | `openclaw-image`、`image` 等字段 |
| 飞书 | 聊天平台。SDK 包名里的 Lark 是同一个东西 | `channels.feishu` |
| 身份（identity） | 只带限定词使用：SSH 身份、浏览器登录身份、age 身份、Git 身份 | |
| 会话（session） | 只带限定词使用：Paseo 会话、agent 容器会话、桌面会话、OpenClaw 会话 | |

## 用词约定

1. “tier”只指执行层；GitHub token 的 `public`、`personal`、`world` 叫“级别”。
   代码里 `(github TIER)` 的参数名下次改到时改为 `LEVEL`。
2. 执行层在 Paseo 界面里显示为“日常沙箱、系统沙箱、宿主”（`TIER_LABELS`），
   界面文字不改，分别对应 `daily`、`system`、`host`。
3. 不单用“沙箱”，一律带限定词：agent 容器、daemon 容器、OpenClaw 执行沙箱、
   Codex 沙箱、Chromium 沙箱、Guix 构建沙箱。
4. 受限网络的网桥名是 `br-` 加网络名，超过 15 个字符时缩写（`sandboxed-agents`
   用 `br-sbx-agents`）。

## 旧叫法

现有文档里还有这些叫法，读的时候对照；新写和修改的文字用“现在叫”一列。

| 旧叫法 | 现在叫 | 出现在（`docs/` 下） |
|---|---|---|
| the sandbox、沙箱、project container、agent container、contained session、容器内的 agent | agent 容器 / contained-agent | `contained-agent/`、`paseo/broker-*`、`secrets/` |
| Paseo application container、Paseo container、service daemon | daemon 容器 / Paseo daemon | `paseo/daemon-*`、`paseo/broker-*` |
| app-managed Paseo | 应用自管的 Paseo | `contained-agent/` |
| host broker、system broker、user broker、trial broker、packaged broker | Paseo broker（按部署方式区分时说“系统 Shepherd 的 broker”等） | `paseo/broker-*`、`paseo/daemon-*` |
| provider client、profile client、Paseo client、`paseo-codex`/`paseo-claude` | broker 客户端（后两个是兼容别名） | `paseo/broker-*` |
| broker tier、label、tier | 执行层 | `paseo/daemon-*`、`paseo/broker-*` |
| tier（GitHub）、级别 | GitHub token 级别 | `contained-agent/`、`secrets/` |
| work tree、main repository、main worktree | worktree、主 worktree | `contained-agent/`、`paseo/branch-gc-guide.md`、`paseo/broker-*` |
| source checkout | 来源 worktree | `contained-agent/` |
| worktree root（指 `~/.local/share/paseo/worktrees`） | Paseo worktree 目录 | `paseo/daemon-*`、`paseo/broker-*` |
| central policy、host policy、user-level central policy | 中央配置 | `contained-agent/`、`paseo/broker-*` |
| 私有沙箱策略、sandbox policy（daemon） | daemon 策略 | `secrets/`、`paseo/daemon-*` |
| broker sandbox policy、broker policy | broker 环境策略 | `paseo/broker-*` |
| per-project ssh-agent、project agent、restricted OpenSSH agent | 项目 SSH agent | `contained-agent/`、`desktop/ssh-keyring-guide.md` |
| shared SSH service、broker's SSH cache、shared broker agent | broker 共享 SSH 服务 | `contained-agent/`、`paseo/broker-*`、`desktop/ssh-keyring-guide.md` |
| independent SSH agent | daemon 独立 SSH agent | `paseo/daemon-*` |
| trusted init、namespace init、outer supervisor、host guardian | 执行 supervisor | `paseo/broker-*` |
| cgroup guardian | （未实现的备选设计） | `paseo/broker-*` |
| Local Podman runtime、host service、outer engine | Podman 运行时 | `contained-agent/` |
| helper app-servers、auth/catalog probes | 版本探测 | `contained-agent/`、`paseo/broker-*` |
| 宿主机 | 主机 | `secrets/` |
| 开发机、构建机、workstation | lappie（或“构建镜像的机器”） | `guix/`、`new-api/` |
| the NAS、the server | storie | `guix/storie-network-guide.md` |
| live installer、the installer、live 系统、安装镜像 | Live ISO | `maa/`、`guix/storie-network-guide.md`、`guix/` |
| installed system、安装系统 | 已安装系统 | 同上 |
| Restricted workload networks、受限网络说明 | 受限网络 | `restricted-network/`、`guix/` |
| `agents`、`br-agents` | `static-agent`、`br-static-agent` | `restricted-network/` |
| `uraj-charon` | `strongswan-charon` | `guix/strongswan-guide.md` |
| full tunnel、全隧道、boot VPN | fwd2home | `maa/`、`guix/strongswan-guide.md` |
| fwd2home bypass | VPN 绕行 | `maa/` |
| 独立引擎容器、沙箱引擎、Docker engine（指 OpenClaw） | 引擎容器 | `openclaw/` |
| 工具沙箱、角色沙箱、工具容器、Podman 沙箱 | 执行沙箱 | `openclaw/` |
| 共享助手、私人助手 | 共享角色、私人角色 | `openclaw/` |
| 管理员（OpenClaw） | 命令管理员 | `openclaw/` |
| 配置协调程序、校验入口 | 对齐（reconcile） | `openclaw/` |
| the instance、production container | Android 实例 | `maa/` |
| daily run、scheduled run、daily round | 日常任务 | `maa/` |
| manual standby | storie 备用 | `maa/` |
| pause container、anchor | 网络锚点容器 | `new-api/`、`guix/` |
| system-log、syslog | rsyslog（Shepherd 服务名 `syslogd`） | `guix/`、`openclaw/` |
