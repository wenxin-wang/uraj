# contained-agent-v2 进度

当前：第 2 步。下一步要人定：盒子要承担哪些隔离，见 README 的待定项。

1. ~~盒子 rootfs 原型：Guix profile 代替 Fedora 镜像，嵌套 Podman 可用~~
   已完成。结论：只读挂 `/gnu/store` 加一个 profile 即可；`newuidmap`
   必须用 file capability，setuid 副本写 `uid_map` 报 EPERM；Postgres、
   Compose DNS、盒子内访问发布端口都通过。产物：
   `exp/contained-agent-v2-box_20261115/`，
   [box-prototype-design-20261115](box-prototype-design-20261115.md)。
2. 盒子边界清单：列出现在 agent 容器的挂载、synthetic HOME、凭据和设备，
   决定在盒子里怎么实现。
3. agent 进盒子：主机侧 exec 启动 agent，透传 stdio 和退出码。
4. agent 自有 Guix profile：会话中途加包，不经过 `contained-agent allow`。
