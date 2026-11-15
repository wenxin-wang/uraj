# zombie pasta 的来源（2026-11-15）

## 现象

lappie 上有二三十个 `pasta.avx2` 进程处于 `<defunct>`（zombie）状态，数量随时间增长。
[box-network-measure-20261115](box-network-measure-20261115.md) 里顺带看到。

## 排查

脚本：`exp/contained-agent-v2-workspace-box_20261115/zombies.sh`，在主机上运行。

- 23 个 zombie 的父进程都是同一个 `podman system service --time=0
  unix:///run/api/podman.sock`，也就是某个项目 Podman 运行时容器
  `contained-agent-runtime-<id>` 里的 inner podman 服务，不是主机上的
  `contained-podman` 服务。
- 这个 inner podman 服务的父进程是 conmon，说明它是运行时容器里的 PID 1。
  `src/python/uraj/contained_podman.py` 启动运行时时用一串 `exec` 把 podman service
  变成容器主进程，没有用 `--init`。
- 经主机 `contained-podman` 服务起停三个 pasta 网络的容器，zombie 数不变（23 → 23）；
  `--network=none` 也不变。主机服务本身没有泄漏。

## 原因

rootless Podman 起 pasta 时，pasta 会 fork 到后台，前台进程退出并被 podman 回收。
后台的 pasta 成了孤儿，被托管给所在 PID namespace 的 init。运行时容器里这个 init
就是 podman service，它不回收自己不认识的子进程；容器停止后 pasta 退出，就一直留成
zombie。所以每次 agent 在运行时里 `podman run` 一个用 pasta 网络的容器，就多一个。

上游有同类报告：API 服务留下 zombie `slirp4netns`
（[containers/podman#9777](https://github.com/containers/podman/issues/9777)）。

## v2 要做的

- 盒子的 PID 1 必须是会回收孤儿的 init：`podman run --init`（catatonit），或由盒子
  里的主管进程回收。[box-prototype-design-20261115](box-prototype-design-20261115.md)
  的原型用同样的 `exec` 链启动，也有这个问题。
- 现有 contained-agent 的运行时同样受影响，按 v2 的约定不在这里修；需要的话单独提。
