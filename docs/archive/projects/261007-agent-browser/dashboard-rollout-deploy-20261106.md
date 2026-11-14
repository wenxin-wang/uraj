# dashboard 修复的部署和沙箱重建

新版包装器和转发脚本还会移除 dashboard 进程继承的浏览器启动参数，避免
0.38.2 在执行 Fit、导航等菜单命令时用缺少 profile 的参数重启浏览器。
已运行的旧 dashboard 需要先在沙箱内执行 `agent-browser dashboard stop`，
再用新版脚本启动；浏览器会话可以保持运行。启动环境修正后，也可以点右下角
尺寸菜单选择 `Fit`，通过调整页面大小修正点击坐标。

这项修复随系统部署分发两部分：

- `env/docker/openclaw-sandbox/browser-profile` 随构建上下文进入
  `/etc/openclaw/sandbox-build`，服务启动时构建进新沙箱镜像。包装器也将
  旧式 `identity dashboard`、`run TASK dashboard` 转到安全启动路径。
- `scripts/openclaw/skills/agent-browser/` 生成 `/etc/openclaw/skills`，
  挂入 Gateway 后由 OpenClaw 分发到沙箱；其中要求同步 viewport、收到实际
  `frame` 后再交接，并回报端口和连接命令。

部署包含修复的版本后，还需让旧沙箱换用新镜像。在 storie 执行以下步骤，
先停止服务并移除旧沙箱，再由服务启动流程构建镜像、加载新 skill；下次
agent 使用沙箱时会重新创建。重建会关闭当前浏览器和 dashboard，保留
workspace 及其中的 profile。先结束手动操作，再执行：

```sh
sudo herd stop openclaw
sudo /etc/openclaw/compose up -d --pull never --no-build --wait engine
sudo /etc/openclaw/compose run --rm --no-deps --pull never \
  --entrypoint node gateway /app/openclaw.mjs sandbox recreate --all
sudo herd start openclaw
```

确认重建命令成功后再启动服务。随后让 agent 重新读取 browser skill，
启动 dashboard 并按交接流程验证画面，再使用它新报出的沙箱和端口连接。
