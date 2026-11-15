# Paseo 协议调研：route B（每盒子一个 daemon + 主机侧 proxy 冒充单个 daemon）

调研对象：上游 `getpaseo/paseo`（getpaseo/paseo，tag v0.15.4，对比 v0.11.0 ~ v0.15.4）。
只读分析；所有行号对应 v0.15.4，除非另注。"未确认"表示没有从源码直接证实。

## 0. 结论速览

- 协议权威定义只有一处：`packages/protocol/src/messages.ts`（7853 行，zod）。`packages/server/src/server/messages.ts` 只是 `export *` 再加几个序列化函数。扩展 RPC 的 schema 分布在 `hosts.ts`、`chat/rpc-schemas.ts`、`schedule/rpc-schemas.ts`、`loop/rpc-schemas.ts`、`speech/rpc-schemas.ts`、`browser-automation/rpc-schemas.ts`。
- 客户端→daemon：4 种顶层 WS 信封 + **219 种** session 请求/消息（`SessionInboundMessageSchema`，messages.ts:3283）；daemon→客户端：3 种顶层信封 + **238 种** session 消息（`SessionOutboundMessageSchema`，messages.ts:7033）。
- 219 个入站类型的分类统计：per-agent 28、per-path/workspace 72、global 62、create 9、other 31、可安全拒绝 17。（详见 §2）
- 难点不在"路由键"，而在**状态化的东西**：终端二进制帧的 slot（per-connection）、per-daemon 的目录同步游标（generation/seq）、订阅 id、reverse RPC（浏览器自动化）、HTTP 带外下载、文件上传、语音/听写会话、cwd 路径空间冲突。（§2.2、§3）
- 兼容性：daemon 对未知请求返回 `rpc_error{code:"unknown_schema"}`（websocket-server.ts:2431-2455），proxy 按此格式拒绝，客户端只会让该请求 reject（`DaemonRpcError`），不会断连。但 app 的功能是靠 `server_info.features` 门控的，proxy 通过**少广告 feature** 比逐条拒绝更优雅。（§4）
- 协议 v0.11.0→v0.15.4（约 5 周、5 个 minor）：新增 13 个入站 + 14 个出站类型，**0 删除**；其余是向后兼容的可选字段。协议版本号恒为 1，没有真正的版本协商，兼容靠"只增不改"+ feature flag。（§5）
- 值得注意：Paseo 本身已有一套"daemon 代理另一个 daemon"的机制（`hosts.*`、二进制 opcode 0x30 的 host route，docs/connected-hosts.md），route B 可以参考它的 channel 化设计，但 app 当前是把每个 daemon 当作独立 host，而不是在一个 daemon 里聚合。

## 1. 协议定义与传输

### 1.1 信封与握手

| 层 | 内容 | 位置 |
|---|---|---|
| WS 入站信封 | `ping`、`hello`、`recording_state`、`session`（包 `SessionInboundMessage`） | `messages.ts:7733-7810` |
| WS 出站信封 | `pong`、`session`（包 `SessionOutboundMessage`）、`hello.rejected` | `messages.ts:7733-7816` |
| hello | `clientId`、`clientType`(mobile/browser/cli/mcp/hub)、`protocolVersion`、`auth`(password / localCredential)、`appVersion`、`capabilities`(passthrough)、`routed`、`producer`、`sessionPermissions` | `messages.ts:7741` |
| 握手回包 | 没有单独的 welcome；daemon 发一条 `status` 消息，payload.status=`server_info`（serverId、hostname、version、features、capabilities、protocolVersion…） | `messages.ts:3659`；docs/architecture.md "Handshake" |
| 传输 | WS 路径 `/ws`（`websocket-server.ts:883`）；daemon 可 `listen` 在 `unix://` 套接字（`bootstrap.ts:61`）；文档说明非 TCP 时跳过 Host 校验（bootstrap.ts:780） | |
| 保活 | 客户端每 10s 发顶层 JSON `ping`（不是 session 的 `ping`），daemon 有租约，过期强制断开 | docs/architecture.md |
| 限制 | 出站高水位 8 MiB，超出强制断开该 socket；单消息上限 100 MiB | docs/architecture.md；`chunked-transport.ts` |

proxy 要点：session 与 hello 信封要在 proxy 终结（自己跑 hello/auth/server_info），对每个盒子 daemon 开一条（或每 client 一条）上游 socket；proxy 的 `server_info.features` 应取各盒子的交集再删掉不想支持的项（见 §4）。daemon 支持"一个逻辑 session 多个物理 socket"，同 `clientId` 可复用。

### 1.2 二进制帧（`packages/protocol/src/binary-frames/`）

| 类别 | opcode | 布局 | 路由键 | 位置 |
|---|---|---|---|---|
| 终端流 | Output 0x01 / Input 0x02 / Resize 0x03 / Snapshot 0x04 / Restore 0x05 / ReplayBegin 0x06 / ReplayData 0x07 / ReplayEnd 0x08 | `[opcode][slot][payload]` | **slot**（0..255，per-connection；由 `subscribe_terminal_response.payload.slot` 分配，messages.ts:6645） | `terminal.ts:16-25` |
| 文件传输 | FileBegin 0x10 / FileChunk 0x11 / FileEnd 0x12 | `[opcode][requestIdLen][requestId][body]`，Begin 的 body 有 u16 元数据长度 + JSON | **requestId** | `file-transfer.ts:4-60,100-128` |
| host route | 0x30 | `[0x30][u16 len][routeId][内层帧]`，内层帧原样不重编码 | routeId | `host-route.ts:1-40` |
| 分块 | 0x31 | `[0x31][version=1][origKind][flags START/END][slice]`，无总长/块数，不可交错 | 连接级 | `chunked-transport.ts:8`；docs/protocol-compatibility.md "Binary chunking" |

- 分发由 `decodeBinaryFrame`（`demux.ts:16-`）按首字节完成，终端流与文件传输的 opcode 值域不重叠。
- 终端 slot 是 per-connection 的小整数：proxy 同时代理多个盒子时，**各盒子的上游连接都会从 0 开始分配 slot，必然冲突**，proxy 需要重映射 slot（对客户端暴露自己的 slot 表，上游盒子用各自的），并在 `subscribe_terminal_response` 里改写 slot 字段、在每个二进制帧里改写第二字节。
- 文件下载有两条通道：(a) WS 二进制 FileBegin/Chunk/End（`file_explorer_request` 且 `acceptBinary`，`workspace-files-session.ts:302-326`）；(b) `file_download_token_request` 取 token，然后 **HTTP** `GET /api/files/download?token=`（`bootstrap.ts:924`，token 存内存、默认 60s TTL，bootstrap.ts:699-702）。文件上传：`file.upload.request`（无路由键）后由客户端发 FileBegin/Chunk/End（`file-upload/index.ts:110-114`），响应里的 `uploaded_file.path` 是 daemon 本地路径（messages.ts:1207）。
- 分块协商靠 hello capability `binary_chunking_v1`（`client-capabilities.ts`）与 `server_info.features.binaryChunkingV1`；proxy 可不广告，让两侧都退回单帧。注意"原生 App 禁用出站分块"（docs/protocol-compatibility.md）。

### 1.3 HTTP 侧通道（也要被 proxy 覆盖）

`bootstrap.ts`：`GET /api/health`(855)、`GET /api/status`(859)、`GET /api/files/download`(924，token)、`/mcp/agents`（POST/GET/DELETE，1610/1729，盒子内 agent 调用 daemon 的 MCP，属盒子内部，不需要经 app 的 proxy）、`/public` 静态、可选 serve web client、`serviceProxy.middleware()`（777，docs/service-proxy.md，未确认其行为是否经 app）。

## 2. 客户端→daemon 请求分类

### 2.1 方法与说明

- 分类依据：schema 里字段 + 服务端语义。表按类别分组，每行：type、路由键、备注、schema 位置（`file:line` 为该 schema 定义处）。
- "per-path/workspace" 类包含用 `cwd`、`repoRoot`、`worktreePath`、`projectId`、`workspaceId` 的请求。
- "other" = 无法只靠 agent/path 路由、也不能直接拒绝的请求（见 §2.3 的解释）。
- "可拒绝" = 在 `packages/app/src`、`packages/client/src`、`packages/cli/src` 中都找不到该 type 字符串引用（grep 确认），只有 server 内部/历史使用。注意 `chat/*`、`loop/*` 可能被 server 的 MCP 工具生成而不经客户端（未确认），但对 app 来说可拒绝。
- id 格式：agentId=UUID（`agent-manager.ts:804` 的 `randomUUID`）；workspaceId=`wks_`+16 hex、projectId=`prj_`+16 hex（`workspace-registry-model.ts:12-17`）；terminalId=UUID（`terminal-manager.ts:357`）；订阅 id=UUID（`owned-subscriptions/index.ts:296`）；scheduleId 为 daemon 本地（格式未确认）。
- 注意：多个"per-agent"请求的 agentId 接受"唯一前缀或完整标题"（messages.ts:1415-1420 注释；`fetch_agent_request`、`send_agent_message_request`、`wait_for_finish_request`），proxy 无法仅凭 UUID 表路由，需要广播解析。

### 2.2 全表（219 个）

#### 类别：per-agent（28 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `fetch_agent_request` | agentId | agentId 可为全 id/唯一前缀/完整标题(server 解析)，proxy 无法仅凭前缀路由，需向各盒子广播解析或维护全局索引 | `packages/protocol/src/messages.ts:1415` |
| `send_agent_message_request` | agentId | agentId 可为全 id/唯一前缀/完整标题(server 解析)，proxy 无法仅凭前缀路由，需向各盒子广播解析或维护全局索引 | `packages/protocol/src/messages.ts:1422` |
| `wait_for_finish_request` | agentId | agentId 可为全 id/唯一前缀/完整标题(server 解析)，proxy 无法仅凭前缀路由，需向各盒子广播解析或维护全局索引 | `packages/protocol/src/messages.ts:1438` |
| `delete_agent_request` | agentId |  | `packages/protocol/src/messages.ts:970` |
| `archive_agent_request` | agentId |  | `packages/protocol/src/messages.ts:976` |
| `update_agent_request` | agentId |  | `packages/protocol/src/messages.ts:989` |
| `refresh_agent_request` | agentId |  | `packages/protocol/src/messages.ts:1902` |
| `cancel_agent_request` | agentId |  | `packages/protocol/src/messages.ts:1908` |
| `fetch_agent_timeline_request` | agentId |  | `packages/protocol/src/messages.ts:1941` |
| `agent.timeline.search.request` | agentId |  | `packages/protocol/src/messages.ts:1957` |
| `agent.timeline.list_prompts.request` | agentId |  | `packages/protocol/src/messages.ts:1965` |
| `agent.fork_context.request` | agentId |  | `packages/protocol/src/messages.ts:1993` |
| `set_agent_mode_request` | agentId |  | `packages/protocol/src/messages.ts:2001` |
| `set_agent_model_request` | agentId |  | `packages/protocol/src/messages.ts:2021` |
| `set_agent_thinking_request` | agentId |  | `packages/protocol/src/messages.ts:2033` |
| `set_agent_feature_request` | agentId |  | `packages/protocol/src/messages.ts:2045` |
| `agent.config.apply.request` | agentId |  | `packages/protocol/src/messages.ts:2078` |
| `agent.detach.request` | agentId |  | `packages/protocol/src/messages.ts:2090` |
| `agent.rewind.request` | agentId |  | `packages/protocol/src/messages.ts:2103` |
| `agent_permission_response` | agentId |  | `packages/protocol/src/messages.ts:2236` |
| `agent.timeline.append.request` | agentId |  | `packages/protocol/src/messages.ts:1618` |
| `list_commands_request` | agentId |  | `packages/protocol/src/messages.ts:2992` |
| `agent.provider_subagents.list.request` | parentAgentId | provider 子 agent 的父 agent | `packages/protocol/src/messages.ts:1971` |
| `agent.provider_subagents.timeline.get.request` | parentAgentId | provider 子 agent 的父 agent | `packages/protocol/src/messages.ts:1977` |
| `close_items_request` | agentIds[] (多值) | 数组可跨盒子，proxy 需拆分/扇出并合并响应 | `packages/protocol/src/messages.ts:982` |
| `agent.timeline.set_subscription.request` | agentIds[] (多值) | 数组可跨盒子，proxy 需拆分/扇出并合并响应 | `packages/protocol/src/messages.ts:1987` |
| `clear_agent_attention` | agentId: string|string[] (多值) | agentId 可为数组 | `packages/protocol/src/messages.ts:2954` |
| `usage.list_reports.request` | agentId?(可选) | 有 agentId 则路由到 agent 所属盒子；无则按全局聚合（含 .update 流式更新 + .response） | `packages/protocol/src/messages.ts:1875` |

#### 类别：per-path/workspace（72 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `checkout_status_request` | cwd |  | `packages/protocol/src/messages.ts:2261` |
| `checkout.diff.get.request` | cwd |  | `packages/protocol/src/messages.ts:2275` |
| `subscribe_checkout_diff_request` | cwd | 同时带客户端自选 subscriptionId，proxy 须记录 subscriptionId→盒子 | `packages/protocol/src/messages.ts:2267` |
| `checkout_commit_request` | cwd |  | `packages/protocol/src/messages.ts:2287` |
| `checkout_merge_request` | cwd |  | `packages/protocol/src/messages.ts:2295` |
| `checkout_merge_from_base_request` | cwd |  | `packages/protocol/src/messages.ts:2304` |
| `checkout_pull_request` | cwd |  | `packages/protocol/src/messages.ts:2312` |
| `checkout_push_request` | cwd |  | `packages/protocol/src/messages.ts:2318` |
| `checkout.refresh.request` | cwd |  | `packages/protocol/src/messages.ts:2324` |
| `checkout.discard_changes.request` | cwd |  | `packages/protocol/src/messages.ts:2330` |
| `checkout_pr_create_request` | cwd |  | `packages/protocol/src/messages.ts:2337` |
| `checkout_pr_merge_request` | cwd |  | `packages/protocol/src/messages.ts:2346` |
| `checkout.forge.set_auto_merge.request` | cwd |  | `packages/protocol/src/messages.ts:2353` |
| `checkout.github.set_auto_merge.request` | cwd |  | `packages/protocol/src/messages.ts:2364` |
| `checkout.commits.list.request` | cwd |  | `packages/protocol/src/messages.ts:2391` |
| `checkout.commits.file_diff.request` | cwd |  | `packages/protocol/src/messages.ts:2397` |
| `checkout.forge.get_check_details.request` | cwd |  | `packages/protocol/src/messages.ts:2427` |
| `checkout.github.get_check_details.request` | cwd |  | `packages/protocol/src/messages.ts:2435` |
| `checkout_pr_status_request` | cwd |  | `packages/protocol/src/messages.ts:2440` |
| `pull_request_timeline_request` | cwd |  | `packages/protocol/src/messages.ts:2446` |
| `checkout_switch_branch_request` | cwd |  | `packages/protocol/src/messages.ts:2462` |
| `checkout.rename_branch.request` | cwd |  | `packages/protocol/src/messages.ts:2469` |
| `stash_save_request` | cwd |  | `packages/protocol/src/messages.ts:2476` |
| `stash_pop_request` | cwd |  | `packages/protocol/src/messages.ts:2484` |
| `stash_list_request` | cwd |  | `packages/protocol/src/messages.ts:2492` |
| `validate_branch_request` | cwd |  | `packages/protocol/src/messages.ts:2455` |
| `branch_suggestions_request` | cwd |  | `packages/protocol/src/messages.ts:2500` |
| `forge.search.request` | cwd |  | `packages/protocol/src/messages.ts:2540` |
| `github_search_request` | cwd |  | `packages/protocol/src/messages.ts:2552` |
| `file_explorer_request` | cwd | mode=file 且 acceptBinary 时返回二进制 FileBegin/Chunk/End 帧(按 requestId) | `packages/protocol/src/messages.ts:2833` |
| `fs.file.subscribe.request` | cwd | 同时带客户端自选 subscriptionId，proxy 须记录 subscriptionId→盒子 | `packages/protocol/src/messages.ts:2869` |
| `fs.file.write.request` | cwd |  | `packages/protocol/src/messages.ts:2883` |
| `fs.entry.create.request` | cwd |  | `packages/protocol/src/messages.ts:2895` |
| `fs.entry.rename.request` | cwd |  | `packages/protocol/src/messages.ts:2904` |
| `fs.entry.duplicate.request` | cwd |  | `packages/protocol/src/messages.ts:2912` |
| `fs.entry.delete.request` | cwd |  | `packages/protocol/src/messages.ts:2919` |
| `project_icon_request` | cwd |  | `packages/protocol/src/messages.ts:2926` |
| `file_download_token_request` | cwd | 返回的 token 在 HTTP GET /api/files/download?token=... 上使用(带外通道)，proxy 须记录 token→盒子 | `packages/protocol/src/messages.ts:2938` |
| `subscribe_terminals_request` | cwd | 另有可选 workspaceId | `packages/protocol/src/messages.ts:3028` |
| `unsubscribe_terminals_request` | cwd | 另有可选 workspaceId | `packages/protocol/src/messages.ts:3035` |
| `read_project_config_request` | repoRoot |  | `packages/protocol/src/messages.ts:1695` |
| `write_project_config_request` | repoRoot |  | `packages/protocol/src/messages.ts:1701` |
| `paseo_worktree_list_request` | cwd / repoRoot / worktreePath |  | `packages/protocol/src/messages.ts:2572` |
| `paseo_worktree_archive_request` | cwd / repoRoot / worktreePath |  | `packages/protocol/src/messages.ts:2579` |
| `create_paseo_worktree_request` | cwd + projectId | 在已有仓库上创建 worktree/workspace；路由到仓库所属盒子，响应里的新 workspaceId 要登记路由 | `packages/protocol/src/messages.ts:2608` |
| `project.rename.request` | projectId | prj_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1004` |
| `project.icon.set.request` | projectId | prj_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1012` |
| `project.remove.request` | projectId | prj_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1019` |
| `project.icon.get.request` | projectId | prj_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:2932` |
| `workspace.title.set.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1025` |
| `workspace.pin.set.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1033` |
| `workspace.recovery.inspect.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1086` |
| `workspace.recovery.restore.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:1092` |
| `workspace_setup_status_request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:2626` |
| `workspace.setup.subscribe.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:2632` |
| `workspace.setup.run.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:2638` |
| `archive_workspace_request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:2709` |
| `start_workspace_script_request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:3069` |
| `workspace.script.list.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:3076` |
| `workspace.script.start.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:3082` |
| `workspace.script.stop.request` | workspaceId | wks_<16hex>，daemon 生成 | `packages/protocol/src/messages.ts:3089` |
| `workspace.clear_attention.request` | workspaceId: string|string[] (多值) | 数组可跨盒子 | `packages/protocol/src/messages.ts:2764` |
| `workspace.mark_unread.request` | workspaceId: string|string[] (多值) | 数组可跨盒子 | `packages/protocol/src/messages.ts:2770` |
| `workspace.label.assignment.set.request` | workspaceId (+label) | label 目录是 daemon 本地的；仅 assignment 带 workspaceId | `packages/protocol/src/messages.ts:1056` |
| `list_provider_models_request` | draftConfig.cwd / cwd | provider 模型/模式/功能随项目配置而变；cwd 缺省可当全局 | `packages/protocol/src/messages.ts:1830` |
| `list_provider_modes_request` | draftConfig.cwd / cwd | provider 模型/模式/功能随项目配置而变；cwd 缺省可当全局 | `packages/protocol/src/messages.ts:1837` |
| `list_provider_features_request` | draftConfig.cwd / cwd | provider 模型/模式/功能随项目配置而变；cwd 缺省可当全局 | `packages/protocol/src/messages.ts:2986` |
| `get_providers_snapshot_request` | cwd?(可选) | 带 cwd 路由，不带则聚合；ifNoneMatch 为 per-daemon ETag，聚合后需 proxy 自造 | `packages/protocol/src/messages.ts:1849` |
| `refresh_providers_snapshot_request` | cwd?(可选) | 带 cwd 路由，不带则聚合；ifNoneMatch 为 per-daemon ETag，聚合后需 proxy 自造 | `packages/protocol/src/messages.ts:1857` |
| `fetch_recent_provider_sessions_request` | cwd?(可选) | 带 cwd 路由，否则聚合 | `packages/protocol/src/messages.ts:1405` |
| `list_terminals_request` | terminalId→盒子表 或 cwd/workspaceId | cwd/workspaceId 均缺省时为全局聚合；响应里的 terminalId 须登记 | `packages/protocol/src/messages.ts:3021` |
| `create_terminal_request` | cwd (+workspaceId, agentId?) | 在已有 workspace 内建终端；响应中 terminalId 须登记 | `packages/protocol/src/messages.ts:3041` |

#### 类别：create（9 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `create_agent_request` | config.cwd / workspaceId? | proxy 必须选择或新建盒子；客户端可预先指定 agentId(仅 agent.create，uuid)与 workspaceId(wks_ 正则)，可用来让 proxy 掌握 id | `packages/protocol/src/messages.ts:1773` |
| `agent.create.request` | config.cwd / workspaceId? | proxy 必须选择或新建盒子；客户端可预先指定 agentId(仅 agent.create，uuid)与 workspaceId(wks_ 正则)，可用来让 proxy 掌握 id | `packages/protocol/src/messages.ts:1804` |
| `workspace.create.request` | source.kind=directory→path; source.kind=worktree→cwd/projectId | directory 源需 proxy 新建/选盒子；worktree 源路由到仓库盒子；可带 agent 初始 agent 配置、idempotencyKey | `packages/protocol/src/messages.ts:2718` |
| `resume_agent_request` | handle(provider 会话句柄) + overrides.cwd | 恢复一个已持久化的 provider 会话；目标盒子须能找到该会话文件 | `packages/protocol/src/messages.ts:1883` |
| `import_agent_request` | cwd?/workspaceId?/sessionId | 导入 provider 会话为 agent | `packages/protocol/src/messages.ts:1890` |
| `open_project_request` | cwd | 把主机目录注册为 project；盒子的目录挂载由 proxy 决定 | `packages/protocol/src/messages.ts:2659` |
| `project.add.request` | cwd | 把主机目录注册为 project；盒子的目录挂载由 proxy 决定 | `packages/protocol/src/messages.ts:2669` |
| `project.create_directory.request` | parentPath+name | 在文件系统创建目录(无盒子时的主机路径) | `packages/protocol/src/messages.ts:2675` |
| `project.github.clone.request` | targetDirectory | git clone 到目录并注册为 project | `packages/protocol/src/messages.ts:2701` |

#### 类别：global（62 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `fetch_agents_request` | — | 聚合各盒子结果；daemon 为每实体维护 per-daemon 的 generation/seq/syncSeq 游标(见 §3.3)，proxy 必须自造全局游标 | `packages/protocol/src/messages.ts:1291` |
| `fetch_workspaces_request` | — | 聚合各盒子结果；daemon 为每实体维护 per-daemon 的 generation/seq/syncSeq 游标(见 §3.3)，proxy 必须自造全局游标 | `packages/protocol/src/messages.ts:1328` |
| `project.list.request` | — | 聚合各盒子结果；daemon 为每实体维护 per-daemon 的 generation/seq/syncSeq 游标(见 §3.3)，proxy 必须自造全局游标 | `packages/protocol/src/messages.ts:1366` |
| `fetch_agent_history_request` | — | 聚合；带 filter/search/分页 cursor，proxy 需重写 cursor | `packages/protocol/src/messages.ts:1382` |
| `project.suggestions.request` | — | 聚合 (provider 会话/目录建议类) | `packages/protocol/src/messages.ts:1373` |
| `directory_suggestions_request` | — | 聚合 (provider 会话/目录建议类) | `packages/protocol/src/messages.ts:2561` |
| `workspace.label.list.request` | — | 聚合/proxy 自答；label 目录 per-daemon，带 generation/seq，且有 subscribe/sync | `packages/protocol/src/messages.ts:1050` |
| `workspace.label.update.request` | — | 聚合/proxy 自答；label 目录 per-daemon，带 generation/seq，且有 subscribe/sync | `packages/protocol/src/messages.ts:1068` |
| `workspace.label.delete.request` | — | 聚合/proxy 自答；label 目录 per-daemon，带 generation/seq，且有 subscribe/sync | `packages/protocol/src/messages.ts:1075` |
| `workspace.label.delete.inspect.request` | — | 聚合/proxy 自答；label 目录 per-daemon，带 generation/seq，且有 subscribe/sync | `packages/protocol/src/messages.ts:1080` |
| `daemon.get_status.request` | — | proxy 自答（身份、状态、配对、config reload 都应指向 proxy 自身而不是某个盒子） | `packages/protocol/src/messages.ts:1446` |
| `daemon.get_pairing_offer.request` | — | proxy 自答（身份、状态、配对、config reload 都应指向 proxy 自身而不是某个盒子） | `packages/protocol/src/messages.ts:1451` |
| `daemon.config.reload.request` | — | proxy 自答（身份、状态、配对、config reload 都应指向 proxy 自身而不是某个盒子） | `packages/protocol/src/messages.ts:1456` |
| `diagnostics.request` | — | proxy 自答（身份、状态、配对、config reload 都应指向 proxy 自身而不是某个盒子） | `packages/protocol/src/messages.ts:1484` |
| `ping` | — | proxy 自答（身份、状态、配对、config reload 都应指向 proxy 自身而不是某个盒子） | `packages/protocol/src/messages.ts:2971` |
| `shutdown_server_request` | — | proxy 自答或拒绝；不要原样扇出，否则会重启/关闭/升级所有盒子 | `packages/protocol/src/messages.ts:1923` |
| `restart_server_request` | — | proxy 自答或拒绝；不要原样扇出，否则会重启/关闭/升级所有盒子 | `packages/protocol/src/messages.ts:1914` |
| `daemon.update.request` | — | proxy 自答或拒绝；不要原样扇出，否则会重启/关闭/升级所有盒子 | `packages/protocol/src/messages.ts:1931` |
| `get_daemon_config_request` | — | 配置是 per-daemon；写入需扇出到所有盒子或由 proxy 持有 | `packages/protocol/src/messages.ts:1684` |
| `set_daemon_config_request` | — | 配置是 per-daemon；写入需扇出到所有盒子或由 proxy 持有 | `packages/protocol/src/messages.ts:1689` |
| `list_available_providers_request` | — |  | `packages/protocol/src/messages.ts:1844` |
| `provider_diagnostic_request` | — |  | `packages/protocol/src/messages.ts:1864` |
| `provider.usage.list.request` | — |  | `packages/protocol/src/messages.ts:1870` |
| `plugin.catalog.get.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1489` |
| `plugin.list.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1498` |
| `plugin.logs.get.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1503` |
| `plugin.directory.install.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1509` |
| `plugin.directory.inspect.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1516` |
| `plugin.source.install.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1522` |
| `plugin.source.status.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1589` |
| `plugin.source.update.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1595` |
| `plugin.source.update.preview.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1577` |
| `plugin.source.update.apply.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1583` |
| `plugin.reload.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1605` |
| `plugin.enable.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1606` |
| `plugin.disable.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1607` |
| `plugin.remove.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1608` |
| `plugin.rpc.invoke.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1605` |
| `agent.skills.get_status.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1659` |
| `agent.skills.reconcile.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1662` |
| `agent.skills.uninstall.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1665` |
| `agent.skills.save_selection.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1659` |
| `agent.skills.import_legacy_selection.request` | — | host 级；plugin/skill 状态 per-daemon；plugin.rpc.invoke 带 pluginId，plugin 作为 daemon 内的受信代码运行(未确认是否能跨盒子) | `packages/protocol/src/messages.ts:1676` |
| `speech.local_models.list.request` | — | 主机级模型存储(app 设置页使用)；盒子内是否有语音栈未确认 | `packages/protocol/src/speech/rpc-schemas.ts:161` |
| `speech.local_models.download.request` | — | 主机级模型存储(app 设置页使用)；盒子内是否有语音栈未确认 | `packages/protocol/src/speech/rpc-schemas.ts:166` |
| `speech.local_models.delete.request` | — | 主机级模型存储(app 设置页使用)；盒子内是否有语音栈未确认 | `packages/protocol/src/speech/rpc-schemas.ts:172` |
| `register_push_token` | — | daemon 发 Expo 推送；token 需扇出到各盒子或由 proxy 统一推送 | `packages/protocol/src/messages.ts:2999` |
| `push.unregister.request` | — | daemon 发 Expo 推送；token 需扇出到各盒子或由 proxy 统一推送 | `packages/protocol/src/messages.ts:3004` |
| `workspace.github.search_repositories.request` | — | workspace GitHub 仓库搜索(需 gh 登录，主机级) | `packages/protocol/src/messages.ts:2692` |
| `hosts.list.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:39` |
| `hosts.add.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:44` |
| `hosts.update.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:49` |
| `hosts.remove.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:55` |
| `hosts.link.open.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:115` |
| `hosts.route.open.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:60` |
| `hosts.route.frame.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:66` |
| `hosts.route.close.request` | — | daemon 间托管主机目录；proxy 自答空目录并且不广告 server_info.features.connectedHosts / hostMultiplexing 即可 | `packages/protocol/src/hosts.ts:72` |
| `hub.management.daemon.connect.request` | — | daemon↔Hub 管理(app 未引用，未确认)；proxy 自答/拒绝 | `packages/protocol/src/messages.ts:1461` |
| `hub.management.daemon.get_status.request` | — | daemon↔Hub 管理(app 未引用，未确认)；proxy 自答/拒绝 | `packages/protocol/src/messages.ts:1468` |
| `hub.management.daemon.disconnect.request` | — | daemon↔Hub 管理(app 未引用，未确认)；proxy 自答/拒绝 | `packages/protocol/src/messages.ts:1472` |
| `hub.management.daemon.permissions.update.request` | — | daemon↔Hub 管理(app 未引用，未确认)；proxy 自答/拒绝 | `packages/protocol/src/messages.ts:1477` |
| `schedule/list` | — | 聚合各盒子的 schedule | `packages/protocol/src/schedule/rpc-schemas.ts:39` |

#### 类别：other（31 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `schedule/create` | target: {agent: agentId} 或 {new-agent: config.cwd} | target 决定路由；schedule 存在 daemon 内，盒子销毁则丢失 | `packages/protocol/src/schedule/rpc-schemas.ts:27` |
| `schedule/inspect` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:44` |
| `schedule/logs` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:50` |
| `schedule/pause` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:56` |
| `schedule/resume` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:62` |
| `schedule/delete` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:68` |
| `schedule/run-once` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:74` |
| `schedule/update` | scheduleId→盒子表 | id 为 daemon 本地；proxy 须登记 | `packages/protocol/src/schedule/rpc-schemas.ts:90` |
| `terminal.rename.request` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3062` |
| `subscribe_terminal_request` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3096` |
| `unsubscribe_terminal_request` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3114` |
| `terminal_input` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3136` |
| `kill_terminal_request` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3142` |
| `capture_terminal_request` | terminalId→盒子表 | terminalId=UUID(per-daemon)；proxy 从 list/create 响应学习映射；订阅后用二进制帧 slot | `packages/protocol/src/messages.ts:3148` |
| `subscription.release.request` | subscriptionId→盒子表 | 客户端或 daemon 生成的订阅 id，需 proxy 记账 | `packages/protocol/src/messages.ts:3273` |
| `unsubscribe_checkout_diff_request` | subscriptionId→盒子表 | 客户端或 daemon 生成的订阅 id，需 proxy 记账 | `packages/protocol/src/messages.ts:2282` |
| `fs.file.unsubscribe.request` | subscriptionId→盒子表 | 客户端或 daemon 生成的订阅 id，需 proxy 记账 | `packages/protocol/src/messages.ts:2877` |
| `session.events.set_subscription.request` | 连接级 | proxy 向所有盒子扇出并自答一次；用于选择接收哪些 status.* / project.update 等事件 | `packages/protocol/src/messages.ts:3251` |
| `creation.subscribe.request` | idempotencyKey | 恢复创建生命周期；key 来自之前的 create 请求，proxy 记 key→盒子 | `packages/protocol/src/messages.ts:1822` |
| `file.upload.request` | 无路由键 | binary FileBegin/Chunk/End 随后由客户端按 requestId 发出；响应的 uploaded_file.path 是盒子内路径，之后的 attachments 引用它 → proxy 需 暂存或登记 upload id→盒子 | `packages/protocol/src/messages.ts:2945` |
| `browser.automation.execute.response` | （reverse RPC）requestId | daemon→client 发 browser.automation.execute.request，客户端回此 response；proxy 需按 requestId 回送给发起盒子 | `packages/protocol/src/browser-automation/rpc-schemas.ts:510` |
| `browser.host.register.request` | 扇出 | 客户端(桌面)声明自己是 in-app 浏览器主机；需向所有盒子注册，并转发 daemon 发来的 execute.request | `packages/protocol/src/messages.ts:3262` |
| `client_heartbeat` | 扇出 | focusedAgentId/focusedTerminalId 只对所属盒子有意义，其余盒子置空；各盒子用它判断是否抑制推送 | `packages/protocol/src/messages.ts:2960` |
| `set_voice_mode` | 会话状态 / agentId? | 语音模式绑定一个 agent；后续 voice_audio_chunk/audio_played/abort_request 无 id，须 sticky 路由到该盒子；语音栈在盒子内未必存在 | `packages/protocol/src/messages.ts:1098` |
| `voice_audio_chunk` | 会话状态 / agentId? | 语音模式绑定一个 agent；后续 voice_audio_chunk/audio_played/abort_request 无 id，须 sticky 路由到该盒子；语音栈在盒子内未必存在 | `packages/protocol/src/messages.ts:942` |
| `audio_played` | 会话状态 / agentId? | 语音模式绑定一个 agent；后续 voice_audio_chunk/audio_played/abort_request 无 id，须 sticky 路由到该盒子；语音栈在盒子内未必存在 | `packages/protocol/src/messages.ts:953` |
| `abort_request` | 会话状态 / agentId? | 语音模式绑定一个 agent；后续 voice_audio_chunk/audio_played/abort_request 无 id，须 sticky 路由到该盒子；语音栈在盒子内未必存在 | `packages/protocol/src/messages.ts:949` |
| `dictation_stream_start` | dictationId(客户端生成) | 流式听写，sticky 到一个 speech-capable 后端 | `packages/protocol/src/messages.ts:1713` |
| `dictation_stream_chunk` | dictationId(客户端生成) | 流式听写，sticky 到一个 speech-capable 后端 | `packages/protocol/src/messages.ts:1719` |
| `dictation_stream_finish` | dictationId(客户端生成) | 流式听写，sticky 到一个 speech-capable 后端 | `packages/protocol/src/messages.ts:1727` |
| `dictation_stream_cancel` | dictationId(客户端生成) | 流式听写，sticky 到一个 speech-capable 后端 | `packages/protocol/src/messages.ts:1733` |

#### 类别：可拒绝（17 个）

| type | 路由键 | 备注 | schema |
|---|---|---|---|
| `chat/create` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:6` |
| `chat/list` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:13` |
| `chat/inspect` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:18` |
| `chat/delete` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:24` |
| `chat/post` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:30` |
| `chat/read` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:39` |
| `chat/wait` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/chat/rpc-schemas.ts:48` |
| `loop/run` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/loop/rpc-schemas.ts:89` |
| `loop/list` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/loop/rpc-schemas.ts:111` |
| `loop/inspect` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/loop/rpc-schemas.ts:116` |
| `loop/logs` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/loop/rpc-schemas.ts:122` |
| `loop/stop` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/loop/rpc-schemas.ts:129` |
| `list_available_editors_request` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/messages.ts:2645` |
| `open_in_editor_request` | — | 仅 server MCP/内部使用，现有 app/CLI/client 包中无引用（grep 确认） | `packages/protocol/src/messages.ts:2650` |
| `hub.execution.agent.create.request` | — | daemon↔Hub 执行通道，需 hub 权限，无已发布客户端 | `packages/protocol/src/messages.ts:3157` |
| `hub.execution.agent.validate.request` | — | daemon↔Hub 执行通道，需 hub 权限，无已发布客户端 | `packages/protocol/src/messages.ts:3179` |
| `hub.execution.control.request` | — | daemon↔Hub 执行通道，需 hub 权限，无已发布客户端 | `packages/protocol/src/messages.ts:3221` |
### 2.3 "other" 类的原因（不可简单拒绝，也不能按 agent/path 路由）

1. **per-terminal（6 个）**：`terminal.rename.request`、`subscribe_terminal_request`、`unsubscribe_terminal_request`、`terminal_input`、`kill_terminal_request`、`capture_terminal_request` 只带 `terminalId`，没有 cwd/agent。proxy 必须从 `list_terminals_response` / `create_terminal_response` / `terminals_changed` 学习 `terminalId→box`，且 `subscribe_terminal` 还要建立 slot 映射。
2. **订阅型**：`subscription.release.request`、`unsubscribe_checkout_diff_request`、`fs.file.unsubscribe.request` 只带订阅 id；`session.events.set_subscription.request` 是连接级的事件选择，必须扇出到所有盒子。proxy 需要 `subscriptionId→box`。
3. **file.upload.request**：无任何路由键，之后客户端用二进制帧推文件内容；盒子内路径随后被 `attachments[uploaded_file]` 引用。proxy 要么自己暂存（在主机）并在 create/send 时转存进目标盒子，要么先选定盒子。
4. **browser.host.register.request / browser.automation.execute.response**：反向 RPC。盒子内 daemon 发出 `browser.automation.execute.request`（出站，带 agentId/cwd/workspaceId，`browser-automation/rpc-schemas.ts:498`），客户端按 requestId 回 response（入站）。proxy 需要扇出 register，并按 requestId 把 response 路由回发起盒子。
5. **语音/听写**（`set_voice_mode`、`voice_audio_chunk`、`audio_played`、`abort_request`、`dictation_stream_*`）：会话状态化，音频块无 id。语音 agent 在盒子里还需要语音栈；方案要么 sticky 路由，要么 proxy 本地处理，要么不广告 `capabilities.voice`（`ServerCapabilities.voice`，messages.ts:3618）。
6. **client_heartbeat**：必须扇出（各盒子靠它判断 app 是否在前台以决定是否推送）；`focusedAgentId`/`focusedTerminalId` 只对所属盒子保留。
7. **creation.subscribe.request**：按 `idempotencyKey` 恢复创建流程，key 来自先前的 create 请求；proxy 要记 `key→box`。
8. **schedule/\***：schedule 存在 daemon 的存储里；`schedule/create` 取决于 `target`，其余按 scheduleId 查表。app 有 schedules 界面（`screens/schedules-screen.tsx`），所以不能一拒了之。若盒子是一次性的，schedule 随盒子消失，语义需要另行决定。

### 2.4 全局类里需要注意的几点

- `fetch_agents_request`/`fetch_workspaces_request`/`project.list.request` 的响应带 `sync`（generation、headSeq、removals、mode）；每个实体行有 `syncSeq`；后续的 `agent_update`/`workspace_update`/`project.update` 带 `generation`+`seq`（messages.ts:1271-1290, 4220-4250）。这些游标是 **per-daemon 单调序列**，proxy 必须自造"全局 generation + 序列"（最简单：每次都回 `mode:"snapshot"`, `reason:"generation_changed"`，并改写后续 update 的 seq），否则 app 的 `runtime/directory-sync` 会出现游标倒退/错乱。
- `get_providers_snapshot_request` 的 `ifNoneMatch` 是 per-daemon 的 ETag。
- `daemon.get_status`、`get_pairing_offer`（relay 配对二维码）、`restart/shutdown/update` 都应由 proxy 自答，而不是转发/扇出。
- 全局类的写操作（`set_daemon_config_request`、plugin 安装、skills 保存）需决定：只改 proxy 持有的配置，还是扇出到所有盒子。

## 3. daemon→客户端消息

### 3.1 出站总览

238 个出站类型中约 190 个是请求对应的 `*_response`（payload.requestId 关联，`rpc_error` 作为通用失败回包，messages.ts:3909），其余为推送/事件：

| 推送/事件 | 携带的 id | 位置 | proxy 处理 |
|---|---|---|---|
| `agent_update`（upsert/remove） | `payload.agent.id`、`agent.workspaceId?`、`agent.cwd`；remove 带 `agentId`；`subscriptionId`、`generation`、`seq` | messages.ts:4228 | 合并流；改写 generation/seq；记 agent→盒子 |
| `agent_stream` | `agentId`、`subscriptionId`；timeline 事件带 per-agent seq/epoch | 4249 | 按 agentId 转发，无合并问题 |
| `agent_status` | `agentId`、requestId、`agent`（含 agent_created 等） | 4262, 3930-3981 | 同上 |
| `agent.timeline.replacement` | agentId | 4814 | 直通 |
| `agent.provider_subagents.update` | parentAgentId、subagentId | 4935 | 直通 |
| `agent_permission_request/resolved` | agentId | 5327/5336 | 直通 |
| `agent_deleted` / `agent_archived` | agentId | 5346/5354 | 直通 + 更新路由表 |
| `agent_attention_required` | agentId、**serverId**、workspaceId、subscriptionId | 4972 | 改写 serverId 为 proxy 的 serverId |
| `workspace_update`（upsert/remove） | `workspace.id`、`removedProjectId`、generation/seq | 4390 | 合并流；改写序列 |
| `project.update` | projectId、generation/seq | 4486 | 同上 |
| `workspace.label.update` | label 名；generation/seq（独立序列） | 4435 | 需要合并 label 目录 |
| `script_status_update`、`workspace_setup_progress` | workspaceId | 4533/4542 | 按 workspaceId 直通 |
| `workspace.create.update` / `agent.create.update` | 创建生命周期；idempotencyKey/ids | 5053/5057 | 直通 + 登记路由 |
| `terminals_changed` | cwd、workspaceId、terminals[].id | 6611 | 合并；登记 terminalId→盒子 |
| `terminal_stream_exit` | terminalId、subscriptionId | 6677 | 要映射 slot/订阅 |
| `terminal_attention_required` | terminalId、cwd、workspaceId、**serverId** | 6687 | 改写 serverId |
| `checkout_status_update`、`checkout_diff_update`、`fs.file.update` | cwd、subscriptionId | 5584/5618/6258 | 按订阅 id 直通 |
| `providers_snapshot_update` | cwd?、subscriptionId | 6379 | 合并/去重 |
| `usage.list_reports.update` | requestId | 6523 | 直通 |
| `hosts.changed`/`hosts.route.*` | — | `hosts.ts` | proxy 自答 |
| `browser.automation.execute.request` | agentId?、cwd?、workspaceId?、requestId | `browser-automation/rpc-schemas.ts:498` | reverse RPC，需 requestId 路由表 |
| `activity_log`、`assistant_chunk`、`audio_output`、`transcription_result`、`voice_input_state`、`dictation_stream_*` | groupId/dictationId | 3521-3601 | 语音链路，sticky |
| `status`（server_info 之外还有 `daemon_config_changed`、`plugin_catalog_changed`、`plugin_settings_changed`、`restart_requested`…） | — | 3890, 3659, 3970-3981 | proxy 自己产生，盒子的 status 事件不应直通 |
| `hub.execution.agent.update/stream`、`daemon.update.progress` | — | 6766/6776/6715 | 不支持 |
| `pong`、`artifact` | — | 3899, 4000 | |

### 3.2 全局快照（需要 proxy 合并）

- `fetch_agents_response.entries[]`（4310）、`fetch_workspaces_response.entries[]` + `emptyProjects`（4371）、`project.list.response.projects[]`（4506）：全量 + 每实体 `syncSeq` + `sync` 元数据。
- `get_providers_snapshot_response` / `providers_snapshot_update`（6364/6379）：按 cwd。
- `workspace.label.list.response`（4426）：label 目录，独立序列；docs/architecture.md 说明跨 host 不同步，所以各盒子的 label 目录会各不相同。
- `fetch_agent_history_response`（4321）与 `fetch_recent_provider_sessions_response`（4332）：分页 + 排序，需要 proxy 在聚合时重写 cursor。
- `list_terminals_response`（6602）、`schedule/list/response`、`plugin.list.response`、`daemon.get_status.response`（5155，含 pid/serverId/nodePath，必须自答）。
- `server_info`（3659）：serverId 是 daemon 持久化的唯一 id（`server-id.ts`）。proxy 要给 app 一个稳定的单一 serverId；盒子 daemon 的 serverId 会出现在 `agent_attention_required.serverId`、`terminal_attention_required.serverId`、`send_agent_message_request.sourceAgentServerId`、`daemon.get_status`，需改写。

### 3.3 id 碰撞风险

- agentId/terminalId 为 `randomUUID()`，workspaceId/projectId 为 64 位随机 hex：**跨盒子实际碰撞概率可忽略**。
- 但不是全部由 daemon 生成：`agent.create.request.agentId`（`z.uuid().optional()`）与 `workspace.create.request.workspaceId`（`/^wks_[a-f0-9]{16}$/`，messages.ts:2718-2724）可由客户端指定；proxy 可借此统一分配 id。
- **同一仓库/同一路径在多个盒子**：projectId 由 daemon 随机生成（`workspace-registry.ts:391,429`；按路径归并的细节未确认），不同盒子对同一 `projectRootPath`（如 `/workspace`）会出现不同 projectId 但相同路径；cwd 作路由键会歧义。app 的 `projectKeys` 过滤、`projectRootPath` 展示也会撞。需要在 proxy 里做路径命名空间（给 cwd 加盒子前缀并双向改写）或保证每个盒子的路径唯一。
- 序列/generation/ETag 是 per-daemon，不可直通（§2.4）。
- 订阅 id 是 UUID，不碰撞，但必须记录归属盒子才能路由 `subscription.release.request` 等。
- 终端 slot（0..255）是 per-connection，**一定碰撞**（§1.2）。
- requestId 是客户端生成，proxy 向上游转发时最好保持原值（响应按 requestId 关联），若同一请求要扇出到多个盒子则 proxy 要为各上游重新编号并合并。

## 4. 版本协商、能力与错误处理

- **版本号**：`WS_PROTOCOL_VERSION = 1`（`websocket-server.ts:515`），仅检查 `protocolVersion < 1` 才拒绝（1747-1757）。`server_info.protocolVersion` 可选；`hello.rejected`（reason: password_required/incorrect_password/incompatible_protocol）仅对声明 `hello_rejection` 能力或带 auth 的客户端发送（docs/protocol-compatibility.md）。**实际上没有版本协商，版本号恒为 1**。
- **能力机制**：(a) 客户端 hello.capabilities（`client-capabilities.ts` 的 `CLIENT_CAPS`；v0.11→v0.15 新增 `terminalChunkedReplay`、`binaryChunkingV1`、`workspaceSetupObservation`）；(b) 服务端 `server_info.features`（messages.ts:3670-，布尔 flag，带 COMPAT 注释）。app 在**单点**判断 feature，缺失就提示更新 host，不做降级（docs/protocol-compatibility.md "The feature contract"）。
- **未知入站消息**：daemon 对 `type:"session"` 且有 requestId 的未知/非法消息回 `rpc_error{requestId, requestType, code:"unknown_schema", error:"Unknown request, try upgrading the daemon (currently vX)"}`（`websocket-server.ts:2431-2455`）；无 requestId 的就只记日志。code 为 `invalid_message` 表示 schema 校验失败。proxy 按同样格式拒绝即可。
- **客户端对 rpc_error**：`sendRequest` 把 `rpc_error` 变成 `DaemonRpcError{code, requestType}`，使该 Promise reject（`daemon-client.ts:2260-2280`）；个别功能显式处理 `unknown_schema`（例如 `app/src/git/pull-request-panel/use-data.ts:322-328` 回退）。**不会断连，也不影响其它请求**，但会在 UI 上显示错误/功能失效。无 requestId 的请求（`terminal_input`、`client_heartbeat`、`subscribe_terminals_request` 等）拒绝时无法回包，静默丢弃。
- **客户端对未知出站消息**：`handleJsonPayload`（`daemon-client.ts:6905-6955`）校验失败只记 `Message validation failed` 日志并丢弃；若是可关联的 response（类型以 `_response`/`.response`/`/response` 结尾且有 requestId），则 reject 对应 waiter 为 `DaemonProtocolError`。即 proxy 少发/多发字段不会断连，但字段缺失会让对应调用失败。校验器是生成的 AOT 校验（`docs/protocol-validation.md`），要求 schema 为纯结构（无 transform/catch）。
- **优雅降级建议**：不要靠逐条拒绝；让 proxy 的 `server_info.features` 不声明 `connectedHosts`、`hostMultiplexing`、语音 `capabilities`、`ownedSubscriptions` 等不想支持的项，app 会走 UI 门控。注意不要关掉 app 必需的 feature：app 会走 legacy 路径，那些路径多是同一个 requestId 的老 RPC，proxy 也要实现。
- **owned subscriptions**：现代客户端协商 `owned_subscriptions`（hello capability）/`features.ownedSubscriptions`：列表请求带 `subscribe:{}` 才产生服务端订阅 id，订阅归属于发起它的物理 socket，重连后订阅 id 会换新（docs/architecture.md "Handshake"）。这意味着 proxy 每次客户端重连都要重新在各盒子上建订阅。

## 5. 协议变动（v0.11.0 → v0.15.4）

方法：对每个 tag 用 `git archive` 解出 `packages/protocol/src`，解析 `SessionInbound/OutboundMessageSchema` 成员；再 `git diff` 看字段。

| 版本 | 日期 | 入站类型数 | 出站类型数 | 新增 | 删除 | messages.ts 变更 | 备注 |
|---|---|---|---|---|---|---|---|
| v0.11.0 | 2026-10-07 | 206 | 224 | — | — | — | 基线 |
| v0.11.4 | | 206 | 224 | 0 | 0 | — | 补丁版本无协议变更 |
| v0.12.0 | 2026-10-19 | 206 | 224 | 0 | 0 | +49/-7 行 | 小幅可选字段变更（未逐条核对；源码注释称 `workspaceSetupObservation` 为 v0.12.0 引入）；protocol 目录新增 paseo-tool-presentation 模块、改了 validation/ws-outbound.ts |
| v0.13.0 | 2026-10-24 | 215 | 234 | +9 入 +10 出 | 0 | +92/-2 | `hosts.*`（8 对，connected hosts）+ `workspace.setup.subscribe`；host-route 二进制 opcode 0x30 |
| v0.14.0 | 2026-10-29 | 218 | 237 | +3 入 +3 出 | 0 | +31 | `speech.local_models.{list,download,delete}` |
| v0.15.0 | 2026-11-03 | 218 | 237 | 0 | 0 | +50/-2 | 二进制分块 0x31（`chunked-transport.ts` 214 行）、终端 `ReplayBegin/Data/End` opcode、新 client capability |
| v0.15.4 | 2026-11-10 | 219 | 238 | +1 入 +1 出 | 0 | +34 | `project.suggestions.{request,response}` |
| 合计 | | +13 | +14 | | 0 | messages.ts 共 +256/-11 | protocol/src 非测试文件共 32 个文件 +1958/-610 行（含 paseo-tool-presentation 等非 wire 模块） |

- 新增入站 13 个：`hosts.list/add/update/remove/link.open/route.open/route.frame/route.close.request`、`workspace.setup.subscribe.request`、`speech.local_models.list/download/delete.request`、`project.suggestions.request`。出站对应的 14 个（含 `hosts.changed`、`hosts.route.frame`、`hosts.route.closed` 三个推送）。
- 粒度上平均每个 minor 新增约 4 个入站类型（0~9）；**没有任何类型被删除或重命名**，与 docs/protocol-compatibility.md 的"只增不改"策略一致。
- 字段级变化（messages.ts diff）：几乎都是 `.optional()` 新增，如 `includeBackground`、`internal`/`background`、`sourceAgentId`/`sourceAgentServerId`/`sessionMode`、`wholeTurns`、`killTerminals`/`keepTerminals`、`contentEncoding`、`setupStatus`、`kind/mimeType`、`createdAt`/`lastUserMessageAt`；配置里 `usage`、`idleRuntimeCleanup`、`resumeOnStartup`、`resumePrompt`、`envOverrides`、`requireProtectedSecurity`。少数放宽：`checkout diff mode` 的 enum 增加 `"all"`；一处 `log: string` 变为可选。
- `server_info.features` 新增至少 21 个 flag（`internalAgents`、`backgroundWorkspaces`、`connectedHosts`、`hostMultiplexing`、`usageSetting`、`speechSettings`、`idleRuntimeCleanupSetting`、`resumeOnStartupSetting`、`fileByteWrites`、`terminalsSurviveRestart`、`wholeTurnTimeline`、`relayProtectedSecurity`、`projectSuggestions`、`hopliteProvider`、`binaryChunkingV1`、`workspaceSetupObservation`、`workspaceSortTimes`、`agentMessageProvenance`、`agentMessageBatching`、`checkoutDiffAll`…，以 v0.11.0..v0.15.4 的 diff 为准，可能略有遗漏）。
- CHANGELOG.md 在该区间增加约 511 行，大多是功能与修复，协议专条目很少（未确认逐条审查）。
- 发布节奏：约 1 个 minor/5 天。proxy 要么和 daemon 同版本发布，要么对每个 minor 做一次 diff 审计。proxy 的新类型清单必须在每个 minor 上更新；漏掉的新类型会被 proxy 以 `unknown_schema` 拒绝，app 与 daemon 都不会崩溃，但对应新功能会失效。
- 因为所有盒子 daemon 都是同一镜像、同一版本，盒子之间无版本漂移问题；只需关注 app↔proxy 一侧的漂移（用户的 app 与 proxy 版本各自更新）。proxy 可以直接声明 `protocolVersion: 1` 并取各盒子 `features` 的交集。

## 6. 对 route B 的含义（摘要）

1. 可行但"薄代理"不成立：proxy 必须有状态（agent/workspace/project/terminal/subscription/upload/idempotencyKey→盒子的路由表、slot 表、requestId 表、自造的目录同步游标、自己的 server_info/status/pong/heartbeat/ping），本质是一个简化版的 daemon。
2. 纯 per-agent / per-path 的请求（约 100 个，约占 45%）路由简单；复杂度集中在 global（聚合、游标）、other（31 个，状态化）和 create（9 个，需要盒子生命周期决策）。
3. 路径空间是潜在最大坑：app 与 daemon 之间大量字段是绝对路径（cwd、projectRootPath、workspaceDirectory、path）；多个盒子若用相同的盒子内路径，需要 proxy 做命名空间改写，或者给每个盒子分配不重叠的路径视图。
4. 减少表面积：不广告 `connectedHosts`/`hostMultiplexing`/语音/`binaryChunkingV1`，可少代理 hosts.*（8 个）、dictation/voice（8 个）、分块；拒绝 chat/loop/hub.execution/editors（17 个）。
5. 参考实现：daemon 自己的 host route 机制（`hosts.route.*` + opcode 0x30 + channel id）已经解决了"一个连接里复用多个下游 daemon"的编码问题，可借鉴其 channel 化与帧大小预算（`host-route.ts`），但它的语义是"客户端显式选择 serverId"，不是聚合。

## 未确认清单

- app 是否实际发送 `hosts.*`、`hub.management.*`（app/src 中未找到直接引用，未确认是否经 client 包间接调用）。
- `plugin.*` 的 plugin 运行位置（daemon 内受信代码）在盒子中的语义。
- `chat/*`、`loop/*` 是否经 server 侧 MCP 工具生成（没有客户端引用）。
- `serviceProxy.middleware()` 是否需经 app 通路。
- 各类 scheduleId 的格式。
- `server_info.features` 新增 flag 的完整清单与首次出现的精确版本（按 minor 粒度未逐个核对）。
