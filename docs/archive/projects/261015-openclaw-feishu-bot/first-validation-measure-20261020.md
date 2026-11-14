# 首次集成的验证记录

仓库已包含用户提供的 image ID 和加密凭据。此处的自动测试不验证
storie 上的镜像内容、凭据有效性或飞书授权，也未执行主机 reconfigure。
镜像运行时的 schema 检查与端到端验收在部署时执行。

本轮验证：78 项服务断言、35 项运行时断言、33 项 SOPS 回归断言及
42 项 new-api 回归断言全部通过（共 188 项）。Guix 成功构建最终声明
对应的配置、Compose 文件和 `openclaw-prepare` 程序。仓库风格检查器
只覆盖 C/C++/Python，不支持本次 Scheme 文件；Scheme 由上述测试加载
并检查，补充执行 `git diff --check`。

修复热更新加载问题后，78 项服务断言通过，并在使用临时 socket 的
独立 Shepherd 1.0.9 中，通过 `root eval` 加载、注册生成的服务文件，
确认 `openclaw` 存在且为 stopped。此检查未启动容器或修改系统 Shepherd；
storie 上的实际热更新仍需重新部署确认。

准备程序另有 Guix 构建隔离测试：使用生产 gexp 自带的模块元数据，
清除外部 Guile 搜索路径，加载真实运行时模块后替换文件操作入口，
验证生成程序能调用该入口；不读取秘密、不写入主机数据目录。
