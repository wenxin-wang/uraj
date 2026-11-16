# 盒子的网络和 reflink 实测（2026-11-15）

在 lappie 上实测 [box-prototype-design-20261115](box-prototype-design-20261115.md)
的盒子：盒子里的进程能连到哪里，以及仓库用 reflink 拷进盒子的代价。脚本在
`exp/contained-agent-v2-workspace-box_20261115/`（`net.sh`、`reflink.sh`），盒子由
`KEEP=1 exp/contained-agent-v2-box_20261115/run.sh` 起。下文用占位符代替地址：
`<host-lan>` 主机的局域网地址，`<gateway>` 局域网网关，`<relay>` Paseo relay。

## 盒子的网络配置

- `contained-podman` 服务没有设 `pasta_options`，用 Podman 6.1.4 的默认值。
- pasta 让盒子沿用主机的局域网地址 `<host-lan>/24` 和默认路由 `via <gateway>`。
- `/etc/hosts` 里 `host.containers.internal` 指向 `169.254.1.2`；`resolv.conf`
  的第一个 nameserver 是 `169.254.1.1`。

## 可达性

主机上起两个临时 HTTP 服务：一个只监听 `127.0.0.1`，一个监听 `0.0.0.0`。每次连接
超时 5 秒。

| 从盒子访问 | 结果 |
|---|---|
| `127.0.0.1`（盒子自己的回环） | 拒绝 |
| 主机上只监听 `127.0.0.1` 的端口，经 `host.containers.internal`、`169.254.1.2`、`<gateway>` | 无响应 |
| 主机 Paseo daemon（默认端口，只监听回环），经同样三种地址 | 无响应 |
| 主机上监听 `0.0.0.0` 的端口，经 `host.containers.internal` 或 `169.254.1.2` | **通** |
| 主机上监听 `0.0.0.0` 的端口，经 `<gateway>` | 无响应（`<gateway>` 是真正的路由器） |
| `<host-lan>` 上的两个端口 | 拒绝：这个地址在盒子里是盒子自己 |
| `<gateway>:80`（局域网里的另一台机器） | 通 |
| `<relay>` | 通（HTTP 404） |
| 公网 https | 通 |

结论：

- “盒子不能访问主机回环”在默认配置下成立，主机 daemon 连不到。
- 但主机上监听所有地址的服务，盒子经 `169.254.1.2` 都能连到。要堵住，得关掉 pasta 的
  这个地址映射，参数还没验证。
- 局域网和 relay 都通。pasta 不能按目的地址过滤，以后禁止访问内网要换成 bridge 加
  [受限网络](../../restricted-network.md)，代价是 root 侧把 veth 接进盒子的 netns。

## reflink

`reflink.sh` 把 `~/src/uraj` 拷到 `~/.local/share/contained-agent` 下：

| 项 | 结果 |
|---|---|
| 文件系统 | 两边都是同一个 btrfs 子卷，支持 reflink |
| 大小 | 1221 个文件，9.1M，其中 `.git` 4.8M |
| 拷贝耗时 | 0.04 s（没控制缓存冷热） |
| 新增占用 | 0（`btrfs filesystem du` 的 Exclusive 为 0） |
| 拷贝后第一次 `git status` | 1.07 s；index 里的 stat 缓存失效，之后恢复正常 |

这是一个小仓库，大仓库的耗时还没测。

## 顺带看到的

主机上有 36 个 `pasta.avx2` 进程是 `<defunct>`。后来查明来自项目 Podman 运行时里的
inner podman 服务，不是主机服务，见
[pasta-zombie-debug-20261115](pasta-zombie-debug-20261115.md)。
