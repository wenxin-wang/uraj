# agent-browser 进度

全部完成。

1. ~~沙箱里的浏览器~~ 已完成。10/28，PR #56：trixie 镜像、agent-browser、`skills` 字段、
   30 分钟空闲关闭。
2. ~~角色登录快照~~ 已完成。10/28，PR #59；上线记录见
   [profile-snapshot-deploy-20261029](profile-snapshot-deploy-20261029.md)。
3. ~~GPU~~ 已完成。10/29 headless 加 Vulkan，PR #65；同日因风控页改回有头模式加 cage，
   PR #69，见 [headed-browser-debug-20261029](headed-browser-debug-20261029.md)。
4. ~~skill 的登录流程~~ 已完成。10/30，PR #75、#76。
5. ~~contained-agent 一侧~~ 已完成。11/01 用主机发布的登录快照 fork，PR #77；
   同日没有发布登录也能浏览公开站点，PR #80。过程文档以 `contained-agent-*.md` 命名。
6. ~~旧锁~~ 已完成。11/04 启动前清除来自其他主机的 `SingletonLock`，PR #84。
7. ~~人接管~~ 已完成。11/06 浏览器 dashboard 和转发脚本，PR #89，部署记录见
   [dashboard-rollout-deploy-20261106](dashboard-rollout-deploy-20261106.md)。
