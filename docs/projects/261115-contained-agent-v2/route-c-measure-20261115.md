# 路线 C 原型实测（2026-11-15）

在 lappie 上验证 [paseo-route-design-20261115](paseo-route-design-20261115.md)
的路线 C：盒子里跑一个 Paseo daemon，主机 daemon 用 connected hosts 经 unix socket
登记它，app 只和主机 daemon 配对。脚本在 `exp/contained-agent-v2-route-c_20261115/`。
Paseo 0.15.4。

## 搭法

- **盒子**（`box.sh`）：由 `contained-podman` 服务启动，rootfs 是只读 `/gnu/store`
  加一个 Guix profile（paseo、socat、catatonit、git 等）。PID 1 是 catatonit。
  盒子 daemon 监听盒子自己的回环 `127.0.0.1:6767`（保留 agent 的 Paseo MCP），
  盒子里的 socat 把它转成 `/run/box/paseo.sock`，这个目录挂到主机上。relay 和密码
  都关掉。没有嵌套 Podman，也没有 coding agent 和凭据。
- **测试主机 daemon**（`host.sh`）：独立的 `PASEO_HOME` 和端口，不碰人正在用的
  daemon；`paseo host add unix://<sock>` 登记盒子，开 relay 后用新的配对链接把桌面
  app 配给它。

## 结果

| 检查 | 结果 |
|---|---|
| 盒子进程 | catatonit → daemon → supervisor、terminal worker、socat，都在盒子里 |
| 盒子里的 CLI 建 workspace、终端 | 通过 |
| 主机经 unix socket 直连盒子 daemon | 通过 |
| 主机 daemon 登记盒子 | 通过，状态 `online`，记下盒子的 serverId |
| 盒子重建后 | 主机 daemon 自动重连同一个 serverId（盒子 daemon 的 home 保留） |
| app 自动出现盒子 host | 通过（桌面 app 0.15.4） |
| 盒子 host 下的 workspace | 通过 |
| 在 workspace 里开终端 | 通过；`id` 为盒子里的 `podman`（1000），cwd 是 `/home/podman/work/demo`，`/run/box` 里只有 `paseo.sock` |
| 浏览文件和 git diff | 通过 |
| 建 agent | 失败：provider 列表是默认的，没有可用模型；盒子里没装 coding agent，也没有凭据。符合预期，留给“agent 进盒子”那一步 |

## 坑

- **桌面 app 必须 0.13 以上**才会自动发现中转的 host。lappie 上 reconfigure 后桌面 app
  仍是 0.11.4：旧进程从升级前一直没退出，再启动 `paseo-desktop` 只会把旧窗口叫到前台。
  退出旧进程后重启即可。
- **盒子重建时要删 Paseo 的 PID 锁**：锁里的 PID 在本次开机内仍存在就算“正在运行”。
  新盒子里 PID 分配和旧盒子一样，daemon 会把自己当成旧 daemon，直接以 0 退出。
  `server-id` 要保留，主机 daemon 按它固定身份。
- **盒子里的 CLI 要显式传 `--host`**：盒子设了 `PASEO_HOME`，CLI 拒绝同时有
  `PASEO_HOST`。不带 `--host` 也不带 `PASEO_HOST` 时，CLI 连的是本地 home 的 daemon。
- **打包的 CLI 把 `PASEO_NODE_ENV` 写死成 `production`**，开发用的 mock provider 用不了，
  原型里没法不靠凭据测 agent。

## 没做的

- 盒子里的 agent：装 coding agent、给凭据、经主机 daemon 收发消息和审批。
- 推送、MCP 注入在盒子里的实际效果。
- 盒子里同时跑 Paseo daemon 和嵌套 Podman。
- 手机 app。
