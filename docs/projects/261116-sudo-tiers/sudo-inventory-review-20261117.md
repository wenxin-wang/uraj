# sudo 用法盘点（2026-11-17）

sudo-tiers 第 2 步（盘点 sudo 用法）的结果：列出 `docs/` 各 guide、主机配置注释和
脚本里出现的 sudo 命令，按两级（免口令、手机签名）归类，并标出看上去只读或只是
启停服务、实际能间接执行任意代码的命令。人的 shell 历史没有盘点：本 session 在
Paseo 沙箱里看不到主机的历史文件，人贴回了统计结果，见“日常用法”一节。

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
  锁在外面。11/17 定：远程主机上这几个不放免口令一级。

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
OpenClaw 沙箱里的浏览器会话。11/17 定：放签名一级。

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

## 日常用法

人在主机终端跑了下面的统计，贴回了前 40 条（共 378 次）：

```sh
grep -hoE 'sudo( -[A-Za-z]+)* +[^ |;&]+( +[^ |;&-][^ |;&]*)?' ~/.bash_history \
  | sort | uniq -c | sort -rn | head -40
```

| 类别 | 次数 | 主要命令 | 归哪级 |
|---|---|---|---|
| `herd` 状态和启停 | 178 | `herd restart` 81、`status` 47、`stop` 39、`start` 9、`logs` 2 | 免口令（不带参数时） |
| System 部署 | 72 | `-E maak system-reconfigure` 41、`-E maak` 13、`guix time-machine` 14、`-E maak guix` 4 | 手机签名 |
| 读写解密后的秘密 | 34 | `vim`/`cat /run/secrets/contained-agent/projects.scm` 20、`env SOPS_AGE_KEY_FILE=... sops` 8、`cat /run/secrets/strongswan/...` 4、`vim /run/secrets/paseo/config.yaml` 2 | 手机签名 |
| 读日志和数据 | 28 | `cat .../new-api/traj-records/traj.jsonl` 12、`tail` 5、`rg` 5、`vim /var/log/...` 4、`grep` 2 | 手机签名，或改权限免 sudo |
| 内核和硬件 | 17 | `dmesg` 8、`tcpdump` 5、`libinput debug-events` 5、`evtest` 2 | `dmesg` 免口令，其余签名 |
| root shell | 9 | `-i` 5、`bash` 4 | 手机签名 |
| 改 `/etc` 等 | 14 | `vim /etc/resolv.conf` 6、`vim /etc/hosts` 2、`mount` 2、`chmod` 2、`resolvconf` 2 | 手机签名 |
| 其余 | 26 | `"$(command ...)"` 14、`reboot` 3、`ls /etc/guix/` 3、`btrfs filesystem` 2 | 见下 |

结论：

- 免口令一级覆盖约一半（`herd` 178、`dmesg` 8、`reboot` 3、`btrfs filesystem
  show/usage/df` 2）。`herd restart` 里带参数的有多少没统计，guide 里只有换镜像
  tag、relay commit 这几种，应该不多。
- System 部署是签名一级最大的一块（72 次，约占全部的五分之一），调试配置时会连着
  部署好几次。所以“一次批准管一段时间”对部署值得做，或者照上文“System 部署”签
  store 路径，每次部署批一次但页面上看得清是什么。
- 读日志和数据的 28 次可以用权限消掉：日志归档也保持 `log-readers` 组；new-api 的
  traj 记录也归 `log-readers` 可读（11/17 定，见文末）。之后 `tail`、`rg`、`vim`
  不再要 sudo。用 `vim` 以 root 打开日志本身
  就等于 root shell。
- 改 `/run/secrets/` 下解密后的副本（20 多次）是在试配置：改动在 `sops-secrets`
  重启后被覆盖，正式的改法是编辑 SOPS 密文再重启。签名一级下每次都要批，可以
  接受；contained-agent 的项目配置以后要不要挪出 `/run/secrets/`，留给
  contained-agent-v2。
- `dmesg` 只放不带参数和 `-T`、`-w` 一类只读选项，`-C`、`-c` 会清空内核日志。
  `reboot` 和停服务一样只是 DoS，lappie 上可以免口令，远程主机上签名（同上文
  “停 `ssh-daemon`”的决定）。
- `tcpdump` 能读全部流量，`-z` 还能执行命令，签名一级。
- `sudo "$(command -v libinput)" record` 14 次：人给 agent 当 harness 时 agent 要
  的，人自己不常用。见文末。

## 待人补充和待定

- 11/17 人定：远程主机上停 `ssh-daemon`、`networking`、strongSwan（以及 `reboot`）
  不放免口令一级；OpenClaw 的只读操作做成 Shepherd action，放免口令一级。
- 11/17 定：`browser-dashboard.py` 放手机签名一级。它把 OpenClaw 沙箱里浏览器的
  dashboard 转发到本机，SSH 模式下把本地 checkout 里的 helper 代码经 SSH 参数传到
  远端以 root 执行，等于 root shell；日常统计里没出现，签名的频率可以接受。
- 11/17 定：`sudo "$(command -v libinput)" record` 这类命令是 agent 某段任务里反复
  要的，人不常用。归签名一级；agent 的请求可以“批准一次，同一条命令在一段时间内
  不再问”，让 agent 接着干。这是“一次批准管一段时间”的第二个用处（第一个是部署），
  范围按命令（`argv` 或解析后的路径加参数模式）和请求方（哪个盒子或 session）限定，
  具体规则留给特权执行器的设计。`libinput record` 和 `debug-events` 一样读全部输入
  事件，不放免口令。
- 11/17 定：new-api 的 traj 记录归 `log-readers` 可读，不另开组。记录是模型调用的
  输入输出，人会让 agent 读来优化 prompt；上游本来就能看到这些数据，人也不往里传
  token 一类秘密，所以按日志对待。改 `src/guix/uraj/services/new-api.scm` 的目录
  权限，放第 4 步（分级落地）或单独的 new-api PR。
