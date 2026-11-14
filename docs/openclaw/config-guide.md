# OpenClaw 可写配置、不变量与命令执行

信任固定镜像中的 Gateway 及批准的插件会保留部署不变量；它们仍可使用
原生写入路径。这里不修改 OpenClaw 源码，也不使用 `$include`。

Guix 生成只读的 `/etc/openclaw/base.json`，同时作为初始配置和受管字段的
期望值。正式配置是持久化的 `/data/openclaw/home/.openclaw/openclaw.json`。
Shepherd 启动时先停止旧 Gateway，再运行 reconcile：对齐基础字段，
保留 agent、bindings、meta、wizard 和仍在批准列表中的默认模型；在镜像 schema
校验通过后替换主文件，旧配置保存在 `openclaw.json.before-guix`。
这是服务启动阶段的对齐，不是在运行中的 Guix activation 直接覆盖文件。
默认模型只在用户改过时保留：每次对齐后把本次 Guix 默认写入
`openclaw.json.guix-model`，下次启动时若运行配置仍等于这个旧默认，就跟随
新的 Guix 声明。没有该记录时采用 Guix 默认。
基础配置显式声明 `agents.defaults.systemAgent.agentId="main"`，与多 agent
启动时 Doctor 的规范化保持一致；否则重启后新增的该字段会被不变量校验
视为漂移，导致私人角色绑定等配置写入失败。

Guix 只读挂载并启用 `uraj-config-policy` 插件。清单显式声明
`activation.onStartup=true` 和 `onCapabilities=["hook"]`，保证 Gateway
启动时导入插件；仅 `enabled=true` 或 plugins list 显示 enabled 不代表
已在运行进程注册。exec 在沙箱中运行，没有 Gateway 配置或管理凭据。
插件注册 Gateway 侧工具 `openclaw_config_set`，参数为点分路径和 JSON 值，
在 Gateway 进程内调用校验入口。该工具同时列入 `tools.allow` 和
`tools.sandbox.tools.alsoAllow`。

沙箱中的 `openclaw` 是受限的 Python CLI 代理，支持：

```sh
openclaw config get agents.defaults.model --json
openclaw config set agents.defaults.model new-api-gpt/gpt-6-luna
openclaw config set agents.defaults.model '{"primary":"new-api-gpt/gpt-6-luna"}' --strict-json
```

代理通过只读挂载目录中的 Unix socket 调用同一配置工具；读操作只返回
默认模型，写操作仍受工具白名单、Guix 不变量和原生配置校验限制。
不支持其他配置路径或 unset，不透传任意参数。
所有 agent 与原配置工具一样，都能修改这个全局默认模型。
请求串行处理，忙时返回重试提示；不会给沙箱提供 Gateway token。

另支持原生初始化使用的两个 agent 命令，但只针对当前 agent：

```sh
openclaw agents list --json
openclaw agents set-identity --agent main --workspace /workspace \
  --name 'Claw老师' --theme '靠谱、清楚，有点机灵' --emoji '🦀'
openclaw agents set-identity --from-identity --json
```

`list` 仅返回当前 agent 的 ID、名称、身份字段和沙箱 workspace，不提供其他
角色、绑定、会话或记忆。示例的 `main` 应替换为 list 返回的 ID。
`set-identity` 支持 `--agent`、`--workspace`、`--name`、`--theme`、
`--emoji`、`--avatar`、`--from-identity`、`--json`；未给身份字段时也读取
当前 `IDENTITY.md`。此命令同步配置中的 identity；名称同时同步到
`/persona` 登记表，不更改角色所有人、共享范围、绑定或记忆。
`IDENTITY.md` 和 `SOUL.md` 仍由 agent 的文件工具维护。

`--workspace` 只能是 `/workspace` 或该 agent 已登记的主机路径；
不支持任意 `--identity-file`。身份文件限 64 KiB，不允许符号链接或硬链接。
头像只接受当前工作区内不超过 2 MiB 的本地文件，不支持 URL/data URI。
其他 agents 子命令、`--bindings` 和应用推荐命令仍未开放。

Gateway 的 `before_tool_call` hook 从可信上下文取得 agent ID，向其独立
workspace 写入 `.openclaw-cli-capability`（0600）。客户端自动读取并通过
请求头发送，服务端据此核对 `--agent`，不能靠命令参数冒充其他 agent。
该凭证仅授予本角色的身份查询和修改权限，不是 Gateway token；Gateway
重启后旧凭证失效，下次 exec 自动补发。不要将这个文件放入共享 skill
或复制给其他角色。它依赖已有 workspace 隔离，属于家庭共用的隔离边界。
配置和角色登记不是跨文件事务；若登记写入失败会报错，重试可完成同步。

代理目录只包含客户端和 socket，engine 不挂载 Gateway 的完整 state 目录。因代理位于各 agent 工作区之外，Guix 显式设置
`dangerouslyAllowExternalBindSources=true`；挂载列表仍不可由 agent 修改，
原生系统路径禁挂规则仍生效。

管理员也可以在 Gateway 容器内直接使用以下入口（值必须为 JSON）：

```sh
sudo /etc/openclaw/compose exec gateway node /etc/openclaw/config.mjs check
sudo /etc/openclaw/compose exec gateway node /etc/openclaw/config.mjs set \
  agents.defaults.model '"new-api-gpt/gpt-6-luna"'
sudo /etc/openclaw/compose exec gateway node /etc/openclaw/config.mjs set \
  agents.entries.research '{"name":"研究助手","workspace":"/data/openclaw/workspaces/research","agentDir":"/data/openclaw/home/.openclaw/agents/research/agent"}'
```

模型可调用的配置工具只允许修改默认模型，不能直接注册角色或修改绑定。
上述管理员 CLI 仍允许修改 `agents.entries`、默认模型和 `bindings`；
手工注册的 agent 不会自动成为 `/persona` 角色，请通过角色菜单创建。
agent 条目只允许
`name`、`identity`、`model`、`workspace`、`agentDir`；禁止工具、沙箱、
插件等覆盖。模型必须来自 Guix provider 列表。workspace 必须是 Guix
声明的 main workspace 父目录（`/data/openclaw/workspaces/`）下规范化的
绝对路径，`agentDir` 必须位于 `/data/openclaw/home/.openclaw/agents/` 下。
路径保持主机原值，因为 Podman 后端把 Gateway 路径直接作为沙箱 bind
源。这些是路径字符串检查；隔离由沙箱只挂载 workspace 提供。
其他顶层配置及默认设置由 Guix 固定；meta、wizard 留给原生维护流程。
Doctor 会将不可用的 skill 写入 `skills.entries`。对 Guix 未声明的条目，
校验允许并在重启对齐时保留纯 `{ "enabled": false }` 禁用标记；不允许
附加 env、apiKey、加载路径或启用 skill。Guix 已声明的 skill 配置仍须
完全匹配，不使用整节 skills 的宽泛豁免。
不支持 include、环境插值、任意 CLI flags 或 provider builder。

校验入口先检查请求，再在私有临时文件上执行原生 `config set`，重新检查
原生规范化后的完整结果，最后通过 Gateway `config.set` RPC 携带
`config.get` 返回的版本号提交。Gateway 的原生写入器负责并发冲突检查、
备份和配置加载；冲突直接失败，用户重试，不覆盖动态注册产生的更新。
Gateway 必须在线。批量变更可替换整个 `agents.entries` 或 `bindings`；
暂不支持多路径 batch 和删除 agent（原生 config.set 会保护已有条目）。
原生 CLI schema 不接受的操作仍会失败。错误不打印原生诊断或配置值，
避免意外输出凭据；管理员可在受控终端进一步诊断。

沙箱只挂载 agent 自己的 workspace，看不到 Gateway 的配置、状态和凭据，
配置修改只能经过校验工具。各 agent 的 workspace 仍在同一 UID 下，
尚不是多用户隐私隔离。
`channels.feishu.configWrites=true` 允许可信插件写回；用户注册由本仓库
角色插件处理，不启用飞书的 `dynamicAgentCreation`。群聊以 `groupPolicy="open", requireMention=true` 开放测试。
另允许通过群命令修改 `channels.feishu.groups.<oc_ID>.requireMention`，
只接受布尔值并在重启时保留；其余 channels 字段仍由 Guix 管理。
模型配置工具不能修改该字段，避免绕过群主/命令管理员检查。
另由 Guix 设置 `surfaces.feishu.silentReply.group="allow"`：关闭某群的
@要求后，未 @机器人的普通消息可以由模型判断不回复，使用原生
`NO_REPLY` 协议结束。私聊、明确 @和授权命令仍要求回应。
这与消息准入是两个独立设置，不会替其他群关闭 @要求；只影响飞书群聊。
判断是否回复仍需模型调用，但允许静默后不会仅因缺少可见回复强制补答。
