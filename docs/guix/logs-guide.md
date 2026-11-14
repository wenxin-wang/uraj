# 系统日志读取

共享系统配置以 rsyslog 替换 Shepherd 内置的 system-log 服务。
`wenxin` 属于 `log-readers`，可读取当前 `/var/log/messages`；
该文件保持 `root:log-readers 0640`。激活时也会调整已有当前文件的
属组，历史内容不会清除，因此其中仍可能有迁移前的 auth 消息。

新消息中 `auth`、`authpriv` 写入 `secure`，邮件写入 `maillog`；
这些文件以及 `debug` 保持 root 组权限。普通消息保留全部级别。
`guix-daemon.log` 等由 Shepherd 捕获的服务输出不变。

继续使用 Shepherd 默认的外部日志复制截断轮转和 zstd 压缩。
当前 `messages` 的属组不因轮转改变；归档可能变为 root 组，仍需
sudo 读取。

Guix 会安装配置到 `/etc/syslog.conf`，rsyslog 和 Shepherd 统一使用
`/var/run/syslog.pid`。加入 `log-readers` 后重新登录（以及重启 agent）
让附加组生效。`herd status syslogd` 可检查服务状态；
`herd reload syslogd` 仅发送 HUP 重新打开日志，不会重新读取 rsyslog
配置，配置更新需要重启该服务。

配置回归测试：
```sh
guix time-machine -C env/guix/channels-lock.scm -- \
  repl -L src/guix -L src/guile test/guix/uraj/services/rsyslog.scm
python3 test/guix/uraj/services/rsyslog-integration.py \
  /gnu/store/…-rsyslog-…/sbin/rsyslogd
```

集成测试只使用临时日志和独立 socket，替换测试用户身份并关闭内核
输入；验证消息分流、权限、轮转后继续写入和文件重建。

## 按服务的日志目录

用 Compose 跑的服务（Immich、new-api、Paseo relay、OpenClaw）通过
`(uraj services logs)` 的 `service-log` 在 `/var/log/<服务名>/` 下放日志：
目录归 `root:log-readers`，setgid 2750，`log-readers` 成员免 sudo 读取。
声明 `(containers? #t)` 的服务，其容器输出经 Compose 的 syslog 驱动和一条
rsyslog 路由写入 `/var/log/<服务名>/containers.log`，tag 为 `<服务名>/容器名`，
随系统日志轮转。rsyslog 只在启动时读取路由，首次部署新路由需要
`sudo herd restart syslogd`。Paseo daemon 的目录只放它自己的 `paseo.log`。
各服务的日志位置见各自的手册。
