# OpenClaw 验证

> 迁移自 `docs/openclaw.org` 的 “验证”（2026-11-14，内容未改）。

## 验证

```sh
guix repl -L src/guix -L src/guile test/guix/uraj/services/openclaw.scm
guix repl -L src/guix test/guix/uraj/openclaw-runtime.scm
node --test test/openclaw/*.test.mjs
guix build -L src/guix -L src/guile -f test/guix/uraj/openclaw-program.scm
python3 test/python/uraj/container/seccomp.py
python3 test/openclaw/browser-profile.py
python3 test/openclaw/browser-dashboard.py
```

进度卡片测试使用从固定部署镜像提取的原始 dispatcher、CardKit session
和核心进度转发 fixture，替换外部接口后执行更新、答案卡发送、撤回和
回退路径，并与角色检查联测。模拟时钟覆盖十分钟以上的等待和计时清理；
默认 verbose 关闭时的真实转发逻辑也纳入测试。
样式测试使用原始卡片构造器验证共享发送路径和分片字节预算；实际模型
上下文 fixture 验证 Model / Effort 跟随本次选择及回退，不在状态卡提前显示。
可把应用进度补丁前的 runtime/setup bundle 复制到临时目录，再运行：

```sh
FEISHU_DIST=/tmp/feishu-dist node --test \
  test/openclaw/feishu-guarded-progress.test.mjs \
  test/openclaw/feishu-card-style.test.mjs
```

它会检查布局及 fixture 与镜像是否一致；fixture 保留来源 image ID 和
上游许可证，升级时应从新镜像重新提取。此测试不连接飞书或调用模型。

服务测试检查 Guix/SOPS 组合、权限、网络、SecretRef、镜像选择和失败
清理；运行时测试使用临时目录、模拟挂载元数据和 chown，不访问主机
/data、/run 或 Docker。还需要在真实部署时验证：

1. DNS、飞书长连接和 new-api 调用成功；确认其它 LAN/主机服务被拒绝。
2. 未批准的私聊只触发配对流程；批准后可回复；群聊 @机器人可触发模型。
   在同群两个话题及另一群分别发测试消息，确认日志中的 session key 不同，
   同一话题的后续消息复用原 session，回复留在对应话题。
3. 重启 Gateway 后上下文仍在，停止期间没有意外启动的容器。
4. 重启主机后网络规则与秘密先就绪，镜像和数据均被保留。
5. 实测秘密轮换、备份恢复，以及临时版本切回声明版本。
6. 在 Gateway 中 `podman info` 报告 rootless 与 remote；引擎内看不到
   `/run/secrets`、`/etc/openclaw` 和 HOME。
7. 让 agent 执行 `id; ls /run/secrets; ls /data/openclaw/home`，以及访问
   new-api、Gateway 18789 端口和一个公网 HTTPS 站点：应为 UID 2010，
   凭据与 state 不可见，内部地址不通，公网可达。
8. agent 在 workspace 写的文件在宿主上属于 `openclaw:log-readers`，
   管理员不用 sudo 即可读取；`sandbox list` 显示引擎 socket，重启 Gateway
   后沙箱复用，重启引擎后自动重建。
9. 用 `openclaw_config_set` 和沙箱中的 `openclaw config set` 修改默认模型成功；
   CLI 读取仅返回默认模型，其他路径和命令被拒绝。
10. 在话题里发起需要查阅资料或执行工具的请求，确认同一张卡片更新固定
    状态、已用时和距上次进展的时间；等待超过十分钟仍可更新。完成后
    答案卡正文更易读，状态卡撤回；首次身份提示和实际 Model / Effort 仍出现。
    后台完成通知的自动卡片也使用相同字号和边距。
    在聊天列表确认摘要显示正文（跳过身份介绍），处理中显示当前阶段；
    默认共享角色的卡内标题显示“共享助手”。
    取消任务、静默回复和私人群加人导致回复被拦截时，确认状态清理且
    没有私人正文提前显示。

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
