# 首次部署的步骤说明

现有 storie 声明已填写完毕，不需要手动向 `host-sops-services` 添加
重复 secret。以后停用时可将 `%openclaw-configuration` 改成 `#f`。

显式重启 SOPS 是为了在已经运行的主机上解密新增条目；失败时先解决
解密问题，不继续启动。首次添加日志路由需要重启 `syslogd`，也会
重启依赖它的其它服务，应安排可接受的维护时间。
