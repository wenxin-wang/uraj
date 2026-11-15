# Paseo connected hosts 调研（v0.15.4）

源码根：上游 `getpaseo/paseo`。记号：A = 主机 daemon（app 唯一配对对象），B = 盒子 daemon。
路径缩写：`S/` = `packages/server/src/server/`，`APP/` = `packages/app/src/`，`D/` = `docs/`，`P/` = `public-docs/`。

## 结论（先说）

native connected hosts 基本可以替代"自写代理"（route B）。App 会自动发现并把盒子当成一等 host，会话、终端、文件、diff 都走同一套 DaemonClient。
不能直接解决的有三类：
- 盒子创建/注册的编排；
- 仅 unix socket 监听时 agent 的 MCP 注入被关掉；
- 推送通知走盒子自己发。

## 1. App 侧：发现与 UI

### 1.1 发现是自动的，不需要人手动加

- `APP/runtime/host-runtime.ts:2457-2500` `syncHostDiscovery()`：对每个已连接且 `features.connectedHosts` 的 host 调 `client.observeHosts()`（`:2466`）。
  - 对目录里每个 `serverId` 非空且不是自己的条目，调用 `upsertHostConnectionInProfiles`，写入 `{id:"via:<origin>", type:"routed", originServerId}` 这个连接候选（`:2470-2480`）。
  - 随后 `setHostsAndSync` 并 `persistHosts()`（`:2482-2483`），即写入 app 本地存储。
  - 对新发现的 host 立刻 `acquireDirectoryDemand`（`:2485-2489`），所以盒子的 workspace 列表会自动进入侧栏，无需用户先点进去。
- `APP/types/host-connection.ts:60-64`（`RoutedHostConnection`）、`:485`（持久化 schema）：routed 是正式的连接类型。
- 路由 host 的客户端：`APP/runtime/host-runtime.ts:597-606` 和 `:658-680`。用 `createHostChannelTransport(origin, host.serverId, ...)` 在 origin 的连接上开一个虚拟通道，上面跑完整的 `DaemonClient`。
  - 所以对 app 来说它就是一个普通 host，只是 transport 不同。
- `serverId` 为 null（B 还没连上过）的注册不会出现在 app（`:2470` 过滤 `!target.serverId`）。
- 离线/disabled/error 的注册只要 `serverId` 已知，也会出现，目录条目不看 status。
- 仅一跳：`:2463` 当本 host 已是 routed 连接时不再 observe。

### 1.2 需要人选 host 吗

- 新建 workspace：`APP/screens/new-workspace-screen.tsx:650-756` 有 `useNewWorkspaceHostSelector`，候选是 `useHosts()`（`:777`）。
  - 自动选择逻辑按路由、上次活动项目、连接状态决定，另有手动 host picker（`:906`、`:1479-1484`）。
  - 创建走选中 host 的 client：`:1236` 起 `createMultiplicityWorkspace({client: connectedClient, sourceDirectory ...})`，source directory 是 B 上的路径。
  - 结论：人要在 UI 里选 host（或通过项目/路由默认），routed 盒子和普通 host 并列在 picker 里。
- 因此"盒子是否预先存在"决定能否被选中，见第 5 节。

### 1.3 功能覆盖

- 未发现 app 里有按 `routed` 或 `connectedHosts` 禁用功能的开关。`APP` 内 `routed` 只出现在连接建模、host-runtime、设置页文案（`APP/screens/settings/host-page.tsx:112` "Via <origin>"）和 `local-credential.ts:13`（routed 不读桌面本地凭据）。
  - 会话、终端、文件、diff、provider 等都基于同一个 `DaemonClient`，没有分叉。
  - `D/connected-hosts.md` 专门说明了二进制路由帧（终端/文件传输字节，opcode + channel id，100 MiB 限制不变）。
- 唯一和连接类型有关的 UI 差异：
  - `open-in-editor`、`open-in-file-manager` 依赖 `useIsLocalDaemon(serverId)`（`APP/hooks/use-is-local-daemon.ts`，比较桌面 daemon 的 serverId），对盒子自然是非本地，这些功能不可用，符合预期。
  - `APP/utils/workspace-script-links.ts:44`：服务链接 URL 对非 `directTcp` 一律生成 `http://localhost:<port>`，对盒子里的 service 脚本这个链接会指向 app 本机，错误。属于小缺陷，未确认是否有别的代理机制覆盖。
- app 里没有管理"daemon 保存的 connected hosts"的 UI（grep `hosts.add` 在 app 内无调用）。注册只能走 CLI（`paseo --host A host add ...`）、SDK 或插件。
- 删除行为：app 内删除 routed host 只删本地 profile（`host-runtime.ts:2254-2258` `removeHost`）。
  - 发现逻辑只 upsert 不删除（`:2470-2500`），所以 A 上的注册还在时，下次 `hosts.changed` 或重连又会被加回来。
  - 反过来，A 上删除注册后，app 里的旧 routed profile 不会自动消失（未见清理代码），需用户手动删除。

## 2. 端到端、可见性、权限

### 2.1 链路

- app -> relay -> A（relay E2EE，细节由别的调研覆盖）-> A 的 `ConnectedHosts` 物理 link -> B。
- A 对 B 是一个普通 client：`S/connected-hosts/index.ts:196-205` 用 `createHostClient(row.connection, {clientId:"host-link-..."})`。
- 每个 app 作用域在 B 上是一个虚拟 session：`hosts.link.open.request`，`S/connected-hosts/link.ts:77-215`，`VirtualHostSocket` 在 `:15-60`。
- A 对盒子流量是明文（E2EE 终止在 A），`openRoute` 在 `S/connected-hosts/index.ts:296-540` 里解析并转发每一帧（还会改写 hello，`:513-535`）。盒子流量也会落在 A 的内存里，没有针对 B 的端到端保护。未确认其是否有日志落盘，这里没找到。

### 2.2 B 上的权限

- A 打开 route 时把调用方 session 的权限塞进 hello 的 `sessionPermissions`（`S/connected-hosts/index.ts:529`；`S/connected-hosts/session.ts` 的 `open()` 取 `this.permissions()`）。
- B 的 link 端点取"物理 link 当前权限"作为上限 `ceiling`（`S/connected-hosts/link.ts:104-105`），并在 `S/websocket-server.ts:1790-1795` 对 hello 的 `sessionPermissions` 求交集。
  - 即 B 上的权限 = link principal 的权限 ∩ 调用方授权。
  - 调用方权限变化或恢复会关闭已有通道（`S/connected-hosts/session.ts` 的 `revoke()` `revoke()`；`S/websocket-server.ts:1938-1941`）。
- 现实中这个权限几乎是满的：`S/session-admission-auth.ts:15-33` 没有密码就是 principal `owner` + `OWNER_PERMISSIONS`；有密码也一样是 owner。
  - `D/permissions.md` 的 viewer/operator 预设只对配对出来的 principal 有意义。unix socket 目标没有密码（见第 4 节），所以 A 对 B 的 link 是 owner，没有"只读盒子"这种选项。
- 权限表：`D/permissions.md:15-25`；操作映射 `S/authorization/operation-permissions.ts:9-16`。
  - `hosts.list.request`: `daemon.read`
  - `hosts.add/update/remove.request`: `tunnel.manage`
  - `hosts.link.open` / `route.*`：不要求权限（null），靠内层 session 的 ceiling 约束。

### 2.3 谁能增删注册

- `tunnel.manage` 可以改 label、enabled、启用/禁用。
- 改连接、metadata、replaceIdentity、删除，需要是该条目 source 的生产者，或有 `access.manage`（`S/connected-hosts/index.ts:168-176`、`:214-218`，`session.ts:97`）。
- 在默认单 owner 模型下，任何持有 A 的 owner 会话（含 A 上 agent 通过 MCP 或 SDK）都满足。

## 3. 隔离

### 3.1 验证"不能选第二跳"和"保存 host 不授予反向访问"

- 第二跳：
  - B 侧：`S/connected-hosts/link.ts:94-97` 对已经 routed 的会话收到 `hosts.link.open` 直接返回 `unsupported_capability: Connected hosts support one hop`。
  - A 侧：`S/connected-hosts/session.ts` 的 `handle()`（约 :73-80） 在 `routed()` 会话上拒绝所有 `hosts.route.*`。
  - 因此从 B 的虚拟 session 看到的 B 自己的 connected hosts，不能被再路由。
  - app 发现也只在非 routed profile 上做（`APP/runtime/host-runtime.ts:2463`）。
- 反向访问：
  - link 是 A 的 client 主动连 B，B 侧没有任何持有 A 凭据或 socket 的组件。
  - B 上的 `ConnectedHosts` 只有 B 自己 `hosts.json` 里的条目。`hosts.json` 在各 daemon 的 PASEO_HOME 里，A 的不会同步给 B。
  - 虚拟 session 带 `routed: true`、`producer: {serverId: A, sourceId}`（`index.ts:528-532`），B 将其来源记为 `route:<B principal>:<A serverId>:<A producer>`（`S/websocket-server.ts:1980-1990`），使 A 经 B 注册的任何东西都属于该命名空间，不会冒充 B 的直接 consumer。
- 盒子之间：盒子只在 A 的 `hosts.json` 里有目标，彼此没有链路。若 A 的 owner 想让 box1 指挥 box2，需要显式把 box2 注册到 box1，这不会自动发生。

### 3.2 盒子内 agent 能否经 MCP 触达其它主机

- MCP 工具 `list_hosts`、`create_agent(serverId)`、`create_workspace(serverId)`、`send_agent_prompt` 等（`S/agent/tools/paseo-tools.ts:1366-1376`，`S/agent/host-operations/index.ts:80-175`）使用的是"所在 daemon 的 ConnectedHosts"，权限固定为 `OWNER_PERMISSIONS`（`index.ts:101`）。
- 对盒子里的 agent，所在 daemon 是 B，B 的 `hosts.json` 默认为空，所以 `list_hosts` 只返回自己，不能指向 A 或其它盒子。
- 注意相反方向：A 上的 agent 通过 `serverId` 能操纵所有已注册盒子，且权限是 owner。host 上的 agent 因此是盒子的特权主体，这是预期设计，但意味着 host 侧 agent 不属于隔离边界之内。
- 盒子内 agent 若能连到 B 的 socket 并发 `hosts.add`，只能添加 B 的网络命名空间里可达的目标。当盒子无网络且不挂载 A 的 socket 时没有实际效果。需要保证 B 的 unix socket 以外不暴露 host 的 socket 或 TCP 端口。
- 重要副作用：MCP 注入只在 TCP 监听时才有。
  - `S/bootstrap.ts:274-283` `createAgentMcpBaseUrl` 在 listen 不是 tcp 时返回 null；`:285-294` 终端活动上报 URL 同样。
  - 即仅监听 unix socket 的 B，其 agent 得不到 `/mcp/agents`（agent 看不到 paseo MCP 工具）。终端 needs-input/running 活动上报也失效。
  - 若要这些能力，需盒子内另开 loopback TCP 监听（`PASEO_LISTEN` 只支持单个监听；是否能多监听未确认），此时盒子内进程都能打到该 TCP 口，该口同样是 owner 权限无密码，需注意盒子内同一网络命名空间的信任。

## 4. 本地 socket 目标语法

- 解析：`packages/protocol/src/host-target.ts:25-80` `parseHostTarget`。
  - unix socket：以 `unix://`、`pipe://`、`/`、`~`、`\\.\pipe\` 开头。
  - `unix:///run/boxes/x.sock` 和 `/run/boxes/x.sock` 都行，描述为 `unix://<path>`，URL 变为 `ws+unix://<path>:/ws`。
  - `~` 在客户端展开成 home（`packages/client/src/node/index.ts:76`）。
- 密码：只有 ssh（`?password=`）、tcp、ws(s)、relay 目标解析 password。unix/pipe 分支不产生 `password` 字段，所以 socket 目标无法携带密码。
  - 若 B 设了密码，A 的 link 会 `authentication_failed`（`S/connected-hosts/index.ts:344`、`:428-429`、`:449-450`、`:535-541`）。
  - 因此 B 必须无密码，安全依赖 socket 文件权限和 mount 范围。
- 身份固定：
  - 首次连上后记录 `serverId`（`index.ts:260-268`），之后不一致 -> `server_id_mismatch`，状态 error。
  - 重建盒子若 PASEO_HOME 持久，`$PASEO_HOME/server-id` 保持（`S/server-id.ts:35-75`）。若新建 home，serverId 随机（`srv_` + 12 位）。
  - 可用环境变量 `PASEO_SERVER_ID` 固定盒子身份（`S/server-id.ts:35-49`），首次写入文件后一直生效。
  - 恢复路径：`paseo --host A host update <registrationId> --connection <新目标> --replace-identity`（`P/cli.md` Connected hosts 段；`index.ts:178-181`），或 remove 再 add。
  - app 侧：新 serverId 会作为新 host 出现，旧 serverId 的 routed profile 变成离线残留，需手动删除。
- 同一 B 重复注册：`duplicate_host`；A 指向 A 自己：`self_host`（`index.ts:274-294`）。
- 不可达的目标会保存并自动重试（`P/cli.md:84-85`）；注册可在 B 的 socket 出现之前先做（`serverId` 此时为 null）。

## 5. 创建 workspace / 按需创建盒子

- 人在 app 创建 workspace 时选择 host（第 1.2 节）。盒子必须先存在、已注册并已被 A 学到 `serverId`，才会出现在 picker。
  - 所以"一个 workspace 对应一个盒子"的流程，不能靠 app 点"新建 workspace"自动拉起盒子，除非盒子预先建好。
- 插件钩子 `workspace.create.before/after`（`P/plugins/hooks.md:54-56`、`:103-137`）：
  - 运行在收到创建请求的那个 daemon（即 A）上，可以改请求（比如 source 种类）或在 after 里做事。
  - 不能把创建重定向到别的 daemon，workspace 仍会在 A 上创建。
  - 可以在 after 钩子里 `context.paseo.hosts.add(...)` + 起盒子，但 workspace 已在 A 上，不是盒子里。
- 可行的按需路径（未确认，需要实验）：
  - 主机端提供一个"新建盒子"入口（CLI 脚本、server 插件 RPC + 客户端 Command Center 动作，`P/plugins/reference.md:30-48`）。
  - 它建盒子，起 B，调用 `paseo.hosts.add({connection:"unix://...", sourceKey:"box-<id>"})`。
  - app 通过 `hosts.changed` 自动出现盒子，用户再在 picker 里选它创建 workspace。`sourceKey` 使重复 add 幂等（`index.ts:100-118`）。
- 插件 server 钩子对 connected hosts 的 actor 是 `plugin:<pluginId>`（`S/websocket-server.ts:1549`），属 source 所有者，可自行更新或删除自己的注册。

## 6. 限制与缺口

- 推送通知：app 向每个 host 自己的 client 注册 Expo token（`APP/contexts/session-context.tsx:255`、`APP/push-notifications/internal/subscriptions.ts`），推送由 token 所属 daemon 直接发到 `https://exp.host/--/api/v2/push/send`（`S/push/push-service.ts:24`、`S/push/index.ts:34-44`）。
  - 对 routed 盒子，token 被存到 B，B 自己发推送。B 无外网则永远没有推送，A 不会代发（未找到转发代码）。
  - 解决办法：给盒子放行到 exp.host 的出站，或自写推送转发（custom code）。
  - 另：token 租约 48 小时，靠 app 连接中续期，routed 连接同样续期（理论上，未确认）。
- 权限提示、unread/attention：这些是盒子 session 内的事件，经 routed 通道推给 app，与直连一致，仅在 app 在线并连着 A 时可见。`agent.permission.before` 等插件钩子运行在 B 而不是 A。
- A 离线（或 relay 断开）时整个 app 与所有盒子一起失联；routed 连接要求 origin 已连接（`host-runtime.ts:658-662`）。
- 容量限制：每 daemon 最多 128 个注册、128 个 channel、每调用方 32 个 route（`index.ts:142`、`:379`，`link.ts:101`，`session.ts:178`）。物理 link 缓冲 64 MiB（link.ts）。
- 每个盒子一条 A 的长连接并持续重试；盒子很多时 A 的开销线性增长。
- 版本要求：A、B 都要 >= 0.13，并宣告 `connectedHosts` 与 `hostMultiplexing`（`S/websocket-server.ts:2003-2004`）；盒子里的 paseo 版本要同步升级。
- 人不能在 app 里"隐藏"某个盒子而不在 A 上禁用/删除注册（app 删除会被重新发现）。
- A 的 `hosts.json` 含连接串与凭据（模式 0600，`index.ts:` persist）。socket 目标没有凭据，但路径本身暴露在其中。

## 7. 评估

route C（native connected hosts）能替代 route B 的自写代理：
- 传输、E2EE 终点（A）、多路复用、二进制帧、重连、serverId 固定、一跳限制、app 自动发现、侧栏聚合、host picker 全部原生可用。
- 需要的 daemon 侧改动很小：B 监听 unix socket、不设密码、`PASEO_SERVER_ID` 固定、A 上 `host add unix://...`。

仍需自写的部分：
1. 盒子生命周期编排：创建/销毁盒子容器、挂载 socket、调用 `hosts.add/remove`（可用 server 插件或外部脚本）。把"新建 workspace -> 新盒子"做成一步需要额外 UI（插件 Command Center 动作）或约定先建盒子。
2. 推送通知：盒子出站放行，或自写转发。
3. MCP 注入：仅 unix socket 监听时 agent 得不到 paseo MCP 与终端活动上报；需要盒子内 loopback TCP 或自己提供等价物。是否可以同时监听 unix + loopback TCP 未确认。
4. 权限收紧：单 owner 模型下无法给盒子只读/受限权限；A 上 agent 对盒子为 owner。隔离靠容器与 socket 挂载，不靠 Paseo 权限。
5. 注册清理：盒子销毁后 A 上要 `host rm`；app 里残留的旧 routed profile 需用户手动删除。
6. `workspace-script-links` 的 service 链接对 routed host 会给出错误的 localhost URL，可能需要补丁（未确认影响面）。

## 未确认清单

- A 是否记录盒子流量到日志。
- B 是否支持多个 `PASEO_LISTEN`（unix + loopback TCP）。
- 推送 token 续期在 routed 连接下的实际行为。
- service 脚本链接/服务代理（`APP/workspace-service-routes`）在 routed host 下的完整行为。
- 单 owner 以外（配对出的 principal 预设）在 B 上是否有可用的限权入口，OSS daemon 中 `resolveSessionAdmission` 只产生 owner。
