# 系统日志读取

## 系统日志读取

共享系统配置以 rsyslog 替换 Shepherd 内置的 system-log 服务。
`wenxin` 属于 `log-readers`，可读取当前 `/var/log/messages`；
该文件保持 `root:log-readers 0640`。激活时也会调整已有当前文件的
属组，历史内容不会清除，因此其中仍可能有迁移前的 auth 消息。

新消息中 `auth`、`authpriv` 写入 `secure`，邮件写入 `maillog`；
这些文件以及 `debug` 保持 root 组权限。普通消息保留全部级别。
`guix-daemon.log` 等由 Shepherd 捕获的服务输出不变。

继续使用 Shepherd 默认的外部日志复制截断轮转和 zstd 压缩。
当前 `messages` 的属组不因轮转改变；归档可能变为 root 组，仍需
sudo 读取。不增加权限修复任务或压缩回调。

首次切换建议 reconfigure 后重启，使旧的内置 logger 释放 `/dev/log`
并由 rsyslog 接管。Guix 会安装配置到 `/etc/syslog.conf`，rsyslog 和
Shepherd 统一使用 `/var/run/syslog.pid`。之后重新登录（以及重启
agent）让附加组生效。`herd status syslogd` 可检查服务状态；
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
