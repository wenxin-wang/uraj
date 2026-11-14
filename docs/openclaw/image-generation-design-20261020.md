# OpenClaw 图片生成接入

> 迁移自 `docs/openclaw.org` 的 “图片生成接入”（2026-11-14，内容未改）。

## 图片生成接入

聊天模型与图片模型是两项配置。单独把 Luna 切换成 Sol 或 Astra，
不会启用图片生成。上游当前版本提供独立 `image_generate` 工具，需
图片 provider 的凭据、可用图片模型以及工具白名单授权；`image` 或
看图能力也不等于图片生成。

若继续通过 new-api 接入，先确认其实际开放的图片模型 ID、图片生成及
编辑接口、token 权限，以及部署镜像支持的图片 provider 配置。
上游当前文档使用 `agents.defaults.mediaModels.image.primary` 选择
图片模型，但不能据此假定固定镜像支持该字段。现有聊天 provider 的
Responses 支持也不能证明图片接口可用。当前尚未配置图片生成。

可在 storie 的仓库根目录运行只读检查：

```sh
sudo sh scripts/openclaw/inspect-runtime
```

该脚本输出运行中容器的包版本、文件工具配置和 new-api token 可见的
模型 ID。凭据在容器内读取，不输出 token、完整配置或上游错误正文；
只请求固定 new-api 地址的 `GET /v1/models`，不跟随重定向，也不发起
图片生成。模型出现在列表中仍不能证明图片接口调用成功，需另做实际
生成验收。此脚本也不执行文件工具，不能替代工作区越界测试。

参考：[OpenClaw 图片生成](https://docs.openclaw.ai/tools/image-generation)、
[补丁工具](https://docs.openclaw.ai/tools/apply-patch)、
[工具白名单](https://docs.openclaw.ai/gateway/config-tools/tool-policy)、
[OpenAI 图片生成 API](https://developers.openai.com/api/docs/guides/image-generation)。
