# storie 的 Immich

主体是 `(uraj services immich)`，由 `storie.scm` 引用。安装系统启动
Docker、containerd 和 Immich；live ISO 不启动这些服务。
Engine 来自 Guix，CLI 使用 shikanox 的 `docker-full`（包含 Compose 5.4）。
通过 `(uraj packages docker)` 将 Compose 和 Buildx 的 `GOAMD64` 改为
`v1`：shikanox 默认的 `v3` 需要 AVX/AVX2，storie 的 J6412 不支持，
会造成插件启动失败并出现误导性的 `unknown flag: --project-name`。
首次构建可能需要编译该 channel 的 Go 依赖；这不是上游二进制打包。

### 存储和启动

- `/data/immich/postgres`：NVMe Btrfs `@data` 上的 PostgreSQL。
- `/data/immich/model-cache`：模型下载缓存。
- `/core-data/archive/immich`：映射到 Immich 的 `/data`，由应用组织
  upload/library/thumbs/encoded-video/profile/backups，不需预建用户目录。
- `secrets/hosts/storie/immich.yaml`：SOPS 加密的数据库密码；启动时解密到
  `/run/secrets/immich/db-password`，root 0400，不写入 Guix store。
- `/etc/immich/compose.json`：Guix 生成的 Compose 文件（JSON 是合法 YAML）。
- `/etc/immich/compose`：指向本代配置和客户端的操作命令。

`immich` 等待 `dockerd`、`zfs-data-ready`、`file-system-/data` 和 `sops-secrets`。
每次启动还会检查真实的 Btrfs/ZFS 挂载和父网卡，之后才创建数据目录。
不能把缺失数据盘时根文件系统上的同名空目录当作图库。
容器使用 `on-failure`，崩溃时重启，daemon 开机时不自行恢复容器，
启动顺序由 Shepherd 负责。每次服务启动重建整组容器，保证共享网络
命名空间和密码文件挂载一致；数据 bind mounts 保留。

```sh
sudo herd status immich
sudo /etc/immich/compose ps
sudo /etc/immich/compose logs --tail 100
sudo herd stop immich
sudo herd start immich
```

若启动时网络还不能拉取镜像，或数据池缺失，启动会失败并停止已启动的
容器。修复后 `herd start zfs-data-ready`（如需要），再 `herd start immich`。
不要用手工 `compose up` 绕过挂载/密钥检查。`herd status immich` 表示
启动动作成功，不是持续的健康监控；用 `compose ps` 查看容器健康状态。

### 网络

macvlan bridge 模式使用 `enp1s0`，子网 `172.31.0.0/24`，网关
`172.31.0.1`，唯一分配地址 `172.31.0.6`。部署前确保 .6 无占用且
排除在 DHCP 动态地址池之外；交换机端口需要允许多个 MAC。
内网从 `http://172.31.0.6:2283` 访问，第一位注册者成为管理员。
这里没有配置 HTTPS 或反向代理。

一个固定 digest 的 pause 容器持有网络命名空间，其余四个容器通过
`network_mode: service:network` 加入。只有 Immich Web 对外监听；
PostgreSQL、Valkey、ML 均监听共享命名空间内的 127.0.0.1。
anchor 的 hosts 文件把默认 ML 主机名解析到回环地址，避免使用
`IMMICH_CONFIG_FILE` 而锁住网页管理设置。未添加普通 Docker bridge。

此 Docker daemon 禁用默认 bridge、iptables/ip6tables、IP forwarding
管理和 userland proxy。storie 的 `static-agent` / `br-static-agent` 是显式创建的独立
bridge，转发、NAT 和防火墙由 Guix 的 `restricted-network` 服务管理，
见 [受限网络说明](../restricted-network/networks-guide.md)。其他 Compose 项目不能依赖默认 bridge/NAT 自动配置。
此配置不清理历史防火墙规则。
macvlan 数据流不受主机普通 input/forward 防火墙保护，需要访问隔离时
应在路由器/VLAN 或容器网络命名空间设计规则。storie 本机无法直接访问
该 macvlan 地址，这是预期行为；容器之间仍可通过共享回环接口通信。

与官方 Compose 的区别是网络共享、回环绑定、secret 文件和重启策略；
版本固定在 v3.2.4。升级时同时审阅官方 release Compose 和镜像变更，
修改 Guix 配置后重启服务。Guix 系统回滚不会回滚数据库迁移或照片数据。

### 密钥与备份边界

服务只把密码文件路径写入 store，启动时复制到 root 0700 的
`/run/immich` 目录，再只读挂载给数据库和 Immich。运行时副本对容器
用户可读，主机普通用户无法穿过父目录。已有数据库而密码文件缺失时
拒绝生成新密码。不要删除密码文件，也不要把改文件等同于数据库改密。

storie 已通过 `host-sops-services` 声明数据库 secret，并配置：

```scheme
(immich-configuration
 (database-password-file "/run/secrets/immich/db-password")
 (secret-requirements '(sops-secrets)))
```

实际路径由 `sops-secret->secret-file` 推导，和解密服务保持一致。
如果数据库已经初始化，需要使用现有密码，或同步更新 PostgreSQL role；
重启本身不会改密。
管理员密码由首次注册设置；SMTP/OAuth 等可选功能启用后才有额外密钥。
recipients 沿用仓库 `.sops.yaml`；目标私钥由现有 host-sops 服务管理。

Immich 自带数据库导出仍按应用默认值运行，输出到媒体目录的 backups。
原有 ZFS 定时器使用 `--default-exclude`：只有显式设置
`com.sun:auto-snapshot=true` 的数据集才会被快照。保留策略为每小时
72 份、每天 31 份。
移动硬盘、冷存储以及恢复演练留待另行设计。

不要把整个 archive 扫描为外部图库。已有照片可另选具体目录只读挂载，
避免把 Immich 自己的媒体目录再次作为 External Library 导入。
