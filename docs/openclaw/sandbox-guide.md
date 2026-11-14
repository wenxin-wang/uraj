# OpenClaw 执行沙箱

> 迁移自 `docs/openclaw.org` 的 “执行沙箱”（2026-11-14，内容未改）。

## 执行沙箱

Shepherd 用 compose 同时启动 Gateway 与引擎容器 `engine`。引擎内运行
rootless Podman API，socket 在 `/run/openclaw-engine/podman.sock`，只挂给
Gateway；Gateway 以上游 `backend: "podman"` 经 `CONTAINER_HOST` 创建沙箱，
不接触宿主 Docker socket。`mode: "all"`、`scope: "agent"`、
`workspaceAccess: "rw"`：每个 agent 一个长期沙箱，直接读写自己的
workspace。`tools.exec.host` 为 `sandbox`，`tools.elevated.enabled` 为 false，
沙箱不可用时失败，不回退到 Gateway。

| 组件 | 网络 | 挂载 | 凭据 |
|---|---|---|---|
| Gateway | `static-agent` | home、workspaces、引擎 socket、`/etc/openclaw` | 有 |
| 引擎 | `sandboxed-agents` | workspaces、引擎存储、socket、两处只读 state | 无 |
| 沙箱 | 经引擎 pasta 出网 | 自己的 workspace（容器内 `/workspace`） | 无 |

上游 Podman 后端不做路径转换：Gateway 中的 state 与 workspace 路径就是
bind 源，因此 Gateway 和引擎都把它们挂在宿主机相同的绝对路径。除 workspace
外，OpenClaw 还把 state 下两个目录只读挂入沙箱：`rw` 沙箱的 skill 副本
`.openclaw/sandbox/skills-workspaces` 和子 agent 附件
`.openclaw/attachments/subagents`。引擎只读挂载这两个目录，准备程序预先创建；
其余 state（配置、认证、会话）仍不进入引擎。沙箱只覆盖
exec、process 和文件工具；web_fetch、web_search、原生插件和 MCP 仍在
Gateway 执行。本部署开放 web_fetch，它沿用 Gateway 的 `static-agent`
出网规则，并保留上游默认的内网地址拦截。web_search 未开放：2026.10.3
镜像没有打包 DuckDuckGo、SearXNG 等免 key provider，内置的 Brave、Gemini
等需要 API key；经 new-api 的自定义 Responses 地址也不触发 OpenAI 原生搜索。

`sandboxed-agents` 与 Gateway 的 `static-agent` 是不同网桥，沿用同一份
网络策略：继承宿主 DNS，公网 TCP 80/443，其他内网、宿主和已登记网段都被
拒绝，包括 Gateway 与 new-api。以后放行某个内部服务，在该网络的
`forward-exceptions` 中声明。沙箱使用 `network: "pasta"`，流量从引擎容器
的网卡离开，受上述规则约束；`none` 也可用于不需要联网的场景。

Gateway、引擎内的 Podman 用户和沙箱共用 UID/GID 2010（宿主账号
`openclaw`）。引擎内部的从属 ID 为 524288 起的 65536 个。引擎镜像必须
用相同 UID/GID 构建，否则 newuidmap 或 keep-id 映射失败。引擎对所有沙箱
统一限制 8 GiB 内存和 4096 个进程；Docker 以只读方式挂载 cgroup，暂不对
单个沙箱限额。

管理员通过 `log-readers` 组读取 workspace，例如收集报告：
`/data/openclaw` 为 `root:log-readers 0750`，`workspaces` 与 `workspaces/main`
为 `openclaw:openclaw 0750`，再加访问与默认 ACL `g:log-readers:rX`。新文件
按默认 ACL 授予该组读取，但受创建模式的 mask 限制：0644 的文件可读，0600
的不可读。workspace 不能属于 `log-readers` 或带 setgid：crun 在 keep-id 下以
容器 root 于 workspace 内创建挂载点，只有属主和属组都已映射时它才有 DAC
越权，否则报 ``openat2 `workspace`: Permission denied``。
home 与引擎存储仍为 0700，不对该组开放。
