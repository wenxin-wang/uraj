# OpenClaw 引擎参数的验证

## 引擎参数的验证

引擎的放宽参数沿用 contained-agent Podman runtime 原型的经验，但那是在
rootless Podman 外层上验证的，Docker 外层另做了一次性验证。更换引擎基础
镜像、Docker 或内核后，可用它单独诊断 seccomp、keep-id 和存储驱动。
它使用上游 UID 1000 镜像与 Alpine，并不启动正式 Compose 服务；通过不代表
UID 2010、ACL、skill 嵌套挂载、独立网络和 OpenClaw 工具路由都已验收。
正式部署仍须执行本文“验证”一节。在 storie 上以 UID 1000、docker 组运行：

```sh
guix shell python docker-cli -- python3 scripts/openclaw/check-docker-engine.py
```

脚本只创建 `openclaw-engine-probe-*` 容器和 `/var/tmp/openclaw-engine-*`
目录，结束后删除容器与引擎存储，保留 `results.json`、`commands.log`、
生成的 seccomp profile。引擎从最小参数开始：在镜像自带 seccomp profile
基础上放开嵌套所需调用（含基础 profile 以外层 capability 为条件的
chroot、setns、sethostname）、`systempaths=unconfined`、只加回 SETUID/SETGID、
不设 no-new-privileges、按需暴露 `/dev/fuse` 与 `/dev/net/tun`，不使用
`--privileged` 或 SYS_ADMIN。另起一个按 Gateway 加固参数运行的客户端，
以上游创建沙箱的参数建 keep-id 沙箱，检查同路径读写、未挂载文件不可见、
只读子挂载、catatonit、请求挂载 `/` 时只能看到引擎视图，以及默认接入
`static-agent` 时公网可达、其他内网地址不可达。引擎内部的从属 UID/GID
取 524288 起的 65536 个，避免与宿主账号重叠；没有 Docker 用户命名空间时
它们就是宿主 UID。

若某项失败，可用 `--seccomp`、`--cap-add`、`--no-unmask`、`--storage`
逐项对照；新增 SYS_ADMIN 或改为特权容器前须重新评估方案。`results.json`
中的 `engine_process_status` 记录引擎实际的 capability 与 seccomp 状态。
网络检查只记录 wget 能否完成请求：目标服务宕机、HTTP 错误也可能表现为
“closed”，不能单凭这一项证明防火墙阻断；需确认目标服务正常，并结合
restricted-network 规则验收。

2026-10-24 在 storie 上全部通过（引擎镜像 `quay.io/podman/stable`
`sha256:f790c751…`，内层 Podman 5.8.9、crun 1.28）。引擎 capability 上限只有
SETUID/SETGID，nested seccomp 生效，no-new-privileges 关闭；未用特权模式或
SYS_ADMIN。调试中确认的约束：

- 镜像自带 profile 以 `CAP_SYS_CHROOT` 为条件放行 `chroot`；Docker 外层去掉
  全部 capability 后该规则失效，需由 nested profile 无条件放行。
- `newuidmap` 要求进程 GID 等于镜像 passwd 中该用户的主组。
- keep-id 让 crun 在嵌套用户命名空间里访问 rootfs 与挂载源，那里的
  DAC_OVERRIDE 只覆盖属主和属组都已映射的 inode。挂载源路径若属于未映射的组，
  只有其他人权限可用：仅穿越时 `o+x` 即可，否则报 `` crun: readlink `` ``
  （podman#27785）；在其中创建挂载点（如 workspace 内的 skill 挂载）还需读写，
  会报 `openat2 … Permission denied`。因此正式部署的 workspace 不用未映射的
  组，读取者只经 ACL 授权。
- 沙箱与 Gateway 同在 `static-agent` 网桥时能连到 Gateway 的 18789 端口；
  同网桥流量不经 restricted-network 的转发过滤。因此引擎必须接独立的
  `sandboxed-agents` 网络。
