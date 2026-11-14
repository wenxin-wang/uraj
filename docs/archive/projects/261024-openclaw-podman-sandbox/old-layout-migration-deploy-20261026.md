# 旧数据布局的清空迁移

旧布局（HOME 挂在 `/home/node`、workspace 挂在 `/workspace`、属主 1000）
不自动迁移。接入沙箱时数据基本为空，按清空处理：停服务并移除容器，
备份后清空 `/data/openclaw`，然后部署新配置：

```sh
sudo herd stop openclaw
sudo /etc/openclaw/compose down
sudo mkdir -p /core-data/backups/openclaw
sudo tar -C /data -czf /core-data/backups/openclaw/before-sandbox.tar.gz openclaw
sudo rm -rf /data/openclaw
```
