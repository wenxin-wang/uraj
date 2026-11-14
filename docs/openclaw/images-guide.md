# OpenClaw 镜像准备

配置依据上游 `v2026.10.3` 的文档、Dockerfile 和飞书插件定义。
采用该版本的上游 Dockerfile，显式预装 `feishu`，不在服务器启动时
联网安装插件。下面在有 Docker 的构建机执行；源码构建需要至少 6 GB
内存，上游默认 Node 构建堆上限为 8 GB，构建机应留足余量。

```sh
git clone --branch v2026.10.3 --depth 1 https://github.com/openclaw/openclaw.git openclaw-source
cd openclaw-source
git rev-parse HEAD
docker build --build-arg OPENCLAW_EXTENSIONS=feishu \
  --tag localhost/openclaw-gateway:2026.10.3 .
# 检查 /app/dist 中的代码能否解析飞书 SDK；失败时不要部署该镜像。
docker run --rm --network none --read-only --user 1000:1000 \
  --workdir /app/dist --entrypoint node \
  localhost/openclaw-gateway:2026.10.3 \
  --input-type=module -e 'await import("@larksuiteoapi/node-sdk")'
docker save --output openclaw-2026.10.3.tar localhost/openclaw-gateway:2026.10.3
scp openclaw-2026.10.3.tar storie.home.labbies.wenxinwang.me:/tmp/
```

记录实际源码 commit 和构建日志。镜像必须为 storie 的 CPU 架构；不要
把其它架构构建出的镜像直接加载。也可以用上游支持的 Podman 构建流程。
在 storie 上加载并取得不可变 image ID：

```sh
sudo docker load --input /tmp/openclaw-2026.10.3.tar
sudo docker image inspect --format '{{.Id}}' localhost/openclaw-gateway:2026.10.3
```

把输出的完整 `sha256:...` 填入 `image`，`image-repository` 保持
`localhost/openclaw-gateway`。本地构建镜像不一定有 RepoDigest，不能把
image ID 拼成 `repository@sha256:...`；两者含义不同。服务也接受真正的
registry manifest digest 引用，但它同样必须已存在于本机。默认配置
不接受仅 tag 的可变引用。

核心和插件随整个镜像升级。不要在运行中的容器执行 `openclaw update`
或 `plugins install`。此仓库不自动构建、拉取或发布镜像。

针对现有 `v2026.10.3` 镜像，在本仓库根目录构建部署层，`BASE_IMAGE` 是上一步
得到的上游镜像 ID，`<TAG>` 自定。它安装上游飞书插件
声明的 `@larksuiteoapi/node-sdk@1.74.0`，保留原有 pnpm 依赖树，并在构建中
以运行用户验证导入；同时按固定 sha256 安装与引擎一致的 Podman 5.8.9 静态
远程客户端，供 Podman 沙箱后端使用。它还应用 `feishu-topic-chat.mjs` 和
`feishu-guarded-progress.mjs`、`feishu-card-style.mjs`，按内容定位编译后的
飞书消息处理、回复和卡片构造函数；
找不到预期代码时构建失败，升级上游版本后需重新核对。
SDK 补丁不保证解决 Doctor 的其它错误；
传递依赖未锁定，应记录构建产物 ID。

```sh
sudo docker build --network=host --pull=false \
  --build-arg BASE_IMAGE=<上游镜像 ID> \
  -t localhost/openclaw-gateway:<TAG> \
  env/docker/openclaw-gateway
sudo docker run --rm --network none --read-only \
  --user 1000:1000 --workdir /app/dist --entrypoint node \
  localhost/openclaw-gateway:<TAG> \
  --input-type=module -e 'await import("@larksuiteoapi/node-sdk")'
sudo docker image inspect --format '{{.Id}}' localhost/openclaw-gateway:<TAG>
```

把输出的新 ID 写入 `env/guix/os/storie.scm` 的 OpenClaw `image` 字段，
重新部署并检查启动日志。保留原镜像以便回退。

## 沙箱引擎与沙箱镜像

两个镜像都以 UID/GID 2010 构建，须与 `openclaw-configuration` 的 `uid`、
`gid` 一致。引擎基于固定 digest 的 `quay.io/podman/stable:v5.8.9`；沙箱参照
上游 sandbox Dockerfile，改用固定的 `debian:trixie-slim`，加少量常用工具和
浏览器（见 [browser-guide](browser-guide.md)），`HOME` 为可写的 `/tmp`。OpenClaw 提示词要求
文件工具的临时文件放在工作区 `.openclaw/tmp/`，但 crun 为挂载 skill 创建
`.openclaw` 时属主是沙箱 root 映射的子 UID，沙箱用户写不进去。服务启动时在
引擎的 `podman unshare` 中为每个工作区补建属主 2010、权限 0700 的
`.openclaw/tmp`（跳过符号链接；该命名空间只拥有 2010 与沙箱子 UID，碰不到
主机其他文件）；运行中新建的角色在登记时直接创建。各角色只在自己的工作区
内，不互相共享。Debian 包未锁版本，
浏览器用 Debian 的 `chromium`：storie 连不上 Google 的下载站，Debian 软件源
可用，trixie 也持续跟进 Chromium 安全更新。与官方 Chrome 相比，UA 相同，但
Client Hints 报告的品牌是 Chromium；少数风控严格的网站可能区别对待。构建
结果不可复现，以 image ID 记录产物，冒烟测试打印的 UA 含浏览器版本。Podman
会缓存安装层；普通重启不会强制刷新 Debian 包。

```sh
sudo docker build --network=host -t localhost/openclaw-sandbox-engine:5.8.9-1 \
  env/docker/openclaw-sandbox-engine
sudo docker image inspect --format '{{.Id}}' localhost/openclaw-sandbox-engine:5.8.9-1
```

引擎的 seccomp profile 由镜像自带的 `/usr/share/containers/seccomp.json`
生成，仓库保存结果。构建或更换引擎镜像后，用实际镜像重新生成并检查 diff：

```sh
sudo guix shell python docker-cli -- python3 scripts/openclaw/engine-seccomp.py \
  localhost/openclaw-sandbox-engine:5.8.9-1 > env/docker/openclaw-sandbox-engine/seccomp.json
git diff env/docker/openclaw-sandbox-engine/seccomp.json
```

把引擎 ID 写入 `engine-image`。storie 不配置 `sandbox-image`（默认 `#f`）：
每次 Shepherd 启动时，先停止旧服务、启动引擎并等待健康，再在引擎中
执行 `podman build --layers --network=host`，传入配置中的 UID/GID。
构建上下文随 Guix 部署到 store，只读挂载到引擎的
`/etc/openclaw/sandbox-build`，服务器无需仓库工作目录；修改
`env/docker/openclaw-sandbox/` 后重新部署即可。构建网络使用引擎所在的
`sandboxed-agents`，这里的 `host` 指引擎容器的网络命名空间。
首次构建或缓存失效时需要联网，启动耗时也会更长。Podman 使用持久缓存，
普通重启不强制更新软件包。

镜像直接生成在引擎持久存储 `/data/openclaw/engine` 中。构建结果 ID 从
`/run/openclaw-engine/sandbox-image` 复制到
`/run/openclaw/sandbox-image`，只读挂载给 Gateway，由配置协调程序
写入实际沙箱配置；无需手动填写 ID。校验实际 ID 存在后才启动 Gateway。
构建阶段可以拉取基础镜像，沙箱运行时仍从不拉取镜像。构建或校验失败会
停止启动，不自动回退到旧镜像；修复后用 `herd start openclaw` 重试。

如需使用手工构建的镜像，可显式配置 `sandbox-image` 为本地 `sha256:` ID，
此时跳过构建，若引擎缺少该 ID，则从主机 Docker 自动导入。
手工冒烟测试可用 Docker 构建：

```sh
sudo docker build --network=host --no-cache -t localhost/openclaw-sandbox:trixie-1 \
  env/docker/openclaw-sandbox
```

导入引擎前可先冒烟测试沙箱镜像。脚本以去掉全部 capability、只读根和
tmpfs 运行它，接入 `sandboxed-agents`，检查文件桥接工具、CLI 版本和内置
skill，再用有头 Chromium 打开 `https://example.com`，打印 UA、
`navigator.webdriver` 和 WebGL renderer；UA 含 `Headless` 或使用软件渲染
时失败：

```sh
scripts/openclaw/try-sandbox-image localhost/openclaw-sandbox:trixie-1
```

更换沙箱镜像、skill 或挂载后，需要重建旧沙箱。若在线 CLI 提示需要独占离线
状态所有权，先由 Shepherd 停止服务，再只启动 engine，用临时容器执行：

```sh
sudo herd stop openclaw
sudo /etc/openclaw/compose up -d --pull never --no-build --wait engine
sudo /etc/openclaw/compose run --rm --no-deps --pull never \
  --entrypoint node gateway /app/openclaw.mjs sandbox recreate --all
sudo herd start openclaw
```

等待重建命令成功退出后再启动服务；若仍提示所有权未释放，稍等后重试
重建命令，不删除状态锁。此操作重建工具容器，保留 workspace 和记忆。
