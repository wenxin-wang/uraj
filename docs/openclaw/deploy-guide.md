# OpenClaw 部署：秘密、配置、存储、版本

## 秘密

一份 SOPS 密文，三个独立凭据：

```yaml
openclaw:
  feishu-app-secret: <飞书 App Secret>
  new-api-token: <OpenClaw 专用 new-api token>
  gateway-token: <独立生成的高熵随机 token>
```

在项目 Guix 环境中创建：

```sh
gpg --import secrets/keys/admin.asc
sops secrets/hosts/storie/openclaw.yaml
```

新建加密文件只需 `.sops.yaml` 中已登记收件人的公钥，不需要 GPG 卡。
编辑已有密文需要任一授权私钥，例如管理员卡或 storie 的机器 age
identity。凭据可等飞书应用创建后再填；不要提交上述明文模板或假凭据。
Gateway token 可用密码管理器生成至少 32 字节随机值，直接填入 SOPS
编辑器，不把 token 放进命令行参数或聊天。

服务自动向已有的 `sops-secrets-service-type` 贡献三个 secret，全部
解密为 root:root 0400。每次启动复制到 root-only 的 `/run/openclaw/`
下，文件归专用 UID/GID 2010 所有、模式 0400，只单独只读挂载到 Gateway
的 `/run/secrets/`，不挂给引擎或沙箱。SecretRef 引用这些普通文件，Guix store、Compose 和
声明配置都只有路径及引用，没有凭据值。容器不获得主机 age/GPG 私钥。

Gateway、引擎和沙箱都以主机账号 `openclaw`（UID 2010）运行，不与管理员
共用 UID。凭据隔离来自挂载：沙箱进程虽是同一 UID，但其挂载命名空间
里没有这些文件。SecretRef 本身不是任意代码执行场景中的秘密隔离边界。

轮换时先更新密文及系统声明，再重新解密，然后重建容器：

```sh
sudo herd restart sops-secrets
sudo herd restart openclaw
```

先确认 sops-guix 已成功更新实际文件；不要输出秘密来检查。SecretRef
持有运行时快照，文件 bind mount 也可能仍引用旧 inode，所以本方案
明确通过重新创建容器完成轮换。

## 配置、存储与启动

停用 OpenClaw 时把 `%openclaw-configuration` 设为 `#f`。
在 storie 的仓库开发环境中，先确认声明的镜像确实存在（此命令不拉取）：

```sh
for image in <image> <engine-image>; do
  sudo docker image inspect --format '{{.Id}} {{.Architecture}}' "$image"
done
```

确认使用含飞书插件的镜像后，部署 storie（命令见
[guix/deploy-guide](../guix/deploy-guide.md)，例如 `uraj-deploy storie`），
然后在 storie 上：

```sh
sudo herd restart sops-secrets
sudo herd start openclaw
sudo herd status openclaw
sudo /etc/openclaw/compose exec gateway node openclaw.mjs channels status --probe
```

已运行时 `herd start` 不会重建容器；修改配置或轮换凭据后使用
`herd restart openclaw`。

完成首次私聊配对，再分别用 GPT 和 Claude 模型发送一条消息，确认
new-api 的 token 权限、模型名称及协议均可用。不要以 Gateway 的
健康检查通过代替这一步。

| 主机路径 | 容器路径 | 用途 |
|---|---|---|
| /etc/openclaw/base.json | 同路径，只读 | Guix 初始配置与不变量 |
| /etc/openclaw/config*.mjs | 同路径，只读 | 校验入口与策略 |
| /etc/openclaw/config-plugin | 同路径，只读 | 校验工具插件 |
| /etc/openclaw/engine-seccomp.json | 引擎的 seccomp profile | Docker 读取 |
| /data/openclaw/home | 同路径（Gateway） | 状态、认证、备份及维护文件 |
| /data/openclaw/workspaces | 同路径（Gateway、引擎） | 各 agent 工作区，main 在 `main/` |
| /data/openclaw/engine | 引擎 Podman 存储 | 沙箱镜像与容器 |
| /run/openclaw-engine | 同路径（Gateway、引擎） | 引擎 API socket |
| /run/openclaw/\<secret> | /run/secrets/\<secret> | 运行时秘密，仅 Gateway |
| /var/log/openclaw/containers.log | syslog 接收 | 运维日志，轮转 |

附件初期随 state 保存；`/media-data/openclaw/` 暂不创建。
home 是私有数据；workspace 可由 `log-readers` 读取，见 [sandbox-guide](sandbox-guide.md)。
HOME 整体可写，允许上游创建 `.openclaw`、`.config/openclaw` 和
`.openclaw.update-captures` 等目录；镜像根文件系统和声明配置仍只读。
运行配置可写；启动前先对齐 Guix 基础字段并验证，Doctor 修复与升级迁移
仍属于受信任维护操作。若它们引入策略不支持的 agent 字段，下次校验或
启动会拒绝，应审查后调整策略，不自动删除动态数据。
启动程序按上文创建目录与属主；新 HOME 权限为 0700、属主为 2010:2010。
新增网络（如 `sandboxed-agents`）后，正在运行的 `restricted-network` 不会因
reconfigure 重新执行，网络与规则尚不存在；Compose 要求所有外部网络存在，
因此连启动前的 reconcile 也会失败。须先执行
`sudo herd restart restricted-network`（会短暂重启依赖它的服务），再启动
OpenClaw。
容器 stdout/stderr 遵循现有日志组规则；它们也可能带有聊天相关诊断信息。
不要开启含凭据或完整消息的调试日志。应用自己的临时文件日志在容器
`/tmp`，不作长期保存。HOME 下的 `.cache` 另挂载 128 MiB tmpfs，
由 UID/GID 2010 拥有、权限 0700，支持 OpenClaw 的安全临时目录
fallback；缓存随容器销毁，不进入持久数据目录。

Shepherd 等待 `dockerd`、`restricted-network`、`sops-secrets`、
`syslogd` 和 `file-system-/data`。每次 start 再检查 /data 确为 Btrfs
挂载、秘密非空和 DNS 快照有效，之后才创建目录。拒绝符号链接目录，
不递归更改已有用户数据权限，并删除引擎上次遗留的 socket。Docker bind
mount 禁止自动创建缺失路径。

Gateway 仅连接 `static-agent`，引擎仅连接 `sandboxed-agents`。启动器把网络服务的
`/run/restricted-network/resolv.conf` 转成两个服务的 Docker 显式 DNS override，
不会使用主机实时 resolver。`static-agent` 允许公网 TCP 80/443 以及 new-api
`172.31.0.9:3000`；`sandboxed-agents` 只允许公网 TCP 80/443。它们不是域名
白名单，同桥也不是容器间隔离。
刷新 DNS 时先停 OpenClaw，再重启 restricted-network，最后启动 OpenClaw。

Compose 采用 `on-failure`，不会随 Docker daemon 启动而绕过 Shepherd。
镜像本地检查、运行时准备之后，启动引擎并等待其 Podman API 健康，
在引擎内构建沙箱镜像、协调配置，再执行 `config validate` 并验证镜像 ID，最后启动
Gateway，等待 `/startupz`。这个检查不代表飞书和模型都连通；
需要下面的端到端验收。容器健康状态变成 unhealthy 不会由 Docker 的
on-failure 自动重启；该策略只处理进程退出。

基础设置以 Guix 声明为准。agent 配置编辑使用[校验入口](config-guide.md)；UI/向导属于
可信管理员入口，不会自动经过该校验。没有发布主机端口，管理界面通过 SSH
转发至容器 IP：

```sh
sudo /etc/openclaw/compose ps
sudo /etc/openclaw/compose exec gateway node openclaw.mjs channels status --probe
sudo /etc/openclaw/compose exec gateway node openclaw.mjs secrets audit --check
sudo docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' openclaw-gateway-1
```

在客户端把实际容器 IP 填入下面命令，打开 `http://localhost:18789`，
在 UI 输入 Gateway token，并按上游流程完成设备配对，不禁用认证：

```sh
ssh -N -L 18789:<container-ip>:18789 storie.home.labbies.wenxinwang.me
```

容器重建可能改变 IP，届时重开隧道。`/etc/openclaw/compose` 用于
exec、logs、ps 等运维操作；启动和停止交给 Shepherd，以保留前置检查。

## 版本切换与备份

```sh
sudo herd restart openclaw 2026.10.3
sudo herd status openclaw
sudo herd restart openclaw
```

带 tag：在配置的镜像仓库中选择已加载的 tag；不带 tag：恢复声明中的
不可变镜像。启动时解析实际 image ID，再按该 ID 启动，Shepherd 的
running value 同时记录请求引用和实际 ID。镜像不存在则失败，不联网
拉取。注意 `restart` 会先停止旧实例，随后才执行新实例检查；失败时
不会承诺旧实例仍运行，也不会自动回退。

采用临时版本后，下一次普通 restart、重启机器或部署仍使用声明版本。
部署后首次带 tag 的 restart 会加载新定义，tag 同样生效。
正式采用时更新声明 image。版本切换前停服务，将整个
`/data/openclaw/` 做一致性备份到受保护的
`/core-data/backups/openclaw/`，并保留对应镜像和密文配置。
本变更不新增自动备份任务；首次初始化后应建立备份，并在积累重要
会话数据前完成恢复检查。

OpenClaw 可能迁移数据库，切回旧镜像不能保证数据兼容。必要时同时恢复
home 和 workspace。备份含私聊历史及可能的认证状态，不能
挂给 agent 或当作公开日志。SOPS 源文件独立备份，不备份 /run 的明文。
