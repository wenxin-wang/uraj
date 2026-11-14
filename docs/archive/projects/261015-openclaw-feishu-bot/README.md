# OpenClaw 飞书 bot

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。目录日期取设计分支上的第一个提交
（10/15，`1a3d864`），合入 `main` 是 10/20（#15）。

## 目标

在 storie 上用 Guix 部署 OpenClaw Gateway，接飞书做 bot，经 new-api 调用模型，
运行配置受检查，exec 策略可控。现状见 [scope-guide](../../../openclaw/scope-guide.md)、
[deploy-guide](../../../openclaw/deploy-guide.md)、[feishu-guide](../../../openclaw/feishu-guide.md)
和 [images-guide](../../../openclaw/images-guide.md)。

## 背景

- OpenClaw 官方镜像不带可用的飞书插件依赖；服务器启动时不联网装插件，所以镜像要自己
  准备，部署层再补丁。
- 飞书用 WebSocket 长连接，不需要公网地址；模型统一走 storie 上的 new-api。
- 首次部署的问题（热更新闭包缺模块、SDK 解析失败）见
  [missing-shepherd-debug-20261020](missing-shepherd-debug-20261020.md) 和
  [sdk-resolution-debug-20261020](sdk-resolution-debug-20261020.md)。

## 主要决定

- 10/15–10/20（#15）：Shepherd 服务、Compose、SOPS 三个独立凭据、固定 image ID；
  修复运行时镜像里的飞书 SDK 解析；Docker 日志经 syslog 路由；HOME 可写、受管配置只读。
- 10/18（#15 内）：先用补丁镜像给已受理的消息打 GET 表情（`0f983cd`），当天改用飞书插件
  内置的 `typingIndicator`（`806105d`），补丁不再维护。
- 10/20：个人身份不写进 Guix 配置（`be0fcc6`）。
- 10/21：检查过的运行配置，开放 exec（`2830046`）；原生 `config set` 经插件 hook 转到
  校验工具（`d19420f`）。
- 10/22：exec 策略只声明 `mode="full"`（`38490f5`）；hook 插件在 Gateway 启动时激活
  （`4ca6cae`）；保留 Doctor 写入的禁用 skill 条目（`ef145d5`）。
- 10/20：图片生成接入方案只写了设计，没有实施，见
  [image-generation-design-20261020](image-generation-design-20261020.md)。
- 10/28（#60）：默认模型改为 GPT-6 Astra。
- 10/29（#66）：默认模型跟随 Guix 声明；声明图片输入；开放 `web_fetch`；
  `new-api-gpt` 发送 `prompt_cache_key`。
- 10/30（#71）：Codex 上游按 `Session-Id` 头路由缓存，在 new-api 渠道里用参数覆盖补头，
  实测见 [prompt-cache-measure-20261030](prompt-cache-measure-20261030.md)。
- 11/03（#83）：Astra 的默认 thinking 改为 `xhigh`。
- 11/10（#92）：`herd restart openclaw TAG` 在 reconfigure 后也能带上参数
  （同时改了 new-api 和 paseo-relay）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [missing-shepherd-debug-20261020](missing-shepherd-debug-20261020.md)：部署后没有 Shepherd 服务的排查。
- [image-generation-design-20261020](image-generation-design-20261020.md)：图片生成接入方案，未实施。
- [first-start-deploy-20261020](first-start-deploy-20261020.md)：首次部署的步骤说明。
- [first-validation-measure-20261020](first-validation-measure-20261020.md)：首次集成的验证记录。
- [sdk-resolution-debug-20261020](sdk-resolution-debug-20261020.md)：飞书 SDK 解析失败的排查。
- [prompt-cache-measure-20261030](prompt-cache-measure-20261030.md)：提示缓存的实测。
