# OpenClaw 验证

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

进度卡片和卡片样式的测试使用从固定部署镜像提取的原始 dispatcher、CardKit
session 和卡片构造器 fixture，不连接飞书。把应用进度补丁前的 runtime/setup
bundle 复制到临时目录，再运行：

```sh
FEISHU_DIST=/tmp/feishu-dist node --test \
  test/openclaw/feishu-guarded-progress.test.mjs \
  test/openclaw/feishu-card-style.test.mjs
```

它会检查布局及 fixture 与镜像是否一致；fixture 保留来源 image ID 和
上游许可证，升级时应从新镜像重新提取。

服务测试检查 Guix/SOPS 组合、权限、网络、SecretRef、镜像选择和失败
清理；运行时测试使用临时目录、模拟挂载元数据和 chown，不访问主机
/data、/run 或 Docker。`openclaw-program.scm` 另在 Guix 构建隔离下清除外部
Guile 搜索路径，验证生成的准备程序能加载运行时模块。还需要在真实部署时验证：

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
10. 处理进度卡片（见 [persona-guide](persona-guide.md#处理进度卡片)）：在话题里发起
    需要查阅资料或执行工具的请求，确认同一张卡片更新状态，等待超过十分钟
    仍可更新；完成后状态卡撤回、答案卡出现，聊天列表摘要正确。取消任务、
    静默回复和私人群加人导致回复被拦截时，状态清理且没有私人正文提前显示。
11. persona：依次测试共享群首次回复、私人私聊、单人群选私人角色、加人暂停、
    手动恢复，以及重启后的绑定和记忆；实际模型起草和话题内切换也在真实
    飞书里验证。
12. 配置校验：首次初始化、重启保留 agent 和 binding、`openclaw_config_set`
    合法修改成功、exec 中的原生 `config set` 被拒绝并提示工具、受管字段和
    agent 权限覆盖被拒绝、两个并发写入冲突，以及修改后的 Gateway 加载结果。
    仓库单元测试不代替真实镜像验收。
