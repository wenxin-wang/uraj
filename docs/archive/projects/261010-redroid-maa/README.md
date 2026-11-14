# hypie 上的 redroid 和 MAA

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

在 hypie 的 redroid（Docker 里的 Android）里跑明日方舟，让 MAA 按时刻表自动做日常任务，
不消耗理智；storie 上留一个手动启动的备用实例。现状见
[redroid-guide](../../../maa/redroid-guide.md) 和
[daily-tasks-guide](../../../maa/daily-tasks-guide.md)。

## 背景

- 游戏只有 ARM 版 native 库，所以需要 ARM 转译（Houdini）；redroid 要独立的 Docker 网桥，
  Android 的 ADB 不能暴露到局域网。网络部分见
  [261014-restricted-network](../261014-restricted-network/README.md)。
- 第一版 hypie 上的 redroid 在 10/10 进仓库（96b3344）；10/09 的主机核对记录见
  [validation-measure-20261009](validation-measure-20261009.md)。
- 10/16 在 hypie 上并行试了几个实例（`.3` 到 `.6` 四个试验容器），
  10/17 选定官方 Android 13 加 HPE Houdini 后迁到生产，见
  [trial-migration-deploy-20261017](trial-migration-deploy-20261017.md)。
  该文引用的 `scripts/redroid/migrate-houdini-data`、`retire-trials` 从未进过仓库
  （`git log --all` 查不到），`test/redroid/retire-trials.sh` 测的也是它们。

## 主要决定

- 10/10：独立 Docker 桥 `br-redroid`、10.203.0.0/24，Intel 核显渲染，不用 GTX 1080（96b3344）。
- 10/15：hypie 启用 `redroid-maa`；fwd2home 是全隧道，会吞掉桥的网段，所以加
  `vpn-bypass-priority 200`（8a23ac8，#14）。经过见
  [vpn-bypass-debug-20261015](vpn-bypass-debug-20261015.md)。
- 10/16：试 ChromeOS 的 `ndk_translation`（#17）；同日还有 Codysk 和 Waydroid HPE 的试验提交
  （4a074cb、f8afb81、f49126c，未单独合并）。
- 10/17：改用官方 Android 13 基础镜像加 Waydroid 选用的 HPE Houdini，生产数据目录改为
  `maa-houdini-13`（#25）。运行证据见
  [houdini-runtime-measure-20261017](houdini-runtime-measure-20261017.md)；生产配方的检查见
  [runtime-measure-20261017](runtime-measure-20261017.md)。
- 10/17：mcron 定时的日常任务，不消耗理智（#26）；证书和 shell 环境的修复
  （#28），原因见 [ca-bundle-debug-20261017](ca-bundle-debug-20261017.md)；ADB server
  要先启动，见 [adb-prestart-debug-20261017](adb-prestart-debug-20261017.md)；实测见
  [daily-validation-measure-20261017](daily-validation-measure-20261017.md)。
- 10/18：日常任务改用无人机加速纯金，增加 11:00 的一轮（#29）。
- 10/21：每轮日常任务后保存仓库快照 `depot.json`（#35）。
- 10/22：不让 Android 清空主机的 `modprobe` 设置，并让 `docker run` 前先清理同名容器
  （6becdfe）。经过见 [modprobe-autoload-debug-20261022](modprobe-autoload-debug-20261022.md)、
  [restart-race-debug-20261022](restart-race-debug-20261022.md)。
- 10/25：storie 上加手动备用实例，每轮日常任务先探测 ADB 端口，连不上就跳过；
  `remote-maa hack-fsync` 解决资源下载慢（#49）。背景见
  [storie-standby-deploy-20261025](storie-standby-deploy-20261025.md)、
  [fsync-hack-debug-20261025](fsync-hack-debug-20261025.md)。
- 11/02：MAA 升到 6.21.1（#82）。

## 待定

无。备用实例在 storie 上的启动耗时和完整一轮日常任务的耗时没有测量记录，未确认。

## 文档

- [TODO](TODO.md)：进度。
- [validation-measure-20261009](validation-measure-20261009.md)：旧的 redroid 专用实现的验证和主机核对。
- [trial-migration-deploy-20261017](trial-migration-deploy-20261017.md)：从试验实例迁到生产。
- [runtime-measure-20261017](runtime-measure-20261017.md)：生产配方的检查。
- [vpn-bypass-debug-20261015](vpn-bypass-debug-20261015.md)：fwd2home 全隧道吞掉网段。
- [houdini-runtime-measure-20261017](houdini-runtime-measure-20261017.md)：Houdini 的运行验证。
- [daily-validation-measure-20261017](daily-validation-measure-20261017.md)：日常任务在 hypie 上的实测。
- [ca-bundle-debug-20261017](ca-bundle-debug-20261017.md)：定时任务找不到 CA 证书包。
- [adb-prestart-debug-20261017](adb-prestart-debug-20261017.md)：先启动 ADB server。
- [restart-race-debug-20261022](restart-race-debug-20261022.md)：重启时容器名冲突。
- [modprobe-autoload-debug-20261022](modprobe-autoload-debug-20261022.md)：Android 清空 `modprobe`。
- [fsync-hack-debug-20261025](fsync-hack-debug-20261025.md)：资源下载的 fsync。
- [storie-standby-deploy-20261025](storie-standby-deploy-20261025.md)：storie 备用的背景。
