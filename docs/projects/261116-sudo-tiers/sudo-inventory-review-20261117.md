# sudo 用法盘点（2026-11-17）

sudo-tiers 第 2 步（盘点 sudo 用法）的结果：列出 `docs/` 各 guide、主机配置注释和
脚本里出现的 sudo 命令，按两级（免口令、手机签名）归类，并标出看上去只读或只是
启停服务、实际能间接执行任意代码的命令。人的 shell 历史没有盘点：本 session 在
Paseo 沙箱里，看不到主机的历史文件，见文末“待人补充”。

## 免口令一级能被谁用

- 本 session（Paseo 启动的 agent）里跑 `sudo -V` 直接失败：沙箱设了
  `no_new_privs`，setuid 不生效。contained-agent 的容器同理。所以免口令一级挡的
  不是容器里的 agent，而是主机上以 `wenxin` 身份跑、不在沙箱里的进程：桌面会话
  里的程序、浏览器、Emacs、终端，以及 SSH 登录 storie、hypie 的会话。
- 这些进程被攻破时，免口令一级的命令等于白送。所以这一级只放两类：只读且不泄露
  秘密的命令，和坏了最多是停服务（DoS）的命令。

## 归类

### 免口令

| 命令 | 出处 | 条件 |
|---|---|---|
| `herd status`、`herd status <服务>` | 多数 guide | 服务名用正则限定，不带别的参数 |
| `herd start/stop/restart <服务>` | 多数 guide | 不带参数；排除 `root`（见下文“`herd`”） |
| `herd schedule mcron <数字>` | `maa/daily-tasks-guide.md` | 参数限定为数字 |
| `herd configuration <服务>` | uraj 各服务的 `configuration` action | 只打印配置文件路径 |
| `/etc/<服务>/compose ps` | immich、new-api、paseo-relay、openclaw 的 guide | 精确匹配，不带别的参数 |
| `/etc/immich/compose logs --tail <数字>` | `guix/immich-guide.md` | 日志可能含秘密，见下文 |
| `docker images ...`、`docker image inspect ...`、`docker network inspect ...` | images、new-api、relay、redroid 的 guide | 见下文“`docker`” |
| `nft list table inet restricted_network`、`nft list table ip restricted_network` | `maa/redroid-guide.md` | 精确匹配 |
| `swanctl --list-sas --uri unix:///run/strongswan-charon.vici` | `guix/strongswan-guide.md` | 精确匹配；`--uri` 不能放开 |
| `resolvconf -l` | `guix/strongswan-guide.md` | 精确匹配 |
| `exportfs -v` | `guix/storie-network-guide.md` | 精确匹配；`exportfs -a`、`-r` 会改导出 |
| `test -s /var/lib/sops/age/keys.txt` | `secrets/sops-guide.md` | 精确匹配 |
| `age-keygen -y /var/lib/sops/age/keys.txt` | `secrets/sops-guide.md` | 精确匹配；只输出公钥，换路径就能读别的文件 |
| `cat /run/openclaw/sandbox-image` | `openclaw/browser-guide.md` | 精确匹配 |

### 手机签名

| 命令 | 出处 | 为什么 |
|---|---|---|
| `uraj-system-reconfigure`、`sudo -E guix time-machine ... system reconfigure` | `guix/deploy-guide.md` | 改系统；`-E` 带进整个用户环境 |
| `herd restart new-api <tag>`、`openclaw <tag>`、`paseo-relay <commit>` | new-api、openclaw、relay 的 guide | 带参数的启停，见下文 |
| `herd load root ...` | `restricted-network/networks-guide.md` | 加载任意 Scheme，等于 root shell |
| `/etc/<服务>/compose exec/run/up/build ...` | openclaw 的 config、deploy、feishu、images guide；relay | 在容器里执行任意命令，容器挂着秘密和数据 |
| `docker build/run/load ...` | `openclaw/images-guide.md` | docker 守护进程等于 root |
| `docker inspect <容器>`、`docker logs <容器>` | openclaw、redroid 的 guide | 输出容器环境变量和日志，可能含秘密 |
| `mount ...`、`mkdir -p /mnt/...` | `guix/storie-network-guide.md` | 改文件系统 |
| `sops decrypt`（带主机 age key） | `secrets/sops-guide.md`、sudo-tiers 交接 | 解出秘密 |
| `sudo python3 scripts/openclaw/browser-dashboard.py`、`sudo scripts/openclaw/try-browser-gpu`、`sudo guix shell ... scripts/openclaw/engine-seccomp.py` | openclaw 的 browser、images guide | 以 root 跑工作区里的脚本，见下文 |
| `libinput debug-events` | `env/dotfiles/desktop/niri/.config/libinput/plugins/50-touchpad-dead-zones.lua` 注释 | 读全部输入事件，等于键盘记录 |
| `zpool import -f data`、`sudo -i` | `env/guix/os/hypie.scm` 注释 | 装机时的一次性操作 |
| `herd start cow-store /mnt`、`install -d /mnt/tmp` | `src/guix/uraj/system/iso.scm` 注释 | 安装盘上的操作，安装盘不用本仓库的 sudoers，不在范围内 |

### 不需要 sudo 的

- `sudo grep 'openclaw/' /var/log/messages`（`openclaw/images-guide.md`）：当前
  `messages` 是 `root:log-readers 0640`，`wenxin` 直接能读，这里的 sudo 可以去掉。
  轮转出来的归档可能变回 root 组，读归档仍要 sudo。

## 看上去无害、实际危险的

### `herd`

- `herd` 的动作和参数都要限定。`root` 服务的 `eval`、`load`、`reload`、`daemonize`
  等动作都是执行任意代码；`herd stop root` 关机。Guix 的 `%base-services` 带
  Shepherd 的 `transient`、`timer` 服务，它们的 `spawn` 动作以 root 跑任意命令。所以 sudoers 里
  只放 `status`、`start`、`stop`、`restart`、`configuration`、`schedule mcron` 这几种
  形式，服务名用 `^[a-z0-9-]+$` 一类的正则，再排除 `root`。
- 带参数的启停要签名：
  - `herd restart new-api <tag>`、`herd restart openclaw <tag>` 只能换成同一个
    仓库的另一个本地镜像，而本地镜像只能用 docker 构建或导入（要签名），风险不大。
    但一律按“带参数就签名”处理，规则简单。
  - `herd restart paseo-relay <commit>` 会用 `https://github.com/getpaseo/paseo-relay.git#<commit>`
    以 `--network host` 现场构建并运行。GitHub 上同一个 fork 网络里的提交可能可以
    经上游仓库的地址按 SHA 取到（没验证），那就等于任何人都能让 storie 构建他写的
    Dockerfile。即使不是这样，也能换回带漏洞的旧版本。
- 停服务只是 DoS，但远程主机上停 `ssh-daemon`、`networking`、strongSwan 会把人
  锁在外面。要不要另行排除，待人定。

### `/etc/<服务>/compose`

这是 `docker compose --project-name <服务> --file <store 里的 compose 文件>` 的包装，
其余参数原样传下去。`ps` 只读；`exec`、`run`、`up`、`build` 都能执行任意代码。
OpenClaw 的几条常用操作（`pairing list/approve`、`config.mjs check/set`、
`channels status --probe`、`secrets audit --check`）都是经 `compose exec` 进
Gateway 容器做的，所以全落在签名一级。常用的只读操作（`pairing list`、
`config.mjs check`、`channels status --probe`）可以做成服务的 Shepherd action，例如
`herd pairing-list openclaw`，和现有的 `configuration` action 一样，再把这几个 action
放进免口令一级。`pairing approve`、`config.mjs set` 改的是谁能用 bot、bot 的行为，
留在签名一级。

### `docker`

- docker CLI 以 root 跑时用的是 root 的 `~/.docker`，sudo 默认重置环境，
  `DOCKER_HOST` 一类变量带不进去；`--format` 的 Go 模板不能执行命令。所以
  `docker images`、`docker image inspect`、`docker network inspect` 可以免口令，但
  sudoers 要限定到子命令，不能写 `docker *`。
- `docker inspect <容器>` 会输出容器的环境变量，`docker logs` 是容器的全部输出，
  都可能含秘密，放签名一级。容器日志已经经 syslog 进 `/var/log/<服务>/`，
  `log-readers` 免 sudo 能读，平时用不着 `docker logs`。

### 工作区里的脚本

`browser-dashboard.py`、`try-browser-gpu`、`engine-seccomp.py` 是以 root 跑工作区
里的文件。工作区 agent 能写，所以签名必须覆盖脚本内容（README“特权执行器的形态”
里的快照要求）。`browser-dashboard.py` 还自己调 `sudo -n`，指望有缓存的口令或
NOPASSWD；签名一级下每次开 dashboard 都要批一次。常用的话可以把它打包进系统
profile，sudoers 只放 `/run/current-system/profile/bin/` 下的固定路径。它能操作
OpenClaw 沙箱里的浏览器会话，放不放免口令待人定。

### System 部署

`uraj-system-reconfigure` 是 `sudo -E maak ...`，root 一侧求值工作区里的 Guix 代码。
签名要覆盖的东西很难说清楚（工作区、channels、环境变量）。更好的做法是：以人的
身份 `guix system build` 出系统的 store 路径，签名只签这个路径（页面上可以显示
uraj 的提交和 channels 锁文件的 hash），root 一侧只做激活和安装 bootloader。
store 路径不可变，签了什么就执行什么。这一条留给第 5 步（和特权执行器接上），
`guix-deploy` 旁路也可以照这个思路收紧。

## 写 sudoers 时要注意

- 现在 `wheel` 没设 `secure_path`，sudo 按用户的 `PATH` 找命令，再按全路径匹配
  规则。NOPASSWD 规则写的是 `/run/current-system/profile/bin/herd`，用户
  `PATH` 里先找到 `~/.guix-profile/bin/herd` 就匹配不上，又落回要口令的规则。要给
  `wheel` 也设 `secure_path`，和 `guix-deploy` 一样只放系统 profile。
- 参数用正则（`^...$`）写，不用 `*`：sudoers 里的 `*` 能匹配空格，`herd restart *`
  会放过 `herd restart paseo-relay <commit>` 和 `herd restart root`。现有的 `%deploy-sudoers` 已经在用
  正则，说明 Guix 的 sudo 版本支持。
- `-E` 要 `SETENV` 标签才能用；签名一级由执行器自己设环境，不再需要 `-E`。
- storie、hypie 上人也会远程敲 sudo（`browser-dashboard.py` 的 SSH 模式），每台
  主机都要有登记过的 passkey 公钥。公钥不是秘密，可以放进主机配置。

## 待人补充和待定

- 日常实际敲的 sudo：guide 之外的不在这里。人在 lappie、storie 的终端里跑一下，
  把结果（或者其中不想公开的部分去掉后）贴回来：

  ```sh
  grep -hoE 'sudo( -[A-Za-z]+)* +[^ |;&]+( +[^ |;&-][^ |;&]*)?' ~/.bash_history \
    | sort | uniq -c | sort -rn | head -40
  ```

  这决定签名一级的频率，也就决定“一次批准管一段时间”值不值得做。
- 远程主机上停 `ssh-daemon`、`networking`、strongSwan 要不要排除出免口令一级。
- OpenClaw 的只读操作要不要做成 Shepherd action 放进免口令一级。
- `browser-dashboard.py` 放哪一级。
