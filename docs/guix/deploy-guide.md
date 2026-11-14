# 用 guix deploy 远程更新

## 用 guix deploy 远程更新

共享的 `base-os` 创建 `guix-deploy` 用户，桌面和服务器都继承它。
该账户没有密码登录、没有 wheel 附加组，SSH 复用 wenxin 的公钥，
并通过 authorized_keys 的 `restrict` 禁用 PTY、转发和用户 rc。
它仍需要正常 shell，以运行 SSH 远程命令。

sudoers 仅允许 root 执行系统 profile 的 `guix repl -t machine`，
以及路径匹配 store 内 Guile 的 `guile --no-auto-compile ...`。
这些是锁定 Guix 的部署协议所需入口，不能只允许 `system reconfigure`。
这只是命令入口白名单：解释器能执行任意 root 代码，部署者仍是等同
root 的可信管理员。它不是“只能部署”的安全隔离；不要把这个密钥
交给不可信用户。升级 Guix 后如调用形式改变，应重新审阅规则。

### 首次启用

将更新后的仓库同步到目标机，在目标机仓库根目录以 wenxin 执行一次：

```sh
unset TO_ISO
sudo -E guix time-machine -C env/guix/channels-lock.scm -- \
  system reconfigure -L src/guix -L src/guile env/guix/os/storie.scm
```

这一步需要现有 sudo 密码；尚未创建的 guix-deploy 不能自举自己。
其他主机启用时改用各自的系统配置文件。

### 日常部署 storie

在开发机仓库根目录执行，不加 sudo：

```sh
unset TO_ISO
guix time-machine -C env/guix/channels-lock.scm -- \
  deploy -L src/guix -L src/guile --dry-run env/guix/os/deploy/storie.scm
guix time-machine -C env/guix/channels-lock.scm -- \
  deploy -L src/guix -L src/guile env/guix/os/deploy/storie.scm
```

也可用 Home 安装的 `uraj-deploy storie`，它经 maak 直接部署，不预演。
目标后的参数会传给 `guix deploy`，例如 `uraj-deploy storie --dry-run`。
传入配置文件路径（例如 `uraj-deploy /path/to/worktree/env/guix/os/deploy/storie.scm`）
时，从文件的真实路径向上查找最近的 `.envrc`，加载该目录的 direnv 环境，
并使用其中的 `env/guix/os/maak.scm`。`uraj-system-reconfigure` 和
`uraj-home-reconfigure` 也支持这种方式；未传入配置文件时仍使用
`~/src/uraj`。环境须已通过 `direnv allow` 授权；找不到环境或加载失败时停止。

部署尚未合并的工作树时，在该工作树根目录执行以下命令。直接使用仓库
中的入口，无需先更新本机 Home；显式路径确保使用当前工作树的配置，
而不是 `uraj-deploy storie` 默认选择的 `~/src/uraj`：

```sh
direnv allow
./env/dotfiles/common/shell/.local/bin/uraj-deploy env/guix/os/deploy/storie.scm --dry-run
./env/dotfiles/common/shell/.local/bin/uraj-deploy env/guix/os/deploy/storie.scm
```

storie 的部署声明已经设置 `(build-locally? #t)`，系统在开发机构建，
再传输到 storie 激活，不需要在 storie 执行 reconfigure。

`uraj-home-reconfigure` 未传入配置文件时，若存在 `env/guix/os/$(hostname).scm`
则部署该机器配置中嵌入的 Home（见 [Home-only deployment](home-only-deploy-guide.md)），否则使用
`env/guix/os/home.scm`。

`uraj-system-reconfigure` 和 `uraj-home-reconfigure` 会将配置路径后的
额外参数原样传给 Guix，例如临时指定 substitute 源：

```sh
uraj-system-reconfigure env/guix/os/lappie.scm \
  --substitute-urls="https://mirror.sjtu.edu.cn/guix https://mirror.sjtu.edu.cn/guix-bordeaux https://bordeaux.guix.gnu.org https://substitutes.nonguix.org"
```

直接使用 Maak 时，用 `--` 分隔任务参数，避免选项被 Maak 解析：

```sh
maak -f env/guix/os/maak.scm -- system-reconfigure -- \
  env/guix/os/lappie.scm --dry-run
```

入口固定 storie 的 Ed25519 主机公钥，使用端口 23333、guix-deploy
账户和开发机 `$HOME/.ssh/simple` 私钥。本地构建，SSH 传输并激活；
`authorize? #t` 允许远端导入开发机签名的 store 产物。
预演可能连接远端，不代表服务启动或重启验证已通过。

部署后用 wenxin 登录检查 `sudo herd status`、`sudo herd status immich`
和 `sudo /etc/immich/compose ps`。内核及 ZFS/it87 模块更新后安排重启。
回滚命令：

```sh
guix time-machine -C env/guix/channels-lock.scm -- \
  deploy -L src/guix -L src/guile --roll-back env/guix/os/deploy/storie.scm
```

系统代回滚不恢复数据库、照片或 ZFS 数据。
