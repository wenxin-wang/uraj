# 第 5 步交接：继续讨论盒子设计（2026-11-15）

先读：

1. [README](README.md)：目标、已定的事、待定项。待定项是这次讨论的主线。
2. [TODO](TODO.md)
3. [paseo-route-design-20261115](paseo-route-design-20261115.md)：已选路线 C。
4. [route-c-measure-20261115](route-c-measure-20261115.md)：路线 C 原型实测。
5. [box-prototype-design-20261115](box-prototype-design-20261115.md)：盒子的
   Guix rootfs 和嵌套 Podman。
6. [grants-measure-20261115](grants-measure-20261115.md)：不用 root 的动态授权实测。

## 现在在哪

| 环节 | 状态 | 代码 |
|---|---|---|
| 盒子 rootfs 原型（Guix profile、嵌套 Podman） | 实测通过，#106 | `exp/contained-agent-v2-box_20261115/` |
| Paseo 接盒子的路线 | 人选 C（原生 connected hosts） | |
| 盒子网络、reflink | 实测完，#107 draft | `exp/contained-agent-v2-workspace-box_20261115/` |
| zombie pasta | 查清：运行时的 inner podman 是 PID 1，不回收孤儿；盒子要用 init | 同上 |
| 路线 C 原型 | 桌面 app 经测试主机 daemon 用盒子里的 workspace、终端、文件、diff；建 agent 未做 | `exp/contained-agent-v2-route-c_20261115/` |
| 动态授权（不用 root） | 实测通过：nftables、运行中加撤挂载，agent 绕不过 | `exp/contained-agent-v2-grants_20261115/` |
| 设备授权 | 已定方向，TODO 第 9 步待实测 | |
| 正式代码 | 未开始；现有 contained-agent 不为 v2 改动 | |

#106 是 #107 的 base，都还没合并。

## 下一步：要和人讨论的设计

11/15 这一轮又定了 workspace 的含义和文件布局、共享路径、设备授权的方向、网络用 pasta 加 nftables、策略目录（放 space 仓库、YAML 最小子集）、topic 和 workspace 的对应，见 README。还剩：

1. **agent 创建 workspace 的细节**。README 里有建议的接口、请求内容和执行者；确认
   卡片的内容和删除流程还没讨论完。
2. **策略目录和 v1 简报的关系**。策略放哪、结构、语法已定（见 README）；还没定的是
   khalis 里那份简报（原本给 v1 写）是不是只在 v2 实现，以及“改 `policy/` 的 PR
   只改 `policy/`”要不要做成检查。

可以并行做的：

- TODO 第 9 步：设备授权实测。挂载可以照搬 `exp/contained-agent-v2-grants_20261115/nsmount.py`
  （设备节点也是 bind mount），组权限参考 v1 浏览器 GPU
  （`docs/contained-agent/browser-guide.md`）。
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
