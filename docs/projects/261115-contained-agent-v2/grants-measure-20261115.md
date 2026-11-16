# 不用 root 的动态授权实测（2026-11-15）

TODO 第 8 步。问题：盒子管理服务只有用户身份，能不能在盒子运行中改网络规则、
增减挂载，而盒子里的 agent 做不到。

## 做法

在 lappie 上用路线 C 的盒子（`exp/contained-agent-v2-route-c_20261115/box.sh`），
主机终端以普通用户运行 `exp/contained-agent-v2-grants_20261115/grants.sh`。

- 盒子由 `contained-podman` 主机服务起，命名空间是两层：rootless Podman 的 user 和
  mount namespace（conmon 所在，和主机共用 netns），盒子自己的 user、net、mount
  namespace 在它下面。主机用户拥有外层 user namespace，所以在两层里都有全部能力。
- 网络：`nsenter --user=<conmon 的 user ns> --net=<盒子的 net ns> nft -f -`。
- 挂载：`nsmount.py` 先进入外层的 user 和 mount namespace（这里能看到主机路径），
  `open_tree(OPEN_TREE_CLONE | AT_RECURSIVE)` 克隆主机目录，再进入盒子的 user 和
  mount namespace，`move_mount` 挂到目标路径；撤销用 `umount2(MNT_DETACH)`。
- agent：在盒子里以 uid 1000 执行同样的操作。

## 结果

| 项 | 结果 |
|---|---|
| 在盒子 netns 加 nftables 表 | 成功，不用 root |
| 加规则后：主机上监听所有地址的端口（经 `169.254.1.2`） | 连不上（加之前能连） |
| 加规则后：公网、relay（规则里显式放行 relay 的 IP） | 都通 |
| 加规则后：DNS（pasta 的 `169.254.1.1`） | 正常，公网按域名访问通过 |
| 删除这张表 | 成功，主机端口恢复可达 |
| agent：`nft list ruleset`、`nft flush ruleset` | EPERM |
| agent：`nsenter --net=/proc/1/ns/net nft flush ruleset` | EPERM |
| agent：先 `unshare -Ur` 再 `nsenter` 进盒子 netns | 打不开 `/proc/1/ns/net`，失败 |
| agent：`unshare -Urn nft list ruleset` | 成功，但那是它自己新建的空 netns，对盒子没有影响 |
| 规则在 agent 尝试之后 | 仍然生效 |
| 往运行中的盒子挂主机目录 | 成功，不用 root；盒子里可读写，盒子里写的文件在主机上属主是用户自己 |
| agent：卸载这个挂载、自己 bind mount | 都失败 |
| 撤销挂载 | 成功，盒子里路径消失 |
| 撤销前打开的 fd | 撤销后仍能读 |

## 结论

- 网络限制和运行中增减挂载都能由用户级的盒子管理服务完成，不需要 root，agent 绕不过去。
  按目的地址过滤可以在盒子自己的 netns 里做，用 pasta 也能禁主机和内网，所以不需要
  为此换 bridge。
- 撤销挂载只拦住以后的访问。要彻底收回，得杀掉持有 fd 的进程或重建盒子；设备也一样。

## 没测到的和要注意的

- 局域网那项：用作目标的网关 80 端口加规则之前就没有响应，所以测不出规则对局域网的效果。
  内网网段的规则和 `169.254.1.2` 的规则写法一样，后者已生效。
- 规则用的是 `reject`，curl 的表现却是 5 秒超时，而不是连接被拒。正式实现可以对 TCP 用
  `reject with tcp reset`，让程序立刻失败。
- 原型盒子里没有嵌套 Podman。嵌套容器经盒子里的 pasta 出网，socket 在盒子的 netns 里，
  按理也受这些规则约束，要在带嵌套 Podman 的盒子里再确认。
- 主机服务的 rootless user namespace 是挂载的入口。如果以后盒子不再由
  `contained-podman` 起，这个入口要跟着换。
