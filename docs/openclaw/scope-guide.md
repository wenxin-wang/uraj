# Storie OpenClaw / 飞书：范围

> 迁移自 `docs/openclaw.org` 的 “当前范围”、“参考”（2026-11-14，内容未改）。

## 当前范围

一个飞书 bot、一个 Gateway 容器、多个独立身份和记忆的 agent，通过 new-api 调用模型。
飞书采用主动建立的 WebSocket 长连接，不需要公网地址或 webhook 入站。
私聊需管理员批准配对；插件为每个人分配默认私人角色。新群使用独立的
共享角色 `household-shared`，默认需要 @机器人；群主或命令管理员可用
`/mention` 调整，用 `/persona` 选择或创建角色，不需要为每个群修改 Guix。
群聊使用 `groupSessionScope="group_topic"` 和 `replyInThread="enabled"`：
同一 agent 的身份和长期记忆共用，各群、各话题的会话上下文分开；没有话题
标识的消息回到群级会话。每个群绑定一个角色，群内各话题使用同一个角色。
飞书事件对话题群（`chat_mode="topic"`）也上报 `chat_type="group"`，上游
插件因此不走 `topic_group` 分支：话题首条消息按 `thread_id` 建会话，引用
回复按 `root_id` 另建会话，同一话题被拆成两个。部署镜像的补丁层在带
`thread_id` 的群消息上按群查询一次 `chat_mode`（进程内缓存），话题群标记为
`topic_group`，整个话题统一按 `thread_id` 分会话；普通群不变，查询失败时
记录日志并沿用原逻辑。回复锚点仍取 `root_id` 或消息本身。上游
[#160330](https://github.com/openclaw/openclaw/issues/160330) 和 PR #160332
尚未合并。补丁同时修正入站上下文的 `conversation.threadId` 和
`reply.messageThreadId`：话题首条消息没有 `root_id`，使用其自身的
`message_id`，后续引用回复使用 `root_id`。这样首次后台命令完成后的
回复和 message 工具也能保留话题锚点，不会在群里另开话题。
升级到包含修复的版本后删除此补丁。
TODO：启用 cron 前处理没有入站消息的主动发送；新建的 cron 会话没有回复
锚点，会以顶层消息发出，在话题群里成为新话题。届时采用上游修复或补上该部分。
插件还按群串行处理消息：一轮 agent 运行结束前，同一群的下一条消息不进入
会话路由。话题群里各话题共用一个群 ID，一个话题的长任务会挂起其他话题。
同一补丁层把串行队列的键改为群加 `thread_id`（无 `thread_id` 时不变），
不同话题并行，同一话题仍按顺序处理；中止和 `/btw` 通道随之按话题划分。
同一话题内运行中追加的消息仍要等当前一轮结束，不能并入或改变当前运行，
见上游 [#54409](https://github.com/openclaw/openclaw/issues/54409)。
开放文件工具及 `exec`、`process`；它们在独立引擎容器创建的 Podman
沙箱中以专用 UID 2010 执行，不逐条询问，也不回退到持有凭据的 Gateway。
`web_fetch`、`view_image`、`memory_search`、`memory_get` 也已开放；
前者及记忆工具在 Gateway 执行，需同时列入 `tools.sandbox.tools.alsoAllow`。
自定义模型默认按纯文本处理，读取截图时图片会被丢弃；两个 provider 都设置
`image-input? #t`，生成 `input: ["text", "image"]`。已直接经 new-api 用
图片请求验证 GPT-6 Astra、GPT-6 Luna 和三个 Claude 模型能识别图片内容；
其余 GPT 模型同走 Codex 渠道，未逐个验证。
`message` 工具在 Gateway 执行，同样列入 `alsoAllow`；跨平台发送关闭
（`tools.message.crossContext.allowAcrossProviders`），角色插件再把它限制为
仅 `send`、仅当前会话或本轮请求人的私聊（见「群聊角色与私人身份」）。
浏览器工具和飞书文档工具保持关闭。
执行策略使用 `tools.exec.mode="full"`；不要同时声明旧的 `security/ask`。
2026.10.3 启动时的 Doctor 会将 `security="full", ask="off"` 迁移成
`mode="full"`，混用旧模板会导致不变量检查报差异。

`env/guix/os/storie.scm` 已声明 OpenClaw，包含固定 image ID、飞书
GPT/Claude 两组 provider，默认模型为 `new-api-gpt/gpt-6-astra`（`/astra-6`）。
飞书 App ID、命令管理员名单和三个凭据均以 SOPS 密文保存。
DeepSeek 尚未配置。Live ISO 不声明 OpenClaw。

这些是部署声明，不代表主机已运行该服务。首次部署仍需在 storie
确认镜像已加载，再进行 reconfigure、飞书配对及模型调用验收。

## 参考

- [官方飞书接入](https://docs.openclaw.ai/channels/feishu)
- [SecretRef 契约](https://docs.openclaw.ai/gateway/secrets/secretref-contract)
- [选定版本源码](https://github.com/openclaw/openclaw/tree/v2026.10.3)
- [Restricted workload networks](../restricted-network/networks-guide.md)
- [仓库 SOPS 约定](../secrets/sops-guide.md)
