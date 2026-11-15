# Paseo 怎么接盒子：路线 A、B、C 的调研（2026-11-15）

基于 Paseo 0.15.4 源码（`getpaseo/paseo` 的 `v0.15.4` tag），只读源码，没有跑
daemon。下文路径相对上游仓库。盒子以 Paseo workspace 为单位，见
[README](README.md) 的待定项。

## 三条路线

- **A**：daemon 留在主机，agent 用 `podman exec` 进盒子。
- **B**：每个盒子一个 daemon，主机上自写代理，对 app 冒充单个 daemon。
- **C**：每个盒子一个 daemon，主机 daemon 用 Paseo 自带的 connected hosts
  （0.13.0 起，`docs/connected-hosts.md`）经 unix socket 连到盒子 daemon，app
  只和主机 daemon 配对。调研中发现，简报里没有。

## 路线 A：主机侧还会执行什么

daemon 自己的 git、终端、脚本在主机上运行。能用包装程序转进盒子的：

| 环节 | 现状 | 转进盒子的办法 |
|---|---|---|
| git | `spawnProcess("git", ["-c","core.quotepath=false","-c","core.fsmonitor=false",...])`，按 PATH 找（`packages/server/src/utils/run-git-command.ts:398`）；`commit` 不带 `--no-verify`，`diff` 不带 `--no-textconv` | PATH 前置 `git` 包装，按 cwd 选盒子；要透传 stdin、退出码和 `GIT_INDEX_FILE` 等变量 |
| `gh`、`glab`、`tea` | 按 PATH 执行 | 同上 |
| 终端 | node-pty，shell 只取 `$SHELL`（`packages/server/src/terminal/terminal.ts:264`） | daemon 的 `SHELL` 指向包装；包装要叫 `zsh` 才保留 shell integration |
| provider | 命令是可替换的 argv 数组；启动环境带 `PASEO_AGENT_ID`、`PASEO_AGENT_CWD` | 换成 `podman exec` 包装；`--version`、模型发现、auth 探测没有 workspace，包装要有回退 |

包装之后仍在主机上执行仓库内容，或者会坏的：

- `paseo.json` 的 `worktree.setup`、`teardown` 写死 `bash -c`；`portScript`
  直接 `execFile`。
- 带 `command` 的 `create_terminal` 绕过 `$SHELL`。
- 通用 ACP 默认 `terminal: true`（`packages/server/src/server/agent/providers/acp-agent.ts:307`），agent 的
  `terminal/create` 在主机上起任意命令；要配 `clientCapabilities.terminal=false`。
- OpenCode 默认所有 agent 共用一个 `serve`，没法按盒子分。
- daemon 直接用 fs 读写 `.git` 里的状态文件、`paseo.json`、浏览文件、监听变化；
  transcript 从主机的 `~/.claude/projects/<cwd 编码>/` 读，上传落在
  `$PASEO_HOME/uploads/`。所以盒子里的 workspace、transcript、上传目录都要在
  主机上同路径可见。
- diff 的 all-changes 模式把 `GIT_INDEX_FILE` 指到主机 `/tmp`。

结论：可做，但接缝多，而且每次升级都可能多出新的主机侧执行点。

## 路线 B：自写代理的工作量

- app 发给 daemon 的请求 219 种（`packages/protocol/src/messages.ts:3283`），
  出站 238 种。按 agent 路由 28、按路径或 workspace 72、全局 62、创建 9、
  可直接拒绝 17，另有 31 种归不进这几类又不能拒绝（只带 terminalId 的终端消息、
  订阅释放、上传、schedule、浏览器自动化的反向 RPC、心跳等）。
- 必然冲突的状态：终端二进制帧的 slot 每条连接从 0 开始，代理要改写每帧；
  agent、workspace、project 列表的同步游标是每个 daemon 各自的，代理要自造全局
  游标；按标题或 UUID 前缀找 agent 的请求只能广播解析。
- relay 和端到端加密能复用 `@getpaseo/relay/e2ee`，估计 2–4 天；推送要代理自己存
  token、自己判断是否推。
- 协议变化：0.11.0 到 0.15.4 约五周，入站 206→219、出站 224→238，没有删除或改名，
  `messages.ts` +256/−11 行。没有版本协商，靠 `server_info.features`；不认识的请求
  回 `unknown_schema`，app 只让该请求失败，不断连。

结论：代理本质上是一个简化版 daemon，几周的工作量，并要跟着升级维护。

## 路线 C：原生 connected hosts

| 项 | 情况 |
|---|---|
| 连接目标 | `unix:///path`、`/path`（`packages/protocol/src/host-target.ts`）；socket 目标不支持密码，安全靠 socket 文件权限 |
| app 侧 | 主机 daemon 上登记的盒子会被 app 自动发现，存成 `type: "routed"` 的 host（`packages/app/src/runtime/host-runtime.ts:2452`）；会话、终端、文件、diff 都走普通 `DaemonClient`，没看到功能门控 |
| 路径 | app → relay（端到端加密）→ 主机 daemon → 链接 → 盒子 daemon；主机 daemon 看得到明文 |
| 一跳 | 已路由的会话不能再开链接（`packages/server/src/server/connected-hosts/link.ts:94`）；登记不给反向访问；盒子之间不通 |
| 身份 | 首次连接时固定 serverId；盒子重建要保留 `$PASEO_HOME/server-id` 或设 `PASEO_SERVER_ID` |
| 限制 | 128 个登记、128 个通道；两边都要 0.13 以上 |

仍要自己做的：

- **盒子生命周期**：建盒子、起 daemon、`paseo host add`（带 `sourceKey`，幂等）、
  回收时 `host rm`。主机 daemon 的 `workspace.create.*` hook 不能把创建改到盒子上。
- **选 host**：新建 workspace 时，人要在 picker 里选一个 host，盒子作为单独的 host
  出现（`packages/app/src/screens/new-workspace-screen.tsx`）。和简报里“不做人选 host”的决定冲突，见 README
  待定。
- **agent MCP**：盒子 daemon 只监听 unix socket 时，agent 的 Paseo MCP 和终端活动
  回调关闭（`packages/server/src/server/bootstrap.ts:274`，只认 TCP）。盒子有自己的
  网络 namespace，盒子 daemon 可以监听盒子内的回环 TCP，再由盒子里的转发程序提供
  给主机的 unix socket；同时监听两种是否可行未确认。
- **推送**：盒子 daemon 直接 POST 到 Expo 的推送服务，盒子要能出网（现在能）。
- **app 里的残留**：`host rm` 后 app 里的 host 档案要手动删。
- **权限模型**：没设密码时任何连接都是 owner。盒子里的 agent 能连同盒子的 daemon，
  能回答同盒子里任何 agent 的权限请求；这在同一 workspace 内是可接受的（彼此不设防），
  但要求主机侧的审批不能经盒子 daemon，必须由主机侧生成。主机 daemon 上的 agent 能以
  owner 身份操作所有盒子，所以主机 daemon 不应该跑 agent。

## 对比

| | A | B | C |
|---|---|---|---|
| 主机上执行仓库内容 | 要逐个包装，仍有漏网（setup/teardown、portScript、ACP、OpenCode） | 无 | 无 |
| 终端、脚本、git、OpenCode | 包装或丢功能 | 原生，在盒子里 | 原生，在盒子里 |
| 盒子到主机 | 盒子要连主机上的 MCP、OpenCode serve 端口 | 不需要 | 不需要 |
| app 体验 | 单 host | 单 host | 每个盒子一个 host，新建 workspace 时选 |
| 审批 | 主机侧 plugin provider | 代理生成 | 主机 daemon 上的 plugin provider |
| 自写代码 | 一组包装 | 简化版 daemon（几周） | 盒子生命周期、登记、MCP 转发 |
| 升级维护 | 每次查新的主机侧执行点 | 每次跟协议 | 跟 connected hosts 这个功能 |

## 建议

走 C。它拿到了 B 的隔离（盒子里的东西只在盒子里执行），又不用写代理，自写部分是盒子
生命周期这些本来就要做的事。要人定的是“新建 workspace 时在 app 里选盒子 host”能否
接受；如果不能接受，再考虑在 C 之上给 app 加一层，或者回到 B。

## 没验证的

- 都是读源码，没有在真机上让 app 经主机 daemon 打开盒子里的会话。
- 盒子 daemon 能否同时监听 unix socket 和回环 TCP。
- 主机 daemon 上的 plugin provider 发的权限请求，和盒子 host 的 agent 请求在手机上
  怎么并列显示。
- 盒子能否访问主机回环（因此能否碰到主机 daemon），等网络实测。
