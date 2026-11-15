# contained-agent-v2 进度

当前：第 5 步，继续讨论设计，见 [step-5-handoff](step-5-handoff.md)。下一步要人定：
agent 创建 workspace 的细节，见 README 的待定项。

1. ~~盒子 rootfs 原型：Guix profile 代替 Fedora 镜像，嵌套 Podman 可用~~
   已完成。结论：只读挂 `/gnu/store` 加一个 profile 即可；`newuidmap`
   必须用 file capability，setuid 副本写 `uid_map` 报 EPERM；Postgres、
   Compose DNS、盒子内访问发布端口都通过。产物：
   `exp/contained-agent-v2-box_20261115/`，
   [box-prototype-design-20261115](box-prototype-design-20261115.md)。
2. ~~Paseo 接盒子的路线调研~~ 已完成，人选 C（原生 connected hosts）；A 的主机侧
   执行点堵不全，B 的代理相当于简化版 daemon。产物：
   [paseo-route-design-20261115](paseo-route-design-20261115.md)。
3. ~~网络和 reflink 实测~~ 已完成。结论：默认 pasta 下主机回环（含 Paseo daemon）
   连不到；主机上监听所有地址的服务经 `169.254.1.2` 能连到；局域网、relay、公网都通。
   uraj 的 reflink 拷贝 0.04 s、不占新空间。产物：
   [box-network-measure-20261115](box-network-measure-20261115.md)。
4. ~~路线 C 原型~~ 已完成。结论：盒子 daemon 经 unix socket 登记到主机 daemon 后，
   桌面 app 0.15.4 自动出现盒子 host，workspace、终端、文件、git diff 都通过；盒子
   重建后自动重连同一身份。建 agent 要等第 6 步（盒子里没有 coding agent 和凭据）。
   产物：`exp/contained-agent-v2-route-c_20261115/`，
   [route-c-measure-20261115](route-c-measure-20261115.md)。
5. 盒子边界清单：列出现在 agent 容器的挂载、synthetic HOME、凭据和设备，
   决定在盒子里怎么实现。进行中，先讨论 README 里剩下的待定项。
6. agent 进盒子：按选定路线启动 agent。
7. ~~zombie pasta：查清父进程和触发条件~~ 已完成。结论：项目 Podman 运行时里的
   inner podman 服务是容器 PID 1，不回收后台化的 pasta；主机服务没有泄漏。盒子要用
   `--init` 或自己回收。产物：[pasta-zombie-debug-20261115](pasta-zombie-debug-20261115.md)。
8. ~~不用 root 的动态授权实测~~ 已完成。结论：盒子管理服务以用户身份就能在盒子 netns
   里设、删 nftables（禁主机和内网、放行公网和 relay），往运行中的盒子加、撤挂载；
   agent 都做不到。撤挂载收不回已打开的 fd。产物：
   `exp/contained-agent-v2-grants_20261115/`，
   [grants-measure-20261115](grants-measure-20261115.md)。
9. ~~设备授权实测~~ 已完成。结论：render node 和 `/dev/kvm` 都能在运行中挂进、撤出，
   不用 root，agent 自己 `mknod` 失败；附加组经 crun 的 `keep_original_groups`
   带进盒子，render node 可用；用户不在 `kvm` 组，KVM 打不开，真正起虚拟机没测。
   产物：`exp/contained-agent-v2-grants_20261115/devices.sh`，
   [devices-measure-20261115](devices-measure-20261115.md)。
