# Paseo v0.15.4：relay / E2EE / 直连 / 推送 / 身份 调研（route B 代理可行性）

源码根：上游 `getpaseo/paseo`（v0.15.4）。下文路径均相对 `packages/`。
行号为 v0.15.4 的行号。标注“未确认”的是没有从源码直接验证的点。

## 0. 结论速览

- E2EE 层是可复用的独立库：`@getpaseo/relay`（`./e2ee` 导出 `openDaemonSecureChannel`），只依赖 noble、tweetnacl、ws，不依赖 server。
  代理可以直接 import，在“daemon 侧”终结加密。
- 在 relay 之上还有一层薄胶水，约 500 行，可以整体复制：`server/src/server/relay-transport.ts`（relay 控制/数据 socket 管理）、
  `websocket/secure-relay-ingress.ts`、`websocket/encrypted-relay-socket.ts`。
- daemon 可以只监听 unix socket，也可以完全关闭 relay。
  但仅 unix socket 监听会让 agent 内置 MCP 注入和终端活动回调失效（见 3.4）。
- 推送是 daemon 直接 POST `https://exp.host/--/api/v2/push/send`，不需要任何密钥，只需要 app 的 Expo push token。
  推送 payload 里带 `serverId`，所以所有盒子 daemon 必须使用代理的 serverId。
- 真正的工作量在 relay/E2EE 之外：把多个盒子 daemon 的会话合并成一个 daemon 会话
  （hello/server_info、agent 与 workspace 列表合并、请求按 id 路由、二进制终端帧等）。
- 另外，daemon 已有内建的 connected hosts / host multiplexing（`hosts.route.*`），是现成的“一个入口、多个下游 daemon”机制，见 5.3。

## 1. daemon 身份

| 项 | 位置 | 说明 |
|---|---|---|
| serverId | `$PASEO_HOME/server-id`（`server/src/server/server-id.ts:13,35-60`） | 形如 `srv_<12 位 base64url>`（`:23-27`）。env `PASEO_SERVER_ID` 可覆盖，首次会被持久化（`:43-60`）。 |
| X25519 密钥对 | `$PASEO_HOME/daemon-keypair.json`（`server/src/server/daemon-keypair.ts:16-24,31-69`） | 格式 `{v:2, publicKeyB64, secretKeyB64}`，权限 0600，tweetnacl `box.keyPair`（`relay/src/crypto.ts:174-178`）。读取失败会静默重新生成（`:50-52`），identity 随之改变。 |
| 密码 | `config.json` 的 `daemon.auth.password`（bcrypt 哈希）或 env `PASEO_PASSWORD`（`server/src/server/config.ts:496-505`，启动时 hashSync，cost 12，`auth.ts:6,35`） | 可选。 |
| local-credential | `$PASEO_HOME/local-credential`，每次启动重写（`local-credential.ts:12-35`） | 仅本地 CLI/desktop 免密码用，对代理无关。 |
| push-tokens.json | `$PASEO_HOME/push-tokens.json`（`websocket-server.ts:806`） | 见第 4 节。 |

serverId 同时是 relay 的会话标识（`protocol/src/connection-offer.ts:3-8`）。

app 在配对后保存的内容：
- `HostProfile`：`{serverId, password?, label, appearance, connections[], preferredConnectionId,…}`（`app/src/types/host-connection.ts:76-86`）。
- `connections[]` 可以是 `relay`、`directTcp`、`directSocket`、`directPipe`、`remoteSsh`、`routed`（`:20-60`）。
- relay 连接保存 `{relayEndpoint, useTls, daemonPublicKeyB64, minimumSecurityMode?}`（`:39-50`）。
- 存储位置：AsyncStorage key `@paseo:daemon-registry`（`app/src/runtime/host-runtime.ts:1533`）。
- app 的 clientId 保存在 `@paseo:client-id-v1`（`app/src/utils/client-id.ts`）。这是 app 端的值，daemon 只用它做会话键（`websocket-server.ts:1763-1810`）。

所以 app 对 daemon 的“信任锚”只有三样：serverId、daemon 公钥、可选密码。
app 连接后会校验 `server_info.serverId` 是否等于已保存的 serverId，不一致就报错（`host-runtime.ts:1132-1143`）。
daemon 端没有“配对批准”步骤：谁拿到 offer（serverId+公钥）谁就能连，除非设了密码（见 3.3）。

## 2. Relay 与 E2EE

### 2.1 配对

- 配对 offer 是 `ConnectionOfferV2`：`{v:2, serverId, daemonPublicKeyB64, relay:{endpoint, useTls?}, minimumSecurityMode?:"protected"}`
  （`protocol/src/connection-offer.ts:9-20`）。
- 编码方式：JSON、base64url，拼成 `https://app.paseo.sh/#offer=<b64url>`（`server/src/server/connection-offer.ts:187-194`）。
  二维码就是这个 URL（`pairing-offer.ts:120-135`）。
- 另有 `relay://host:port/<serverId>?key=<pub>&ssl=true&security=protected&password=…` 形式，可以带密码
  （`protocol/src/daemon-endpoints.ts:22-72`）。
- 生成入口：CLI `paseo daemon pair`（`cli/src/commands/daemon/pair.ts`）和会话 RPC `daemon.get_pairing_offer.request`
  （`server/src/server/session/daemon/daemon-session.ts:228-262`）。
- 对代理来说，offer 只是一段 JSON，可以自行生成：用代理自己的 serverId、公钥和 relay endpoint，不依赖任何盒子 daemon。
- relay 默认端点 `relay.paseo.sh:443`（`config.ts:39`）。
  新 home 默认 relay 关闭，配对时才开启（`persisted-config.ts:390`，`docs/architecture.md:192`）。

### 2.2 Relay 协议（v2）

URL：`ws(s)://<endpoint>/ws?serverId=<id>&role=server|client&v=2[&connectionId=<id>]`（`protocol/src/daemon-endpoints.ts:208-232`）。
relay 是一个不透明转发器，不做认证，只按 serverId 分会话。参考实现 `relay/src/cloudflare-adapter.ts`。
该实现现在是 legacy，生产 relay 是另一个仓库的 Elixir 服务（`docs/architecture.md:196`，未审阅其代码，未确认其与 CF 版行为逐字节一致）。

- daemon 控制 socket：`role=server`，无 connectionId，每个 serverId 一条。
  relay 推送 JSON 控制消息：`sync{connectionIds}`、`connected{connectionId}`、`disconnected{connectionId}`、`ping`/`pong`
  （`server/src/server/relay-transport.ts:41-46,289-327`）。daemon 用 WebSocket 协议 ping 保活，10 秒一次，30 秒视为失效（`:48-50,211-245`）。
- daemon 数据 socket：每个 app 连接一条，`role=server&connectionId=<id>`。
  daemon 收到 `connected/sync` 后才去建（`:342-396`）。
- app socket：`role=client`，不带 connectionId，由 relay 分配（`cloudflare-adapter.ts:347-351`）。
  relay 在 server 数据 socket 未就绪时会缓冲 client 帧（`:252-262,483-488`）。
- 数据通道为双向透明转发，文本和二进制帧都保留。daemon 侧断开时，relay 用 1012 关闭 client（`:545-556`）。
- relay 看不到 serverId 之外的任何明文；密码和凭据都在加密后的 hello 里（`SECURITY.md` 的 Trust model，
  `daemon-client-relay-e2ee-transport.ts:86-94`）。

### 2.3 E2EE 方案

两种模式，详见 `docs/relay-endpoint-security.md`，代码在 `relay/src/secure-channel.ts`。

- protected（默认，≥v0.13）：`Noise_NK_25519_ChaChaPoly_SHA256`。
  - prologue 为 `paseo-relay-e2ee/1`（`secure-channel.ts:114`）。
  - 静态密钥就是 daemon-keypair.json 里的 X25519 密钥，没有第二个 daemon 身份（`docs/relay-endpoint-security.md:22-23`）。
  - 消息 1（`-> e, es`）放在 `{type:"e2ee_hello", key, capabilities, protected:{v:1, message:<b64>}}` 里，文本帧。
  - 消息 2（`<- e, ee`）放在 `{type:"e2ee_ready", protected:{v:1, message}}` 里。
  - 握手 payload 为 2 字节参数 `[0x01][flags]`，flag bit0 为 binaryCiphertext。
  - 之后每个应用帧封装成 Noise transport 记录：`kind(1)||flags(1)||totalLen(u32)||data`，每块 ≤65513 字节，
    线上格式为 `(u16 len || ciphertext)+`，nonce 为计数器（`protected-records.ts`）。
- legacy：临时密钥 X25519 + NaCl box（XSalsa20-Poly1305），随机 nonce，格式 `[nonce24][ct]`（`crypto.ts`、`encrypted-channel.ts`）。无重放保护。
  只有对端不带 `protected` 字段时才会走 legacy。
  `daemon.relay.requireProtectedSecurity` 可强制拒绝 legacy（`config.ts:341`）。
- 角色：app（initiator）持有 daemon 公钥和每连接临时密钥，无持久私钥；daemon（responder）持有静态私钥，每个会话生成新的临时密钥。
  daemon 的私钥不离开 daemon（代理接管后就是代理持有）。
- 重试：client 每秒重发 hello，daemon 缓存 hello/ready 文本，相同 hello 回相同 ready（`secure-channel.ts:574-640`）。握手超时 15 秒（`secure-relay-ingress.ts:31`）。
- app 在 `server_info.features.relayProtectedSecurity===true` 且会话是 legacy 时会主动断开，用 4002（`daemon-client-relay-e2ee-transport.ts:67-80,139-151`）。
  所以代理的 server_info 必须透传这个 feature，或者直接用 protected 模式。
- relay 看不到明文，只能看到 serverId、IP、时序、大小和握手帧里的公钥。

### 2.4 代理要实现什么（作为 daemon 终结 E2EE）

1. 身份：代理持有一份 `server-id` + `daemon-keypair.json`，格式同上。
   可以直接复用 daemon 的这两个文件，也可以自行生成：`generateKeyPair`、`exportPublicKey` 由 `@getpaseo/relay/e2ee` 导出。
2. relay 侧 daemon 客户端：复制 `relay-transport.ts`（约 400 行，唯一外部依赖是 pino 和 `webSocketProxyAgent`，都容易替换）。
   实现控制 socket 保活，以及按 connectionId 建数据 socket。
   或者代理自己实现 relay 服务端，写进 offer 里的 endpoint，这样完全不经过 relay.paseo.sh（参考 `cloudflare-adapter.ts`，约 600 行，未确认是否有 Node 版可直接跑）。
3. 每个数据 socket 跑 `openDaemonSecureChannel(transport, {daemonKeyPair, minimumMode})`。
   胶水见 `secure-relay-ingress.ts:60-135` 和 `encrypted-relay-socket.ts`，后者负责发送缓冲上限，8 MiB，`MAX_PHYSICAL_SOCKET_BUFFERED_BYTES`。
4. 加密通道之后就是普通的 Paseo WS 协议（JSON 文本帧 + 二进制帧，hello → server_info）。
   代理需要作为这个 WS 的服务端：解析 `hello`（含 `auth.password`），发送 `server_info`，然后转发。
5. 最小的“笨管道”做法：对盒子 daemon 开 unix socket WS，转发所有帧，只拦截 hello、server_info、register_push_token。
   但单会话对应多个盒子时，就必须理解消息语义，见第 7 节。
6. 分块传输 `binary_chunking_v1`（opcode 0x31）和 100 MiB 上限在 hello 能力里协商（`docs/protocol-compatibility.md`）。
   代理若原样转发就无需处理；若自己合并会话，则需要处理。

可分离性：E2EE 部分基本是独立库，不纠缠。
- `relay/src/secure-channel.ts` 只依赖同包的 `encrypted-channel/noise/protected-records/crypto`，接口是简单的 `Transport {send, close, onmessage, onclose, onerror}`。
- `relay/package.json` 的 `exports` 有 `.` 和 `./e2ee`。
- 纠缠点只在 server 侧的胶水，它们把安全通道接到 `wsServer.attachExternalSocket`（`bootstrap.ts:1896-1925`）。这部分不需要，因为代理有自己的会话层。

## 3. 直连、认证、监听

### 3.1 监听配置

- `PASEO_LISTEN` / CLI `--listen` / `config.json` 的 `daemon.listen`（`config.ts:476-495`），默认 `127.0.0.1:6767`。取值：
  - `host:port`（TCP）
  - `/path/to.sock`
  - `unix:///path/to.sock`
  - Windows 下是 `pipe://` 或 `\\.\pipe\…`
  解析见 `bootstrap.ts:52-90`。
- 监听 unix socket 时先 unlink 旧文件再 listen（`bootstrap.ts:1940-1943`），退出时删除（`:2031-2033`）。
  socket 文件权限未显式设置（未确认，依赖 umask）。
- unix socket 下跳过 Host 头校验（`bootstrap.ts:780-795`）。
- WS 路径固定为 `/ws`（`daemon-endpoints.ts:buildDaemonWebSocketUrl`）。
- HTTP 路由（`/api/health`、`/api/files/download`、`/mcp/agents`、`/api/terminal-activity`）与 WS 同一个 server。

### 3.2 关闭 relay

- `PASEO_RELAY_ENABLED=false`（env 优先级最高，且此时 `enabledMutable=false`，RPC 不能再打开，`config.ts:317-343`）。
- 或 `daemon.relay.enabled=false`，或 CLI `relayEnabled`。
- 相关 env：`PASEO_RELAY_ENDPOINT`、`PASEO_RELAY_PUBLIC_ENDPOINT`、`PASEO_RELAY_USE_TLS`、`PASEO_RELAY_PUBLIC_USE_TLS`（`config-environment.ts:33-37`）。
- 运行时开关：`daemonConfigStore.onFieldChange("relay.enabled")`（`bootstrap.ts:1926`）。
- 注意：`bootstrap.ts:1787` 里 `config.relayEnabled ?? true`，也就是说程序化嵌入时不传该值会默认开启。
  用 env 强制 false 最稳妥。

### 3.3 认证（auth.ts / session-admission-auth.ts）

- 密码存 bcrypt 哈希（`auth.ts:6,35`）。
- 无密码：`resolveSessionAdmission` 直接给 owner 全权限（`session-admission-auth.ts:11-20`），HTTP 中间件也直接放行（`auth.ts:83`）。
  SECURITY.md 明确说明：无密码时，能连上 socket 的人就能控制 daemon。
- 有密码时 WS 认证有两条路径：
  - 新：`hello.auth = {kind:"password", password}`（明文放在 hello 里，所以直连明文 ws 时要靠 TLS 或网络隔离；relay 下被 E2EE 保护）。
  - 旧（COMPAT）：`Authorization: Bearer` 或 WS 子协议 `paseo.bearer.<password>`，在 upgrade 阶段校验（`websocket-server.ts:978-1000`）。
  - 失败时会发 `hello.rejected{reason, accepts:["password"]}` 并以 4401 关闭（`:1896-1925`、`:135`）。
- app 把密码存在 `HostProfile.password`（`types/host-connection.ts:77`），`directTcp` 连接的 wire schema 也可带密码（`host-connection-schema.ts:3-9`）。
  relay 连接的密码走 `relay://…&password=` 或手动输入，最终也是 hello。
- 所有认证成功的会话都是 `principalId:"owner"`，权限为全集，没有多用户/多角色（hub 和 routed 才有受限权限，见 `authorization/index.ts`）。
- 对代理的含义：代理自己决定是否要求密码，并校验 hello.auth。
  到盒子 daemon 时可以不设密码，因为 unix socket 靠文件权限隔离；这是明确的信任边界选择。

### 3.4 仅 unix socket 的副作用

- `createAgentMcpBaseUrl` 和 `createTerminalActivityUrl` 在非 TCP 时返回 null（`bootstrap.ts:274-293`）。
  结果是：不给 agent 注入 Paseo MCP（`agentManager.setMcpBaseUrl(null)`，`:1767-1771`），终端 agent hook 的活动回调也不可用。
- 如果盒子内要保留这些功能，需要让盒子 daemon 同时监听 loopback TCP（容器网络命名空间内），再由代理走 unix socket 的另一个入口。
  daemon 只支持一个 `listen`，所以只能“TCP 回环（容器内）+ 容器外由代理桥接 TCP”。
  这点未确认是否有变通办法，建议实测。
- 文件下载：relay 连接下通过会话读取字节（`download-store.ts` 的注释“Saves bytes read over the session”）；
  只有直连 TCP 才用 HTTP `/api/files/download`（`download-store.ts:300-345`）。代理走 relay 路线不涉及 HTTP。

## 4. 推送通知

- app 侧：每个 host 的 client 连接上后调用 `registerPushToken(token)`，发送会话消息 `register_push_token{token}`
  （`app/src/push-notifications/internal/subscriptions.ts:57-70`、`client/src/daemon-client.ts:2492`）。
  token 是 Expo push token，用 EAS projectId 获取。
  撤销：`push.unregister.request`（需要 `features.pushTokenRevocation`），见 `session.ts:3249-3258`。
- daemon 存储：`PushTokenStore`，租约 48 小时，`register_push_token` 和心跳 `client_heartbeat` 都会续租（`session.ts:5067-5090`；
  `push/index.ts:11`；`push/token-store.ts`）。持久化在 `push-tokens.json`。
- 发送：`PushService` 直接 `POST https://exp.host/--/api/v2/push/send`（`push/push-service.ts:165`），批量 100 条，
  body 为 `{to, title, body, data, sound:"default"}`。无服务端密钥、无认证头。
  `DeviceNotRegistered` 和 `InvalidCredentials` 时撤销 token（`:241-246`）。
- 触发：agent 结束/出错/需要权限（`websocket-server.ts:2857-2910`）、终端需要注意（`:2928-3020`）。
  daemon 先用所有已连接客户端的在线状态（presence，来自 heartbeat）计算 `computeNotificationPlan`，决定走应用内通知还是推送。
  推送 payload 的 `data` 含 `serverId`、`workspaceId`、`agentId`、`reason` 等（`docs/notifications.md` 的示例；`buildAgentAttentionNotificationPayload`）。
  app 点击通知后用 `serverId` 找 host（`docs/notifications.md:8-14`）。
- 对代理的含义：
  1. 盒子 daemon 的 `PASEO_SERVER_ID` 必须设成代理的 serverId，否则推送里的 `serverId` 会让 app 找不到 host。
     盒子的 server-id 文件首次写入后不会被 env 覆盖（`server-id.ts:50-60`：文件已存在时仍返回 env 值，因此 env 总是优先）。
  2. 简单做法：代理把 `register_push_token`/`client_heartbeat` 原样转给盒子 daemon，盒子自己推。
     前提是盒子能出网访问 exp.host（可走 `HTTPS_PROXY`，daemon 支持）。
     缺点：每个盒子只看到经过代理转给它的连接，presence 判断是 per-盒子的；多个盒子会重复存 token。
  3. 集中做法：代理不转发 token，自己存 token，监听盒子发来的 `agent_attention_required` 和 `terminal_attention_required` 事件
     （其中带 `notification` payload，见 `websocket-server.ts:2917-2945`），自己调 Expo。
     代价是要自己重做 presence 与去重逻辑（`computeNotificationPlan` 的行为，未逐行阅读，未确认完整规则）。
     优点是盒子不需要出网，且只推一次。
  4. token 不是 secret，但属于设备标识，需要保护好。

## 5. 多 daemon

5.1 app 原生支持多 host：`HostRuntimeStore` 里 `hosts: HostProfile[]`，每个 host 一个 `HostRuntimeController` 和一个 DaemonClient（`host-runtime.ts:1628-1660`）。
同一 serverId 可以挂多个 connections（relay + 直连 + ssh），按候选探测并选最优（`:507-560`、`PROBE_*`）。
这一点我们已决定不依赖，仅记录。

5.2 一个 HostProfile 的 serverId 变化被视为不同 host：连接解析出的 serverId 与保存的不一致会报错，
除非保存的是 `local:` 占位 id（`host-runtime.ts:1132-1143,1591-1593`）。所以代理必须长期保持稳定的 serverId。

5.3 daemon 之间已有内建的“connected hosts”：
- `server_info.features.connectedHosts` 和 `hostMultiplexing`（`websocket-server.ts:2000-2010`）。
- daemon A 的 `hosts.json` 保存 B 的连接，通过 `hosts.route.open/frame/close` 在一条物理链路上复用多个虚拟会话（`protocol/src/hosts.ts`，`docs/connected-hosts.md`）。
- app 有 `routed` 连接类型：`{type:"routed", originServerId}`（`types/host-connection.ts:60-63`），
  即通过 A 的会话去访问 B，B 在 app 里作为独立 host 出现。
- 这条路径下每个盒子是一个独立 host（独立 serverId），与“单一 daemon 身份”的目标冲突，
  但可作为备选设计：代理做 A，盒子做 B。未确认 app 里 routed host 的发现与展示 UI 的完整行为，建议单独调研。

## 6. 代理需要一致伪造的其他每 daemon 状态

- `server_info` 状态负载（`websocket-server.ts:1989-2070`，schema 在 `protocol/src/messages.ts:3659-`）：
  `protocolVersion`（当前 1，`:515`）、`serverId`、`hostname`、`version`、`sourceId`、`permissions`、`desktopManaged`、`capabilities`、
  以及大量 `features.*`（relayProtectedSecurity、binaryChunkingV1、agentRequestReceipts、workspaceRequestReceipts、creationLifecycle、
  daemonConfigReload、pushTokenRevocation、plugins、hostMultiplexing 等）。
  - app 按 feature 做一次性门控，不满足就提示升级或隐藏功能（`docs/protocol-compatibility.md`：“Capability flags live in features”）。
  - 代理应该取各盒子的 feature 交集（取最小公共集），并且 `version` 取同一个值（建议所有盒子用同一 Paseo 版本）。
  - `capabilities`（语音/STT/TTS 就绪度）通过 `capabilities.update` 消息动态更新（`websocket-server.ts:updateServerCapabilities`），需要合并。
  - `hostname` 在 app 里作为展示名，代理需要固定一个。
- `hello`：`clientId`（app 生成）、`clientType`、`protocolVersion`、`capabilities`、`auth`、`appVersion`（`messages.ts:7741-7779`）。
  daemon 以 `[principalId, clientId]` 作为会话键并支持断线续接（`websocket-server.ts:3074-3076`、resumeSession）。
  代理需把一个 app 会话映射到每个盒子的 hello，clientId 可以直接透传或派生，但要保持稳定，否则盒子里会话续接和 presence 会失效。
  hello 超时 4001、无效 hello 4002、不兼容协议 4003、认证失败 4401。
- `daemon.get_status`、`daemon.get_pairing_offer`、`daemon config` 相关 RPC（`daemonStatusRpc`、`daemonConfigReload`、`relayConfig`）会返回 daemon 自身的 pid、listen、relay 状态、provider 列表等，
  需要代理合成或拒绝，否则会显示某一个盒子的内部信息（`daemon-session.ts:215-262`）。
- app 的设置页会显示 daemon 版本（`host-page.tsx:182,727`），并带有 desktop 更新逻辑。未发现 app 对 daemon 版本做硬性下限检查，只有 feature 门控（未确认，只做了 grep）。
- 客户端能力 `pushNotifications` 等会影响 daemon 的投递策略（`wantsSourceNotification`），要透传。
- 跨盒子的聚合：agent 列表、workspace 列表、项目列表（`fetch_agents`、`fetch_workspaces`、`project.list` 等）都是 per-daemon 的，需要由代理合并。
  任何以 id 为键的请求要路由到正确的盒子，所以代理要维护 agentId/workspaceId/terminalId/requestId 到盒子的映射。

## 7. 评估

### 可行性

relay + E2EE 终结：可行，工作量小。
- 直接 import `@getpaseo/relay/e2ee`，复制 `relay-transport.ts` 与两个 websocket 胶水文件。
- 估计 2-4 个工作日，包含重连、保活、connectionId 管理、握手超时、与真实 app 联调。
- 如果自建 relay（避免依赖 relay.paseo.sh），再加 2-3 天，协议很小，参考 CF 实现。
- 配对 offer 生成是几十行。
- 推送集中化约 2-3 天，取决于 presence 去重的复杂度。

难点是会话层合并，即“单一 daemon 身份对应多个盒子”：
- 需要实现 hello/server_info 合成，agent/workspace/project 列表合并，请求路由，订阅（timeline、terminal 二进制流、file transfer）的多路复用，
  RPC 的 requestId 与 receipts 幂等，`capabilities.update`/`daemon_config_changed` 等广播的合并，断线续接。
- 协议很大：`messages.ts` 约 7800 行，且“协议永远向后兼容”的约定意味着代理要对未知消息做保守处理。
- 估计 数周量级（未确认，需先列出 app 实际用到的消息集合再估），且会随 Paseo 版本演进持续维护。
- 如果每个 workspace 只对应一个盒子，路由键相对清晰（workspaceId 属于哪个盒子），但 agent 创建、项目添加、全局设置等没有 workspaceId 的请求需要策略。

### 主要风险

1. 协议跟随成本：Paseo 每个版本都改 messages 和 features；代理需锁定版本，或把不理解的消息按 workspace 路由。
2. 安全边界变化：代理持有 daemon 私钥，E2EE 终点从盒子变成主机；盒子之间的隔离靠代理正确路由。
   无密码时任何拿到 offer 的人都是 owner，建议代理强制密码，或使用 `requireProtectedSecurity` 对应的 protected 模式。
3. 身份稳定：`daemon-keypair.json` 读取失败会静默重建（`daemon-keypair.ts:50-52`），代理必须自己严格管理，否则所有已配对 app 失效。
4. 推送：serverId 必须一致；presence 分散在多个盒子会导致重复推送或漏推。
5. unix-socket-only 会让 agent MCP 注入失效（3.4）。
6. app 对 serverId 变化敏感（5.2）；`sourceId`/producer 相关（routed）字段若透传需要小心。
7. relay 侧的行为以生产 Elixir 版为准，本仓库只有 legacy CF 实现可参考；自建 relay 能规避这点。
8. 可替代路径：用内建 connected hosts（5.3）让 app 把盒子当作独立 host，会省掉会话合并，但违背“单一 daemon 身份”。

## 附：关键文件索引

- `relay/src/secure-channel.ts`：握手、协商、重试（835 行）
- `relay/src/crypto.ts`、`encrypted-channel.ts`：legacy
- `relay/src/noise/*`、`protected-records.ts`：Noise 与记录封装
- `relay/src/cloudflare-adapter.ts`：relay 服务端参考
- `server/src/server/relay-transport.ts`、`relay-runtime.ts`：daemon 侧 relay 客户端
- `server/src/server/websocket/secure-relay-ingress.ts`、`encrypted-relay-socket.ts`：接 E2EE 通道
- `server/src/server/daemon-keypair.ts`、`server-id.ts`、`pairing-offer.ts`、`connection-offer.ts`
- `server/src/server/auth.ts`、`session-admission-auth.ts`、`websocket-server.ts:970-1000,1855-1925`
- `server/src/server/push/*`、`session.ts:3249,5067-5090`
- `server/src/server/config.ts:296-345,470-505`、`bootstrap.ts:52-100,274-293,1896-1943`
- `protocol/src/connection-offer.ts`、`daemon-endpoints.ts`、`hosts.ts`、`messages.ts`（hello 7741，server_info 3659）
- `app/src/types/host-connection.ts`、`app/src/runtime/host-runtime.ts`
- `docs/relay-endpoint-security.md`、`SECURITY.md`、`docs/connected-hosts.md`、`docs/protocol-compatibility.md`
