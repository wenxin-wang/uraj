# 第 5 步交接：继续讨论盒子设计（2026-11-15）

先读：

1. [README](README.md)：目标、已定的事、待定项。待定项是这次讨论的主线。
2. [TODO](TODO.md)
3. [paseo-route-design-20261115](paseo-route-design-20261115.md)：已选路线 C。
4. [route-c-measure-20261115](route-c-measure-20261115.md)：路线 C 原型实测。
5. [box-prototype-design-20261115](box-prototype-design-20261115.md)：盒子的
   Guix rootfs 和嵌套 Podman。

## 现在在哪

| 环节 | 状态 | 代码 |
|---|---|---|
| 盒子 rootfs 原型（Guix profile、嵌套 Podman） | 实测通过，#106 | `exp/contained-agent-v2-box_20261115/` |
| Paseo 接盒子的路线 | 人选 C（原生 connected hosts） | |
| 盒子网络、reflink | 实测完，#107 draft | `exp/contained-agent-v2-workspace-box_20261115/` |
| zombie pasta | 查清：运行时的 inner podman 是 PID 1，不回收孤儿；盒子要用 init | 同上 |
| 路线 C 原型 | 桌面 app 经测试主机 daemon 用盒子里的 workspace、终端、文件、diff；建 agent 未做 | `exp/contained-agent-v2-route-c_20261115/` |
| 动态授权（不用 root） | 只有设计，TODO 第 8 步待实测 | |
| 正式代码 | 未开始；现有 contained-agent 不为 v2 改动 | |

#106 是 #107 的 base，都还没合并。

## 下一步：要和人讨论的设计

按 README 待定项的顺序，人点名的有三块：

1. **agent 怎么创建 workspace**。人已同意大方向：授权声明式（权限集在策略仓库，改动
   走 PR），workspace 命令式（agent 发请求，人在手机上确认，之后一直存在，显式删除）；
   运行中改授权由用户级的盒子管理服务负责。没讨论的细节：agent 发请求的接口
   （盒子里一个 socket？Paseo plugin？）；请求里写什么（名字、仓库及来源、引用的
   权限集、一句目的说明）；确认渠道和卡片内容（参考 README 里已定的审批卡片规则）；
   人确认后由谁建盒子、拷仓库、起盒子 daemon、`host add`；删除时怎么检查未推送的
   提交。
2. **设备，比如调试 MAA 要 GPU**。现有 contained-agent 的浏览器 GPU 透传可以参考
   （`docs/contained-agent/browser-guide.md`）。要讨论：设备是不是一种权限集；
   只能在创建盒子时给，还是运行中也能加；adb 这类网络或 USB 访问怎么算。
3. **策略仓库**。khalis 里有一份“机器人账号加私有明文策略仓库”的简报，还没在 uraj
   实现。要讨论：v2 的权限集、workspace 请求放不放在同一个仓库；目录结构和语法；
   v1 的 `projects.scm` 条目怎么迁过去，还是 v1、v2 各用各的。

另外两件可以并行：

- TODO 第 8 步的实测：盒子管理服务以用户身份进入盒子的 netns 设 nftables、往运行中
  的盒子加撤挂载，并确认盒子里的 agent 做不到。结果决定还要不要 bridge。脚本可以从
  `exp/contained-agent-v2-route-c_20261115/box.sh` 起盒子，主机侧用
  `podman inspect --format '{{.State.Pid}}'` 拿 PID 再 `nsenter`。
- 第 5 步本身：列出现在 agent 容器的挂载、synthetic HOME、凭据和设备
  （`src/guile/uraj/bin/contained-agent.scm`、`docs/contained-agent/container-guide.md`），
  逐项决定在盒子里怎么实现。

## 已知的坑

- 实测脚本都要人在主机终端跑：agent 会话碰不到 `contained-podman` 服务的 socket。
  输出写到 worktree 根目录的 `*.log` 让 agent 读，读完删掉；不要把输出重定向进
  `exp/` 里的脚本文件。
- 盒子重建要删 `$PASEO_HOME/paseo.pid`，保留 `server-id`。
- 盒子里的 `paseo` CLI 要显式传 `--host`；主机上的 CLI 不带 `--host` 会连到人正在
  用的 `~/.paseo`。
- 打包的 Paseo CLI 把 `PASEO_NODE_ENV` 写死成 `production`，mock provider 用不了；
  测 agent 要真的 coding agent 和凭据。
- 桌面 app 升级后要彻底退出旧进程，否则一直是旧版本（#108）。
- 文档和脚本不写私有地址；`exp/` 脚本的地址都用参数传。
