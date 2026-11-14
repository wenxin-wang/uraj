# contained-agent 的 Podman 运行时进度

全部完成。

1. ~~共用 rootless Podman 系统配置~~ 已完成。10/17，PR #27，75d10fe。
2. ~~项目运行时~~ 已完成。10/26 PR #20（632d2d6）：外层 rootless 容器、内层 API、挂载策略、
   原生 overlay 存储。
3. ~~改成主机服务~~ 已完成。10/26 同一个 PR：长驻 `podman system service`、空闲回收、
   `contained-agent podman-service`、Shepherd 服务；运行时镜像按 digest 拉取。
4. ~~自检和验收~~ 已完成。`podman-check`、`podman-list`、`podman-stop`；Harbor 验收见
   [harbor-measure-20261025](harbor-measure-20261025.md)。
