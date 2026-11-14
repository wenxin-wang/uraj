# Immich 首次部署的取舍

```sh
# 在已安装的 storie 上，从仓库环境构建/部署（不是运行在开发机上）：
guix time-machine -C env/guix/channels-lock.scm -- system build env/guix/os/storie.scm
sudo -E guix time-machine -C env/guix/channels-lock.scm -- system reconfigure env/guix/os/storie.scm
```

本次在本机生成了新密码，供尚未初始化的数据库使用。如果此前已经运行
并初始化过数据库，需要改用现有密码，或同步更新 PostgreSQL role；
重启本身不会改密。

本次不增加额外备份任务。

本次没有给 archive 设置属性，也没有增加快照任务。
