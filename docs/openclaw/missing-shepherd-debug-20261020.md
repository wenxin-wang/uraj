# OpenClaw 部署后没有 Shepherd 服务

## 部署后没有 Shepherd 服务

若 `/etc/openclaw` 已存在，但 `sudo herd status openclaw` 找不到服务，
先检查部署输出中是否有 `an error occurred while upgrading services`。
Guix 在服务热更新失败后仍可能打印 `successfully deployed`；这时磁盘上的
系统配置已切换，运行中的 Shepherd 服务可能仍是旧配置。

初版集成可能出现 `no code for module (uraj build openclaw)`。修复后的
启动闭包只使用 Guile 自带模块。准备程序使用 `with-uraj-modules`
打包本地模块及依赖，避免 `source-module-closure` 的默认过滤条件漏掉
`uraj` 模块；否则直接执行 `openclaw-prepare` 也会报同样的错误。更新到
包含修复的仓库版本后，在 lappie 再运行 `uraj-deploy storie`，然后在
storie 检查：

```sh
sudo herd status openclaw
sudo /etc/openclaw/compose ps
```

无需为此单独重启 syslog。若服务已注册但未启动，执行
`sudo herd start openclaw` 并检查启动报错；确认 Gateway 运行后再进行
飞书配对批准。
