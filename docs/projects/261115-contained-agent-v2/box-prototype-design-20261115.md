# 盒子原型：Guix rootfs 加嵌套 Podman（2026-11-15）

## 问题

盒子要同时装 coding agent 和 Podman。现在的 Podman 运行时用
`quay.io/podman/stable`（Fedora），里面没有 agent 的 Guix 环境。要验证：盒子能否
不用 Fedora 镜像，软件全部来自 Guix，同时嵌套 rootless Podman 仍有完整的
subordinate ID 段，能跑切换 UID 的镜像。

## 为什么不用 Guix 容器直接当盒子

- 非特权的 `guix shell --container` 和 `guix system container` 只往
  `uid_map` 写自己一个 UID。盒子里的 Podman 只能 `ignore_chown_errors`，
  Postgres 这类入口切到其他 UID 的镜像跑不起来。
- 补上 `newuidmap` 的启动器不能在会话里跑（broker 的 user namespace 里
  subordinate ID 用不了，会话结束 PID namespace 会杀掉盒子），只能做成主机侧
  长期服务。再加上 exec 和 stdio、cgroup 委托、pasta、idle 回收，就是在重写
  rootless Podman 的外层。
- `guix system container` 以 root 运行时盒子就是真 root，太宽。

所以盒子仍由 `contained-podman` 服务用 rootless Podman 启动，只把 rootfs
换成 Guix 的。

## 方案

和现在 `src/python/uraj/contained_podman.py` 启动运行时的参数一致（keep-id、
嵌套 seccomp、私有 cgroup、`/dev/fuse`），差别：

| 项 | 现在 | 原型 |
|---|---|---|
| rootfs | Fedora 镜像，按 digest 固定 | `podman run --rootfs` 一个几乎空的目录，只读挂 `/gnu/store`；软件来自一个 Guix profile（[manifest](../../../exp/contained-agent-v2-box_20261115/manifest.scm)） |
| 运行时身份 | 镜像 ID | profile 的 store 路径，profile 要有 GC root |
| `newuidmap`、`newgidmap` | 镜像自带，file capability | 启动时盒子内 root 复制到允许 suid 的 tmpfs `/run/privileged/bin`，再 `setcap`；Guix 的 podman 包装脚本本来就在这里找 |
| 降权到 UID 1000 | `setpriv` | `unshare --setgid=1000 --setuid=1000`；Guix 的 util-linux 没编 `setpriv`。不带 namespace 选项时只清附加组、切 ID |
| `/etc/containers` | 镜像提供 | 生成 `policy.json`、`registries.conf`、`storage.conf`，`containers.conf` 加 `helper_binaries_dir` 指向 profile |
| seccomp 基础规则 | 镜像的 `seccomp.json` | 原型仍从 Fedora 镜像取，正式实现要换来源 |

`/gnu/store` 里的文件不能带 setuid 位或 file capability，所以这两个程序只能在
盒子自己的 user namespace 里复制并赋权，不需要主机 root。同样的做法也适用于其他
需要特权位的 Guix 程序。

## 实测

lappie，主机 `contained-podman` 服务 rootless，subordinate ID
`165536:65536`。脚本：[`run.sh`](../../../exp/contained-agent-v2-box_20261115/run.sh)。

| 检查 | 结果 |
|---|---|
| 盒子启动，盒子里 Podman 的映射 | 通过；`0→1000, 1..999→1..999, 1000..65534→1001..`，和现在的运行时一致 |
| Postgres 17 alpine | 通过；进程以 `postgres` 用户运行 |
| 自建网络内按容器名互访 | 通过 |
| 盒子里的进程访问 `-p 18080:80` 的 `127.0.0.1:18080` | 通过；agent 放进盒子后访问发布端口是透明的 |
| 盒子里的 Podman | crun、overlay、netavark |

`newuidmap` 的赋权方式（`DIAG=1`）：

| 做法 | 结果 |
|---|---|
| setuid 副本 | setuid 本身生效（setuid 的 `id` 显示 `euid=0`，`NoNewPrivs: 0`，tmpfs 无 `nosuid`），但写 `uid_map` 报 EPERM |
| `setcap cap_setuid+ep` 副本 | 成功写入多段映射 |

没有追查内核拒绝 setuid 做法的具体检查；Fedora 镜像同样用 file capability。

## 坑

- 跑过一次后 rootfs 里有属于 subordinate ID 的文件，主机用户删不掉，要
  `podman unshare rm -rf`。
- 清理时盒子的 cgroup 可能还没排空，`rmdir` 失败；正式实现照现在的
  `remove_cgroup` 等它排空。

## 没做的

- agent 还没放进盒子：缺 `/gnu/store` 以外的 agent 环境、凭据 socket、
  synthetic HOME，以及主机侧 exec 和 stdio 透传。
- 盒子里没有 Guix daemon socket，盒子里还不能 `guix shell`。
- 盒子出网仍走 pasta，没接受限网络。
