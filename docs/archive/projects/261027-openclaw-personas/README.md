# OpenClaw 家庭 persona

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

storie 上的飞书 bot 由一家人使用：每个人有自己的私人角色（独立身份和记忆），群里用
共享角色，群主或命令管理员能在飞书里切换角色、@要求和群模型，不必为每个群改 Guix。
现状见 [persona-guide](../../../openclaw/persona-guide.md)、
[config-guide](../../../openclaw/config-guide.md) 和
[scope-guide](../../../openclaw/scope-guide.md)。

## 背景

- 此前只有一个 `main` agent，所有人共用同一份身份和记忆。
- 同期的沙箱化（[261024-openclaw-podman-sandbox](../261024-openclaw-podman-sandbox/README.md)）
  让每个 agent 有独立 workspace，persona 的隔离建立在它上面。

## 主要决定

- 10/27（#53）：插件命令 `/persona`、`/mention`，共享角色 `household-shared`，私人角色
  记录所有者；私人角色只允许本人在私聊或只有本人和机器人的群里选择，群里有其他成员时
  暂停；原有 `main` 登记为单个命令管理员的默认私人角色。
- 10/27（#54）：沙箱里提供受限的 `openclaw` Python CLI 代理，经只读挂载的 Unix socket
  调 Gateway 侧的校验工具；`agents list`、`set-identity` 只作用于当前 agent，凭证由
  Gateway 的 hook 按 agent 发放。
- 10/27（#55）：打开飞书原生的静默回复，关闭 @要求的群里模型可以不回复。
- 10/28（#57）：命令管理员名单同时写入 `channels.feishu.allowFrom`，群里内置命令才能
  授权；群主按群动态查询，所以另加 `/groupmodel`。成员查询出错或超时只拒绝当前消息，
  不持久暂停，免得一次网络抖动锁住群。
- 10/28（#61）：心跳通知保持在内部，只改了 `openclaw.scm` 一行；手册现在写作
  `heartbeat.target` 显式设为 `owner`。
- 10/29（#67）：飞书话题群的事件也报 `chat_type="group"`，同一话题被拆成两个会话；
  网关镜像层加补丁 `feishu-topic-chat.mjs`，按话题分会话并让话题并行。
- 10/29（#68）：私人角色的后台命令结束后自动唤醒的运行没有发送者，按会话归属判断，
  不再要求用户重问。
- 10/30（#72）：开放 `message` 工具（仅 `send`，仅当前会话或本轮请求人的私聊），
  因为内置提示词要求登录二维码只私下发给请求人；#74 保留首条消息唤醒时的话题锚点。
- 11/05–11/06（#90、#91）：处理进度卡片，上游发现发送前检查 hook 时会关掉所有预览，
  镜像补丁只放行固定中文状态；答案卡单独发送，字号和边距可读，显示 Model / Effort。
  验证记录见 [progress-card-measure-20261106](progress-card-measure-20261106.md)。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [config-proxy-deploy-20261027](config-proxy-deploy-20261027.md)：配置代理的部署和验证记录。
- [persona-validation-measure-20261027](persona-validation-measure-20261027.md)：家庭 persona 的验证状态。
- [default-model-deploy-20261029](default-model-deploy-20261029.md)：默认模型跟随 Guix 声明的迁移说明。
- [progress-card-measure-20261106](progress-card-measure-20261106.md)：处理进度卡片的验证记录。
