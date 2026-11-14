# agent-browser

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。横跨 OpenClaw 和 contained-agent 两个模块：
OpenClaw 一侧的过程记在这里，contained-agent 一侧的过程文档在同一目录，
以 `contained-agent-*.md` 命名。

## 目标

让 agent 能真实地上网：有头的 Chromium，用得上 GPU，登录状态由人发布快照、任务各用
副本，需要时人能接管浏览器。OpenClaw 一侧见 [browser-guide](../../../openclaw/browser-guide.md)，
contained-agent 一侧见 [browser-guide](../../../contained-agent/browser-guide.md)。

## 背景

- 10/07 桌面 Home 和 contained-agent 先有 agent-browser 的 skill（`441a694`），10/12
  修了容器里找不到 agent-browser 的问题（`30dfd6a`）；那时还没有登录快照和 GPU。
- OpenClaw 沙箱化（[261024-openclaw-podman-sandbox](../261024-openclaw-podman-sandbox/README.md)）
  后，沙箱里的浏览器成了新的需求。

## 主要决定

- 10/28（#56）：沙箱镜像换成 Debian trixie，带 agent-browser、浏览器、Xvfb 和中日韩及
  emoji 字体；服务加 `skills` 字段，由 Gateway 加载 skill 再复制进沙箱；空闲 30 分钟关闭
  浏览器；登录状态按角色保存。分支上先用官方 Chrome（`44ff74d`，10/27），随后改用
  Debian 的 chromium（`193d95d`）。
- 10/28（#59）：角色登录快照：主登录目录与任务副本分开，任务各用独立 session 和 profile。
- 10/29（#65）：改成 headless Chromium 加 ANGLE Vulkan，storie 的 render node 经 Docker
  和 rootless Podman 传给沙箱。
- 10/29（#69）：#65 部署后小红书、京东、百度都出风控页，改回有头模式，用每个 Chromium
  私有的 cage 合成，Vulkan 合成、WebGL 直接用 render node；同一 PR 让 skill 只陈述证据，
  不猜测被拦的原因。取舍记录见 [headed-browser-debug-20261029](headed-browser-debug-20261029.md)。
- 10/29：快照方案上线，见 [profile-snapshot-deploy-20261029](profile-snapshot-deploy-20261029.md)。
- 10/30（#75、#76）：skill 围绕登录生命周期精简；启动登录等待后自动检查并在原话题报告，
  不要求对方回复。
- 11/01（#77）：contained-agent 用同样的设计：用户在主机上保存一个登录身份并发布快照，
  容器只读看到 `published/`，任务在会话的 tmpfs 里 fork；启动器把 render node 连同
  `/sys/dev/char` 和设备的 sysfs 目录暴露给容器；包装器把 cage 和 Chromium 的 stderr
  写日志文件，免得启动日志填满管道而永久阻塞。
- 11/01（#80）：没有发布过登录时，容器里的任务从空 profile 开始，不再拒绝公开站点；
  skill 说明 Codex 自带的沙箱没有 render node，要看页面里的 renderer 判断是否用了 GPU。
- 11/04（#84）：重建沙箱会换主机名，旧沙箱遗留的 `SingletonLock` 会让 Chromium 一直
  报资料被占用；`browser-profile` 启动前检查没有本地进程使用该目录后清除这种锁。
- 11/06（#89）：浏览器 dashboard 供人接管；`browser-dashboard.py` 经 SSH 转发 OpenClaw
  沙箱里的 dashboard；两边的 skill 都有交接流程。部署和沙箱重建见
  [dashboard-rollout-deploy-20261106](dashboard-rollout-deploy-20261106.md)。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [profile-snapshot-deploy-20261029](profile-snapshot-deploy-20261029.md)：Profile 快照方案上线。
- [headed-browser-debug-20261029](headed-browser-debug-20261029.md)：有头模式的取舍。
- [dashboard-rollout-deploy-20261106](dashboard-rollout-deploy-20261106.md)：dashboard 修复的部署和沙箱重建。

contained-agent 一侧的过程文档以 contained-agent-*.md 命名。
