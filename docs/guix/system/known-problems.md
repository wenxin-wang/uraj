# Guix System 已知问题

更新：2026-10-04。主要设备：lappie。依据：用户提供的 `/var/log/messages`、
仓库配置、包源码和宿主机只读查询。日志观察与源码推断分开记录；没有实际影响的
告警先观察，不为消除日志而修改系统。临时日志与构建产物不作为持久档案。

## 待观察

### elogind 恢复后申请 inhibitor 被拒绝

- **证据**：2026-10-04 07:05:26、07:27:11 恢复时，UPower 与 NetworkManager
  申请 inhibitor 收到 `org.freedesktop.login1.OperationInProgress`。
  07:25:38 至 07:27:11 的 s2idle 完成，开盖恢复后约 5.5 秒联网成功。
- **诊断**：elogind 257.14 的睡眠子进程在 post hooks 前发送
  `PrepareForSleep(false)`，但父进程要等子进程退出才清除 `delayed_action`。
  客户端收到恢复通知后立即申请锁，可能被尚未清除的状态拒绝。
  2026-10-04 检查上游 main 仍有该时序，257.16 仍有相同拒绝条件；未找到现成修复。
- **可能影响**：若客户端此后没有成功重新申请 delay inhibitor，下次睡眠可能
  不等待其准备工作完成。日志没有证明持续缺锁，也没有证明已造成网络或电源故障。
  不能据此推断锁屏失败、数据丢失或所有 inhibitor 都失效。
- **观察方法**：在正常使用中比较睡眠前、恢复后稳定状态的锁列表；可用以下只读查询，
  关注 NetworkManager／UPower 的 `sleep`、`delay` 项。若持续缺锁且出现实际故障，
  再采集连续两次睡眠的日志与列表。

  ```sh
  gdbus call --system --dest org.freedesktop.login1 \
    --object-path /org/freedesktop/login1 \
    --method org.freedesktop.login1.Manager.ListInhibitors
  ```

- **可能修复**：区分“已发恢复通知”和“睡眠子进程已退出”，允许前者之后重新申请
  sleep inhibitor，同时保留防止并发睡眠请求的 action/job guard。
  本地方案曾完成构建与现有测试，未做运行时验证，现已撤下，暂不替换 elogind。
- **参考**：[inhibitor 协议](https://systemd.io/INHIBITOR_LOCKS/)、
  上游 [sleep.c](https://github.com/elogind/elogind/blob/main/src/sleep/sleep.c)、
  [elogind.c](https://github.com/elogind/elogind/blob/main/src/login/elogind.c)、
  [logind-dbus.c](https://github.com/elogind/elogind/blob/main/src/login/logind-dbus.c)。

### 恢复时 tty2–6 的 greetd 被重新启动

- **证据**：07:05:26、07:27:11，Shepherd 同时报告 `Respawning term-tty2` 至
  `term-tty6`。没有对应 tty1 重启记录。
- **补充证据**：`greetd-2.log`、`greetd-3.log` 在上述恢复时刻均记录
  `unable to wait VT: terminal: unable to wait for activation: EINTR: Interrupted system call`；
  同样错误自 09-27 起反复出现，早于本轮配置修复。
- **诊断**：tty2–6 配置 `switch = false`，greetd 在启动 greeter／用户会话前
  等待 `VT_WAITACTIVE`；调用返回 EINTR 后错误直接传播，导致守护进程退出，
  Shepherd 随即重启。这解释了未激活 VT 同时 respawn，不能归因于 agreety 或
  已登录 shell 崩溃。具体中断来源未追踪，不能仅凭 EINTR 指定某个信号。
- **实际影响**：这些错误发生在会话启动前，目前证据只显示空闲登录服务被重启，
  没有已登录会话丢失的证据。先观察恢复后切换 tty2 是否仍可正常登录；若出现
  终端不可用或已登录会话退出，再单独采集该次日志。
- **可能修复**：对等待 VT 的 EINTR 重试，其他错误仍上报，并验证正常终止不会
  被重试逻辑吞掉。2026-10-04 检查上游 master 仍直接传播该错误；暂不加本地补丁，
  也不把所有 VT 改为 `switch = true`（会主动切换终端）。
- **源码**：[0.10.3 启动顺序](https://github.com/kennylevinsen/greetd/blob/0.10.3/greetd/src/server.rs)、
  [上游 VT 等待实现](https://github.com/kennylevinsen/greetd/blob/master/greetd/src/terminal/mod.rs)。

### 混合睡眠后的时钟异常

- **触发原因已有强线索**：用户未主动请求睡眠。UPower 电池历史
  `/var/lib/upower/history-charge-ASUS_Battery-70.dat` 保存
  `1791068698 2.000 discharging`（10-04 07:04:58）；20 秒后 07:05:18
  elogind 宣布 hybrid-sleep。生成的 UPower 配置为
  `UsePercentageForPolicy=true`、`PercentageAction=2`、
  `CriticalPowerAction=HybridSleep`。因此高度支持低电量保护触发，虽未捕获
  当时的 D-Bus 调用者。恢复附近历史变为 `0.112 charging`。
  当前 Noctalia 电池空闲 900 秒策略调用的是 `loginctl suspend`，不是 hybrid-sleep；
  当前配置不能反证历史配置。07:25:36 的另一次普通 suspend 则有明确合盖记录。
- **证据**：07:05 的 hybrid-sleep 后，ntpd 报 `Clock offset exceeds panic threshold`
  并退出 255，随后被 Shepherd 重启。后续墙钟时间与内核时间增量明显不一致。
- **诊断**：存在时间跳变线索，但尚未确定 RTC、恢复计时或校时的具体责任。
  不能用 07:05:20–07:05:26 的墙钟记录断言混合睡眠仅持续六秒，也不能仅凭
  `hibernation exit` 证明磁盘镜像恢复成功。
- **NTP 行为**：默认 panic 阈值为 1000 秒；已有 `-g` 仅允许一次不受该阈值限制
  的校时，不意味着后续永不退出。Shepherd 重启 ntpd 后会重新获得这次机会。
  因而本次退出是大偏差的证据，不是缺少 `-g`。参见
  [NTP 4.2.8 文档](https://www.ntp.org/documentation/4.2.8-series/ntpd/)。
- **当前检查（10-04，新一次启动）**：09:12 采样 RTC 为 01:12 UTC、系统为
  09:12 +08:00，秒级一致；clocksource 为 `tsc`，resume 设备为 `259:2`。
  10:02 的 `ntpq -c rv` 为 `leap_none, sync_ntp`、stratum 3、offset 约
  −48.9 ms。当前同步正常，不代表先前恢复过程正常，也不足以排除间歇性 RTC 问题。
- **下一步**：若再次发生，记录外部实际经过时间、睡眠前后 `date`、`/proc/uptime`、
  RTC 读数、完整 PM 日志与 `ntpq -pn`／`ntpq -c rv`。先确认普通 suspend、
  hibernate、hybrid-sleep 哪种触发；不以放宽 NTP 阈值掩盖计时问题。
- **另一个低优先级告警**：`baseday_set_day: invalid day (25556)` 与可复现构建的
  1970 时间戳及 NTP basedate 下限高度吻合，不是 RTC 变成 1970 的证据。
  10-03 09:02 的查询曾确认 `sync_ntp`、stratum 2、offset 约 +12.6 ms；
  这不证明后续混合睡眠后的同步状态。

### USB-C／外接显示器恢复异常

- **证据**：外接设备枚举附近出现 LTTPR 参数错误；07:05 恢复后
  `ucsi_acpi USBC000:00` 报 `failed to re-enable notifications (-110)`、
  `GET_CONNECTOR_STATUS failed (-110)`，伴随 USB 重置／断开。
- **诊断**：UCSI 命令超时及显示链路能力读取异常是线索，尚未证明两者同根因。
  LTTPR 日志包含驱动回退处理；现有片段未见 GPU timeout/reset。
- **当前检查（10-04）**：机型 Adol 14 M5451GADOL，BIOS M5451GA.314
  （07/30/2026），内核 7.2.6。DRM 仅 eDP 内屏为 connected，外部 DP／HDMI
  均为 disconnected；Type-C port0 为 sink、usb_power_delivery，AC0 与其
  UCSI 电源节点 online=1。当前供电状态可见，但这不是外屏恢复测试，也不能
  证明历史 UCSI 超时已消失。现有 `dcdebugmask=0x410` 禁用内屏 PSR／Replay，
  不应当作 UCSI 或 LTTPR 修复。
- **上游线索**：2026-09-04 的
  [usb: typec: ucsi: allow retries of ucsi_resume_work（v2）](https://lists.openwall.net/linux-kernel/2026/09/04/3094)
  针对恢复时控制器忙导致通知启用失败、后续连接状态变化收不到的问题，增加延迟重试。
  这是相关候选补丁；尚未确认合入版本、当前 7.2.6 是否包含及本机适用性，
  不能直接承诺升级或回移可修复，也不据此解释 LTTPR 告警。
- **下一步**：若出现黑屏、充电或热插拔失效，对比不接外设、直连和扩展坞场景，
  记录端口、线缆、显示器及内核／固件版本，再考虑对应上游修复。
  不据日志批量添加内核参数。
- **使用反馈（10-04）**：用户暂未观察到外屏、USB-C 插拔或充电功能异常，继续观察。

### 关机／重启仍需完整验收

- 历史关机出现 `/run/user/1000` busy；重复 PAM 挂载与会话清理已修正（见下）。
  新日志的两次注销顺利移除会话，但还不能证明所有 FUSE 子挂载及完整关机均正常。
- **`/var` busy 的具体线索（10-04）**：当前生成的 `user-file-systems` 清理逻辑
  没有把 initrd 挂载的 `/var` 列入 known-mount-points，因此会把它当作手动挂载
  提前卸载；`/var/cache/fontconfig`、`/var/lib/gdm` 却在已知列表内，由后续
  `file-systems` 服务停止时卸载。父挂载在子挂载之前卸载，足以解释 busy。
  当前 compiled service 指向
  `/gnu/store/mjplx9a76nb2p08jv8gzf17kryd5iy7a-shepherd-user-file-systems.scm`；
  逻辑来源为 Guix `gnu/services/base.scm` 的 `file-system-shepherd-services`。
  沙箱内挂载视图只作辅助证据，不能替代历史宿主机关机日志。
- **影响与修复方向**：该清理循环捕获卸载错误后继续，不是看到 busy 就必然卡死；
  但此处也没有在子挂载卸载后重试 `/var`。后续若修复，应为 initrd 挂载与子挂载
  建立完整的停止顺序，不能仅把 `/var` 加入忽略列表以隐藏告警。
  暂不修改服务图，需要实际关机末尾日志验证最终状态。
- **进一步核对**：Guix `gnu/system.scm` 的 `non-boot-file-system-service`
  会移除所有 `needed-for-boot?` 文件系统；`boot-file-system-service` 只提供
  工具包，没有补上卸载服务。这解释了 `/var` 为什么缺席，而非仓库漏写
  一个普通 `dependencies` 字段。单独给子挂载添加 `file-system-/var` 依赖
  会指向不存在的服务；简单重复注册 `/var` 又可能重挂载或重复 fstab。
  完整修复应在 Guix 文件系统服务层为提前挂载的文件系统提供“仅接管卸载”的
  服务，并让子挂载依赖它，同时保留 initrd 启动路径与唯一的 fstab 条目。
  实施前需覆盖启动不重挂载、子挂载先停止、手动子挂载清理、最终卸载失败处理
  及安装镜像不引用宿主机 `/var` 的回归测试。当前只完成源码核对，未实现此修复。

## Noctalia 重启进入 kexec 后没有执行关机

- **证据**：10-04 00:45:24、08:35:16，elogind 接受重启并选择 kexec，
  同秒记录 `Operation 'kexec' finished`，但 Shepherd 未开始停止服务。
  凌晨后续请求报 `Action kexec already in progress`。当前启动的
  `kexec_loaded=0` 不能反推上一次启动请求时的状态。
- **触发条件**：Guix `guix/scripts/system.scm` 默认 `load-for-kexec?=#t`，
  reconfigure 会预加载新系统。elogind 检测到已加载内核时可自动选择 kexec。
  预加载本身不是失败原因。
- **执行根因（源码及打包配置已核对）**：Guix `gnu/packages/freedesktop.scm`
  将 elogind 的 `KEXEC` 配置为 kexec-tools 的原始 `/sbin/kexec`，已核对
  elogind 二进制内嵌路径。elogind 257.14 的
  `src/login/logind-dbus.c:elogind_run_helper` 用
  `execlp(helper, helper, NULL)` 无参数执行它。kexec-tools 2.0.31 的
  `kexec/kexec.c:main` 默认 `do_load=1`、`do_exec=0`；无内核文件时
  `do_kexec_file_load` / `my_load` 返回 `No kernel specified`，不会进入
  shutdown 或执行已加载内核。该错误文本由源码推导，尚未从历史日志捕获。
- **为何一直 in-progress**：辅助进程异步启动实际程序，未等待其退出状态便
  记录 finished；elogind 父进程的 `src/login/elogind.c:elogind_sigchld_handler`
  仅对 sleep operation 清除 action 状态，kexec 失败后仍保留 action_job。
  这解释首次请求未重启、后续请求被拒绝的两个阶段，与 `/var` busy 独立。
- **修复方向**：Guix 应将 kexec helper 接到 Shepherd 的有序 kexec 重启入口
  （如调用 `reboot --kexec` 的专用包装程序，实施时核对所依赖 Shepherd 版本），
  由 PID 1 停止服务后执行内核切换；不能简单改成裸 `kexec -e` 跳过清理。
  elogind 还需正确收集 helper 失败并恢复 action 状态。
- **本地修复**：`(uraj packages elogind)` 的 `elogind-with-shepherd-kexec`
  将 helper 指向执行 Shepherd 1.0 `reboot --kexec` 的包装程序，共享桌面配置
  已接入。明确使用 1.0，因为 Guix 默认的 Shepherd 0.10 客户端不支持此参数。
  保留 Guix replacement 包的修复。构建通过（261 项通过、8 项跳过），已核对
  二进制内嵌 helper 路径；尚未 reconfigure 或验证实际重启。此改动修复错误入口，
  不包含 elogind 通用 helper 失败状态恢复的上游修改。
- **源码依据**：[kexec-tools v2.0.31](https://github.com/horms/kexec-tools/blob/v2.0.31/kexec/kexec.c)，
  本机 elogind 257.14 checkout 与当前 Guix channel 的上述源文件。

## 已处理，保留回归线索

| 问题 | 诊断与修复 | 最新验证范围 |
| --- | --- | --- |
| 无线监管数据库签名被拒绝 | Guix 原包省略 `.p7s`；`packages/wireless.scm` 使用同一上游发行的数据库与签名并验证 | 10-04 新启动未见签名拒绝，5 GHz 联网成功 |
| 蓝牙 D-Bus 拒绝 | PipeWire SPA 对 no-reply Release 错误回复；另缺 GATT Release 策略。回移 no-reply 判断，并仅放行 root 的 GATT Release | 10-04 恢复日志未再出现这两类拒绝；不等同于所有音频场景已测 |
| ModemManager 延迟睡眠 | 无使用中的蜂窝设备却持有 delay inhibitor；共享桌面基础服务移除 ModemManager | 新启动服务缺席，睡眠不再有其五秒超时；需要蜂窝网络时恢复服务 |
| 用户运行目录重复管理 | greetd 的 pam_mount 与 pam_elogind 重复管理；桌面保留后者，niri 退出时先停止用户 Shepherd 再结束 session bus | 07:30、07:34 两次注销当秒移除会话，无 runtime-directory busy；完整关机仍待观察 |
| zswap 实际使用 lzo | zstd 为模块，内核早期初始化时未加载；initrd 加载模块后、挂载根之前选择 zstd | 用户已验证，提交 `73265e1` |

## 暂不作为功能故障

- ACPI `C014`–`C017` 引用缺失：20 个逻辑 CPU 均在线；可能是固件残留，未确诊。
- AMD-Vi 匹配告警之后仍启用中断重映射和 Virtual APIC；未见功能失败证据。
- ACP 告警不证明麦克风不可用：ALC233 已识别输入，PCM 有 capture，需实际录音判定。
- 普通启动 `PM: Image not found`、睡眠时 `OOM killer disabled/enabled` 不单独表示故障。
- 启动 IPv6 NTP bind 失败随后监听成功；P2P 转发告警后 Wi-Fi 仍正常连接。
- nscd 的多次重启紧跟 DNS 配置更新及显式停止请求，当前记录不支持把它当作崩溃循环。
- 启动阶段特定 `init ... guile` segfault 的历史记录有
  [Guix 上游讨论](https://www.mail-archive.com/help-guix@gnu.org/msg21757.html)；
  不能仅据该行认定运行中的 PID 1 崩溃。
