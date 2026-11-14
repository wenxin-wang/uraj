# OpenClaw 沙箱里的浏览器

> 迁移自 `docs/openclaw.org` 的 “沙箱里的浏览器”、“手动接管沙箱浏览器”（2026-11-14，内容未改）。

## 沙箱里的浏览器

沙箱镜像 `env/docker/openclaw-sandbox` 带 agent-browser、Debian 的
Chromium、Mesa Vulkan 和中日韩及 emoji 字体。命令和浏览器在同一个沙箱
容器里运行；不使用 OpenClaw 内置的 `browser` 工具，上游 Podman 后端也
不支持内置浏览器沙箱。

浏览器以有头（headed）模式运行：headless 会改变浏览器特征，部署后
小红书、京东和百度同时出现风控页，此前 Xvfb 有头模式下小红书可以正常
搜索和扫码登录。Xvfb 无法使用硬件加速，因此启动包装器 `sandbox-chromium`
为每个 Chromium 启动私有的 cage（wlroots 无头后端），Chromium 以
`--ozone-platform=wayland` 连接；cage 随 Chromium 退出，同一沙箱的多个
浏览器各用一个 Wayland socket。cage 用 render node 的 Vulkan 渲染器合成；
没有 render node 时改用 pixman。WebGL 由 Chromium 的 GPU 进程直接使用
render node，与合成器渲染器无关。`AGENT_BROWSER_ARGS` 指定 `--enable-gpu`、
`--use-gl=angle` 及 `--use-angle=vulkan`，并保留
`--disable-blink-features=AutomationControlled`。agent-browser 在容器中
自动加入 `--no-sandbox`。包装器在可写的 `/tmp` 创建私有 `XDG_RUNTIME_DIR`，
并继续过滤 `--enable-unsafe-swiftshader`，避免许可软件回退。cage 和 Chromium
的 stderr 写入该目录的 `browser-PID.log`（一天后清理），不交给 agent-browser：
它在浏览器启动完成后才读取，启动日志超过管道容量时 cage 会永久阻塞。
CLI 的 `skills get` 正文来自镜像中同版本源码包的 `skills`、`skill-data`。
登录状态按角色保存；新镜像的 `browser-profile` 将主登录目录与任务副本分开。
`login URL` 打开主登录浏览器，`identity screenshot /workspace/login.png`
可截图扫码。确认登录成功后 `publish` 正常关闭浏览器、检查进程退出并发布快照。
首次使用会把已关闭的旧 `.agent-browser/profile` 迁移到 `identity`，不丢弃登录。
重建沙箱会换主机名，旧沙箱里被杀死的浏览器留下的 `SingletonLock` 指向旧主机，
Chromium 会一直报资料被占用；`browser-profile` 启动前检查没有本地进程使用该目录后
清除这种锁。每个 workspace 只有一个沙箱，同主机的锁仍由 Chromium 自己判断。

普通任务运行 `browser-profile create`，保存 JSON 返回的 task ID，然后用
`browser-profile run ID open URL`、`run ID screenshot PATH` 等命令操作。
每个任务独立 session 和 profile；`finish ID` 关闭并删除任务副本。
空闲 30 分钟会关闭浏览器，但不删除副本。任务的登录变化不写回主目录。
发布新快照不影响旧任务；网站仍可能撤销或轮换 token，复制不保证登录有效。
旧快照暂不自动清理。所有目录位于同一角色的 workspace，不构成角色内隐私隔离。
扫码优先通过截图完成，暂不部署 VNC。

storie 配置 `(render-device "/dev/dri/renderD128")`。Docker 把该设备传给
engine，Guix 生成的 `CONTAINERS_CONF_OVERRIDE` 再让 rootless Podman 将它
传给每个角色沙箱；Gateway 不获得 GPU。未配置该字段的主机不透传 GPU。
设备必须允许 engine 的 UID 访问；storie 当前 render node 权限为 0666。
不传入 `card0`，不启用 privileged。各任务可共用 render node。
硬件 WebGL 不代表视频硬件解码或整个合成流水线均已加速。

storie 使用启动时自动构建：修改沙箱后 reconfigure，服务启动会在 Podman
中构建镜像并写入实际 ID，无需手动修改 `sandbox-image`。启动成功后验证
真正的 Docker engine → rootless Podman → agent-browser 链路：

```sh
image=$(sudo cat /run/openclaw/sandbox-image)
sudo scripts/openclaw/try-browser-gpu "$image"
```

该检查使用临时容器和 /tmp profile，不读取角色登录状态；验证两个并行
浏览器的硬件 WebGL、像素回读与截图生成。若要在部署前手工测试镜像，
可运行 `scripts/openclaw/try-sandbox-image IMAGE`，另行检查角色快照复制。
两个测试都拒绝 SwiftShader/llvmpipe/lavapipe 软件 renderer。

Skill 由 Gateway 加载，再由 OpenClaw 复制进沙箱（state 下的
`.openclaw/sandbox/skills-workspaces`），所以不放在镜像里，也不经过 Home
的 agent skill 服务。服务字段 `skills` 接受 `(NAME DIRECTORY)` 列表，
Guix 把它们解开符号链接复制成 `/etc/openclaw/skills`，以只读方式挂进
Gateway，并写入 `skills.load.extraDirs`。storie 使用 `scripts/openclaw/skills/agent-browser` 的专用说明。
通用命令参考由镜像里的 CLI 通过
`agent-browser skills get core` 提供。`requires.bins` 在 Gateway 侧检查，
agent-browser 的 skill 未声明此项，Gateway 镜像无需安装它。

## 手动接管沙箱浏览器

agent-browser 0.38.2 自带网页 dashboard，可以查看实时页面、点击、输入、
导航和切换标签页。`browser-profile` 的 `role-identity`、`task-ID` 和同一
沙箱里的原生 agent-browser session 都会显示，操作的是正在运行的浏览器。
无需 VNC，也不改变 cage、GPU 或 profile。它显示网页内容，不包含 Chromium
原生菜单及系统弹窗；操作前让 agent 等待，完成后再继续，dashboard 不会
自动暂停 agent。

agent-browser 0.38.2 在 headed Chromium 下可能把页面尺寸误报为
1280 x 720，而实际内容区更矮，导致画面可见但点击坐标偏移。skill 在交接前
会用 `browser-profile identity eval '[innerWidth, innerHeight]'` 读取尺寸，
再执行 `browser-profile identity set viewport WIDTH HEIGHT` 同步 dashboard，
保留当前桌面页面的尺寸。任务副本则将 `identity` 换成 `run TASK`。

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

OpenClaw 沙箱在 Docker engine 里的 rootless Podman 中，dashboard 只监听
沙箱的 loopback，不能直接从宿主访问。仓库提供转发脚本，在本机运行：

```sh
# 先列出 storie 上运行中的沙箱，选择目标角色对应的容器名。
python3 scripts/openclaw/browser-dashboard.py --ssh storie --list
python3 scripts/openclaw/browser-dashboard.py --ssh storie CONTAINER
# 打开 http://127.0.0.1:4848
```

也可以告诉 agent：「启动浏览器 dashboard，确认可连接后告诉我端口、
会话名和所在沙箱，然后等我操作完。」两边的 browser skill 都包含这个
交接流程。agent 在目标沙箱中启动并验证 dashboard，回报实际端口。
例如 agent 给出的端口是 4851，将它传给 `--dashboard-port`：

```sh
python3 scripts/openclaw/browser-dashboard.py --ssh storie \
  --dashboard-port 4851 --port 4848 CONTAINER
# 仍然打开 http://127.0.0.1:4848
```

还需用 `--list` 确认目标容器名或 ID。脚本复用 4851 上已有的 dashboard；
`--port 4848` 决定转发入口，两者不必相同。

在终端按提示输入 storie 的 sudo 密码即可，`--list` 也支持密码提示。
SSH 模式通过远端 PTY 运行一个提权 helper，整个转发期间不再逐请求执行
sudo。密码由 SSH/sudo 处理，脚本不读取或保存密码。HTTP 和 WebSocket
通过独立的 SSH 端口转发通道传输，不经过 PTY。

helper 启动沙箱内的 dashboard，并通过 `compose exec`、`podman exec`
转发流量，无需重建镜像或发布容器端口。本机和远端 helper 都只监听
`127.0.0.1`。`--port` 默认 4848，同时用于本机和远端宿主的监听端口；
任一端已占用时换用 `--port 4849` 等端口，也可同时接管多个沙箱。
`--dashboard-port` 指定沙箱内端口，默认也是 4848。

本机和远端用户 PATH 中均需 Python 3；脚本会在 sudo 重置 PATH 前定位
远端 Python。helper 代码从当前 checkout 通过 SSH 参数传入，远端无需
checkout 或临时脚本。也可在 storie 上直接提权运行（省略 `--ssh`）：

```sh
sudo python3 scripts/openclaw/browser-dashboard.py CONTAINER
# 自己电脑的另一个终端：
ssh -N -L 4848:127.0.0.1:4848 storie
```

Ctrl-C 或 SSH 断开会关闭转发 helper 及其 exec 进程，浏览器和 dashboard
保持运行。需要停止 dashboard 时：

```sh
sudo /etc/openclaw/compose exec -T engine podman exec CONTAINER \
  agent-browser dashboard stop
```

新版包装器也支持在沙箱内执行 `browser-profile dashboard start` / `stop`。
dashboard 依赖该沙箱的 daemon 目录，只显示已启动的 session；任务副本里的
修改仍不会写回主登录。需要持久登录时操作 `role-identity`，成功后再
`browser-profile publish`。
