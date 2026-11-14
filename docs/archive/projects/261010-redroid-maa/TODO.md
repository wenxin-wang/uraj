# hypie 上的 redroid 和 MAA 进度

全部完成。

1. ~~hypie 上的 redroid 首版~~ 已完成。10/10，私有桥、受限出站、核显渲染，96b3344；
   10/15 启用并加 VPN 绕行，PR #14；对应主机核对见
   [validation-measure-20261009](validation-measure-20261009.md)。
2. ~~ARM 转译方案~~ 已完成。10/16 试 ChromeOS `ndk_translation`，PR #17；10/17 定为官方
   Android 13 加 HPE Houdini，PR #25。
3. ~~试验实例迁到生产~~ 已完成。10/17，见
   [trial-migration-deploy-20261017](trial-migration-deploy-20261017.md)；文中的迁移脚本
   没进过仓库。
4. ~~日常任务~~ 已完成。10/17 mcron 日常任务，PR #26；证书和 shell 环境，PR #28；
   10/18 无人机和 11:00 一轮，PR #29；10/21 仓库快照，PR #35；11/02 MAA 6.21.1，PR #82。
5. ~~启动可靠性~~ 已完成。10/22 保留主机模块自动加载，`docker run` 前清理同名容器，
   6becdfe。
6. ~~storie 备用~~ 已完成。10/25 备用实例、ADB 探测、`remote-maa hack-fsync`，PR #49。
   启动耗时和完整一轮的耗时没有记录，未确认。
