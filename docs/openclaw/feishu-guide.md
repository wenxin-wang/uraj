# OpenClaw 飞书与模型

## 飞书与模型

### 消息处理中的表情提示

启用飞书插件内置的 `typingIndicator=true`。插件在回复处理阶段给
原消息添加 `Typing` 表情，结束后移除，不另外发送确认文本。
它表示“正在处理”，不是消息接收的持久回执；无需本地插件补丁或
为此重建镜像。表情接口失败只记录诊断，不阻断正常回复。

飞书应用需启用并发布消息表情回复权限
`im:message.reactions:write_only`。修改 Guix 配置后重新部署即可。
原有 SDK 修复镜像继续使用；已构建的 GET 补丁镜像在移除其环境开关后
也不会添加 GET，但后续不再需要维护该补丁。

### 提示缓存

自定义 OpenAI 兼容地址默认不发送 `prompt_cache_key`。因此 `new-api-gpt`
设置 `prompt-cache-key? #t`，为每个模型生成
`compat.supportsPromptCacheKey`；它同时启用 OpenClaw 按缓存 TTL 修剪旧
工具结果。Claude provider 使用 Anthropic 的缓存标记，不需要此项；
OpenClaw 的 Claude 请求从第二轮起即命中缓存。

仅有该键仍不够：new-api 后面的 Codex 上游按 `Session-Id` 头路由缓存，
OpenClaw 不发会话头，只带键几乎不命中。
OpenClaw 不能按会话设置请求头，所以在 new-api 的 `CodexMT`
渠道（id 3）设置参数覆盖，缺少会话头时用 `prompt_cache_key` 补齐：

```json
{"operations": [
  {"mode": "sync_fields", "from": "json:prompt_cache_key", "to": "header:Session-Id"},
  {"mode": "sync_fields", "from": "json:prompt_cache_key", "to": "header:Thread-Id"}]}
```

`sync_fields` 只补缺失的一侧，Codex CLI 自带的会话头不受影响。该设置
保存在 new-api 数据库，不由 Guix 管理；重建 new-api 或渠道时需重新填写。

### 快速切换模型

Astra 的默认 thinking 为 `xhigh`，由 storie 的 `model-thinking` 生成
`agents.defaults.models["new-api-gpt/gpt-6-astra"].params.thinking`。
provider 的 `reasoning-efforts` 同时声明该模型支持的强度，生成
`compat.supportedReasoningEfforts`，避免自定义 provider 把 `xhigh` 降为
`high`。其他模型沿用上游默认。
修改后重新部署并重启 OpenClaw 生效，不需要重建镜像。

已有会话的 `/think` 设置优先于模型默认。单独发送 `/think default` 清除
会话覆盖，或用 `/think xhigh` 显式设置当前会话；`/think` 查看当前强度。

在已配对的飞书私聊中单独发送下列命令，切换当前会话模型；也可用
`/model ALIAS -s`。恢复默认模型用 `/model default -s`。
别名保存在 `agents.defaults.models.<provider/model>.alias`，由 Guix
的 `model-aliases` 生成，不需要重建镜像。修改后重新部署即可。

| 命令 | 模型 |
|---|---|
| /astra-6 | new-api-gpt/gpt-6-astra |
| /sol-6-1 | new-api-gpt/gpt-6.1-sol |
| /sol-6 | new-api-gpt/gpt-6-sol |
| /luna-6 | new-api-gpt/gpt-6-luna |
| /sol-5-6 | new-api-gpt/gpt-5.6-sol |
| /terra-5-6 | new-api-gpt/gpt-5.6-terra |
| /luna-5-6 | new-api-gpt/gpt-5.6-luna |
| /opus-5-5 | new-api-claude/claude-opus-5-5 |
| /sonnet-5-5 | new-api-claude/claude-sonnet-5-5 |
| /haiku-4-5 | new-api-claude/claude-haiku-4-5 |

`gpt-reserve` 没有版本号，暂不配置版本别名，仍可使用完整引用切换。

群聊中，飞书插件只按 `channels.feishu.allowFrom` 授权内置命令，不看配对
记录或 `commands.ownerAllowFrom`；未授权时 `/model`、`/astra-6` 被当作普通
文字交给模型。启动对齐配置时，命令管理员名单同时写入
`channels.feishu.allowFrom`：管理员在群里可直接用上述命令。该字段在频道级
不限制谁能在群里与机器人对话，私聊中只是在已批准配对之外追加。
v2026.10.3 的 Doctor 在启动时把 `allowFrom` 复制到 `groupAllowFrom`；Guix 也声明
这份副本，否则运行配置与受管值不一致，所有经检查的写入（含 `/persona use`）
都会失败。`groupPolicy="open"` 不使用 `groupAllowFrom`。

群主是按群动态查询的，不能写入 `allowFrom`，因此另有插件命令（群要求 @时
同时 @机器人）：

```text
/groupmodel astra-6
/groupmodel new-api-claude/claude-opus-5-5
/groupmodel default
```

命令管理员直接执行；其他发送者按 `/mention` 的方式查询当前群主并比对，
查询失败不修改。它经 `config.mjs session-model` 调用 Gateway 的
`sessions.patch`，与 `/model … -s` 校验相同、写入相同的会话覆盖，只作用于
当前话题会话（无话题时为群级会话），不改默认模型或其他话题。
私人角色因成员检查暂停时，`/persona`、`/mention`、`/groupmodel` 仍可用，
其他消息都只回复暂停提示。

v2026.10.3 把飞书富文本（post）消息转成 Markdown 时会转义 `-`：话题群里
新开话题的首条消息若是 `/astra-6`，Gateway 收到 `/astra\-6`，不被识别为
命令，交给模型处理。`/groupmodel` 会去掉参数里的这种转义，任何位置都可用；
内置别名命令只能在话题内以回复的形式发送。

绑定私人角色的群里，插件只放行带私人角色运行授权的回复和自身控制命令的
回复。内置 `/astra-6`、`/model` 仍会切换模型，但确认回复会被拦下，飞书里
看不到；在这类群里用 `/groupmodel`，它的回复可以送达。

### 应用配置和配对

在飞书开放平台创建应用，启用机器人能力，取得 App ID 和 App Secret。
按选定版本的官方飞书说明配置长连接、`im.message.receive_v1` 消息事件、
私聊消息接收和机器人发送消息权限，并发布应用供自己的账号使用。
群聊测试还需启用接收群内 @机器人消息的权限。话题/引用消息读取需要
应用身份权限 `im:message:readonly`（或已有的 `im:message`），开通后发布
应用版本使其生效。缺少该权限时，日志会出现 `99991672 Access denied`；
若消息仅有 @、又无法读取引用内容，则会被 `skipping empty message`
跳过。首次测试应发送 `@机器人 请回复测试成功`，不要只发送一个 @。
当前配置启用流式卡片，还需应用身份权限 `cardkit:card:write`；
开通、发布及排错见上文“处理进度卡片”。
回复附带图片（例如 agent-browser 截图）时，Gateway 先调用
`/open-apis/im/v1/images` 上传，需要应用身份权限 `im:resource:upload`
（或 `im:resource`），开通后发布应用版本。缺少时日志出现
`99991672 Access denied ... im:resource:upload`，整条回复不会送达，用户
只收到无可见回复的兜底提示。

#### 按群切换 @要求

飞书后台「权限管理」搜索并开通应用身份权限 `im:message.group_msg`
（获取群组中所有消息），再创建并发布应用版本，按后台要求完成审批。
仅有 `im:message:readonly` 不会让未 @机器人的消息自动送达。
群主授权查询还需要获取群信息权限 `im:chat:read`。

部署插件后，在群或群话题里发送（当前要求 @时需同时 @机器人）：

```text
/mention off
/mention on
/mention status
```

`off` 关闭当前整个群的 @要求，`on` 恢复，`status` 查看。
在 `commands.ownerAllowFrom` 明确登记的飞书命令管理员可直接修改，
无需查询群主。其他发送者每次修改都会向飞书查询当前群主并与发送者
open_id 比对；群主变更后以查询结果为准，查询失败不修改。
仅通过私聊配对不等于命令管理员。管理员仍只能修改命令所在群。
storie 的身份信息由 `secrets/hosts/storie/openclaw-identities.yaml` 管理。
其中 `openclaw.feishu-app-id` 保存飞书 App ID，
`openclaw.command-owners` 保存管理员名单：值是 JSON 数组字符串，元素为
`feishu:ou_…`。使用 `sops secrets/hosts/storie/openclaw-identities.yaml`
编辑密文文件，重新部署并重启后生效。新增或撤销管理员都应更新该文件。
Guix 的 `identity-file` 仅引用密文，Gateway 启动对齐配置时从
`/run/secrets/command-owners` 注入 `commands.ownerAllowFrom`，从
`/run/secrets/feishu-app-id` 注入飞书 App ID；不把这些 ID 明文写入源码
或 store。运行配置及其备份会含明文 ID，由现有目录权限保护。
群 ID 随群内命令保存在运行配置中，无需每新增一个群就修改密文并部署。
缺失或格式错误的已配置名单会导致启动失败，不会默认为所有人。
命令不调用模型；关闭 @要求后，该群普通消息可能触发模型并增加费用。
所有话题共用该群设置，session 仍按话题分开。其他群的设置不变。
Gateway 按其配置加载策略应用成功保存的修改；并发冲突时重试命令。
此入口针对当前部署的飞书 `main` 账号；不支持被账号级 groups 覆盖的配置。

#### 私聊配对

不用查询自己的 `open_id`。Gateway 启动后，在飞书私聊 bot，它会向
未批准的用户返回配对码。在 storie 查看请求并批准你自己的配对码：

```sh
sudo /etc/openclaw/compose exec gateway node openclaw.mjs pairing list feishu
sudo /etc/openclaw/compose exec gateway node openclaw.mjs pairing approve feishu <CODE>
```

将 `<CODE>` 替换成 bot 发给你的实际配对码。批准后再发消息即可正常
聊天，批准记录保存在持久化 state 中，普通容器重建无需重新配对。
未获批准的用户不能触发模型。不要批准不认识的请求；批准多个人会让
他们共用 Gateway，但默认私人角色、工作区和记忆各自独立。飞书用户配对与管理 UI 的设备配对
是两套独立机制。

在 new-api 中创建 OpenClaw 专用 token，限制模型及额度。所有 provider
共用已有的 `new-api-token`，不需要为 GPT、Claude、DeepSeek 另建
秘密或机器人。每个 provider 独立设置名字、API 协议和模型列表。
配置入口是 `env/guix/os/storie.scm` 的 `%openclaw-configuration`。

以下模型 ID 是占位值，替换成 new-api 实际提供的 ID。`model` 必须
填写完整的 `provider/model-id`，并且模型已列在对应 provider 中：

自定义推理模型可在 provider 中用 `(reasoning-models '("MODEL-ID"))`
显式声明；该列表必须是 `models` 的子集。OpenClaw 的 Responses 请求根据
`reasoning` 标记选择 `developer` 或 `system` 指令角色。storie 当前全部
GPT 和 Claude 模型均显式设置 `reasoning: true`；这也允许选择推理强度，
具体请求参数是否被接受仍取决于各模型的上游渠道。

```scheme
(model "new-api-gpt/GPT-MODEL-ID")
(providers
 (list
  (openclaw-provider
    (name "new-api-gpt")
    (api "openai-responses")
    (models '("GPT-MODEL-ID" "ANOTHER-GPT-MODEL-ID")))
  (openclaw-provider
    (name "new-api-claude")
    (api "anthropic-messages")
    (models '("CLAUDE-MODEL-ID")))
  (openclaw-provider
    (name "new-api-deepseek")
    (api "openai-completions")
    (models '("DEEPSEEK-MODEL-ID")))))
```

暂时不用 DeepSeek 时，先省略它的整个 `openclaw-provider`，日后补上。
每个 provider 内可列多个模型，重复 ID 去重；不同 provider 可包含
相同 ID。provider 名称必须唯一。旧的顶层 `models`、`model-api`、
`model-base-url` 字段已替换为此 `providers` 列表。

| Provider 名称 | API 协议 | 默认 base URL |
|---|---|---|
| new-api-gpt | openai-responses | http://172.31.0.9:3000/v1 |
| new-api-claude | anthropic-messages | http://172.31.0.9:3000 |
| new-api-deepseek | openai-completions | http://172.31.0.9:3000/v1 |

默认 URL 根据 `api` 选择，不根据模型名字猜测。Anthropic SDK 会追加
`/v1/messages`，所以它的 base URL 不带 `/v1`。可以在单个 provider
中用 `(base-url "...")` 显式覆盖。这里的地址都指向 new-api，真实
上游仍由 new-api 的渠道和模型映射决定。若 GPT 的渠道只提供 Chat
Completions，将它的 `api` 改为 `openai-completions`；每个渠道实际
支持的协议和推理能力需通过调用确认。

这些 ID 必须是 new-api 的客户端模型名，不能用上游映射后的内部名字。
可在 new-api 模型页面查询；若需要验证该 token 真正可见的集合，使用
该 token 调用 `GET /v1/models`，取返回数据的 `id`。token 必须允许
调用所有列出的模型。

飞书中作为普通文本发送 `/model`、`/model list` 查看模型，发送
`/model new-api-claude/CLAUDE-MODEL-ID` 切换当前会话。管理界面的聊天模型选择器也可
切换。这是会话状态；持久默认模型可用校验入口在 Guix 批准的列表中
选择。模型目录仍由 Guix 声明。多个可选模型不会自动变成失败回退列表。
