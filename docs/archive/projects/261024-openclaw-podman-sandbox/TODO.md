# OpenClaw 的 Podman 执行沙箱进度

全部完成。

1. ~~引擎探针~~ 已完成。10/24–10/25，`d419d4f`、`655484a`，随 #48 合入；storie 上
   10/24 全部通过，见 [engine-params-debug-20261024](engine-params-debug-20261024.md)。
2. ~~接入沙箱~~ 已完成。10/26，PR #48：引擎容器、`sandboxed-agents` 网络、UID 2010、
   ACL、`openclaw_config_set`；旧布局清空迁移见
   [old-layout-migration-deploy-20261026](old-layout-migration-deploy-20261026.md)。
3. ~~启动时构建沙箱镜像~~ 已完成。10/29，PR #64。
4. ~~沙箱镜像补 python 和 node~~ 已完成。10/29，PR #70。
5. ~~`.openclaw/tmp` 可写~~ 已完成。10/30，PR #73。
6. ~~重启参数~~ 已完成。11/10，PR #92。
