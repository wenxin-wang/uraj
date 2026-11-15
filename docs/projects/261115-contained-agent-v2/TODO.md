# contained-agent-v2 进度

当前：第 2、3 步。下一步要人定：Paseo 走哪条路线，以及盒子在 app 里显示为单独
host 能否接受，见 README 的待定项。

1. ~~盒子 rootfs 原型：Guix profile 代替 Fedora 镜像，嵌套 Podman 可用~~
   已完成。结论：只读挂 `/gnu/store` 加一个 profile 即可；`newuidmap`
   必须用 file capability，setuid 副本写 `uid_map` 报 EPERM；Postgres、
   Compose DNS、盒子内访问发布端口都通过。产物：
   `exp/contained-agent-v2-box_20261115/`，
   [box-prototype-design-20261115](box-prototype-design-20261115.md)。
2. ~~Paseo 接盒子的路线调研~~ 已完成，等人选路线。结论：建议 C（原生 connected
   hosts）；A 的主机侧执行点堵不全，B 的代理相当于简化版 daemon。产物：
   [paseo-route-design-20261115](paseo-route-design-20261115.md)。
3. 网络和 reflink 实测：盒子能访问主机回环、主机局域网地址、局域网其他主机、
   relay、公网中的哪些；pasta 的默认配置；`.git` reflink 拷贝的耗时和占用。
   脚本已写好，等在主机上运行：`exp/contained-agent-v2-workspace-box_20261115/`。
4. 按选定路线做原型。C：一个盒子、一个盒子 daemon，主机 daemon 登记它，app 经
   主机 daemon 能列 workspace、建 agent、收发消息、开终端；记录不能用的功能。
5. 盒子边界清单：列出现在 agent 容器的挂载、synthetic HOME、凭据和设备，
   决定在盒子里怎么实现。
6. agent 进盒子：按选定路线启动 agent。
