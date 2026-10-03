# 按需启动 strongSwan

lappie 已声明 `fwd2home`。charon 和各 VPN 的 Shepherd 服务默认关闭，
Live ISO 不包含这些服务。启动某个连接会按依赖启动 charon；关闭它不会
断开其他连接。开机和加载配置不会建立连接；手动启动成功后，网络暂时
中断会自动尝试重连。手动停止后保持关闭。

## 填写密码并部署

公共配置模板是 [`env/strongswan/road-warrior-all-tunnel.conf.tmpl`](../../env/strongswan/road-warrior-all-tunnel.conf.tmpl)。
这是实际使用的配置来源，可以直接阅读和修改版本、EAP 认证方式、虚拟
地址请求、流量范围和重连策略。构建时只将 `@NAME@` 替换成公开连接名。
CA 信任和 DNS 插件配置仍由 `src/guix/uraj/services/strongswan.scm` 管理。

域名、认证身份、用户名和密码都放在
`secrets/hosts/lappie/strongswan.yaml` 的加密 `strongswan.fwd2home` 字符串中。
已迁移原草稿的域名和身份；若密码仍是 `REPLACE_WITH_PASSWORD`，启动会
拒绝连接。在仓库根目录使用管理员密钥编辑：

```sh
sops secrets/hosts/lappie/strongswan.yaml
```

私密字符串只需保留下面这些字段（占位符需替换为已有真实值）：

```yaml
strongswan:
  fwd2home: |
    connections {
      fwd2home {
        remote_addrs = "SERVER_ADDRESS"
        local {
          id = "LOCAL_ID"
          eap_id = "EAP_USERNAME"
        }
        remote {
          id = "SERVER_ID"
        }
      }
    }
    secrets {
      eap-fwd2home {
        id = "CREDENTIAL_ID"
        secret = "REPLACE_WITH_PASSWORD"
      }
    }
```

`local.id`、`local.eap_id`、凭据 `id` 是独立字段，精简时保留各自原值，
不要自动改成同一个用户名；服务器地址和证书身份也分别保留。

**兼容现有密文：** 目前未改写已有密文，它仍可包含完整配置。运行时先
include 解密文件，再 include 公共模板；同名节合并，模板中的公共字段
覆盖旧值。你可以在 SOPS 编辑器中删去密文中重复的公共字段，保留上面的
私密片段，无需同时迁移才能使用模板。配置不是把密文字符串插入模板：
swanctl 在运行时合并两份配置，敏感内容始终不参与 Guix 构建。

将 `secret` 改为真实密码。它是 swanctl 配置语法：使用双引号，并对密码
中的反斜杠和双引号进行转义。编辑器应禁用明文备份、交换文件和持久撤销。
不要在命令行参数里填写密码。SOPS recipients 沿用 `.sops.yaml` 的
lappie 规则（三把管理员 GPG 子钥和 lappie age key）。

```sh
sudo --preserve-env=GUILE_LOAD_PATH guix time-machine \
  -C env/guix/channels-lock.scm -- system reconfigure env/guix/os/lappie.scm
sudo herd start vpn-fwd2home
sudo swanctl --list-sas --uri unix:///run/strongswan-charon.vici
sudo herd stop vpn-fwd2home
```

通用用法是 `sudo herd start vpn-名字` / `sudo herd stop vpn-名字`。
`sudo herd stop strongswan-charon` 会停止所有依赖它的 VPN，再关闭守护进程。
Shepherd 的连接状态表示成功执行了手动启动；实际隧道可能随后断开，
以 `--list-sas` 为准。默认启用 MOBIKE 迁移地址，空闲 30 秒后发送 DPD
探测；DPD 超时后重新建立 IKE，网络失败会持续重试。30 秒不是重连完成
时限，探测重传也需要时间。对端主动关闭 CHILD 时也会尝试重新建立。
认证失败等永久错误仍需修正配置后手动 stop/start；这不是无限重试密码。
首次手动连接仍有 30 秒等待上限，超时清理后需重新 start。

sops-guix 在运行时解密到 `/run/secrets/strongswan/fwd2home`，root:root
0400。Guix store 只接收密文、公开名称和运行时路径。charon 不向 syslog
记录身份；手动 swanctl 输出仍可能显示域名、身份和地址。

## 多个连接

1. 用 SOPS 新建同主机下的 YAML，或在现有文件的 `strongswan` 下增加一个
   加密字符串。每个字符串按上面的私密片段提供 `connections` 和
   `secrets`；IKE 和 `eap-名字` 使用对应连接名，CHILD 由公共模板生成。
2. 在 `env/guix/os/lappie.scm` 的 `%vpn-connections` 增加
   `(cons "名字" (sops-secret ...))`，key 指向该字符串，权限保持 root:root
   0400。连接名只允许 ASCII 字母、数字、下划线、连字符，不可重复。
3. 重新部署后按名称启动。公共模板在加密 include 之后覆盖同名 IKE/CHILD
   的连接生命周期：`mobike = yes`、`dpd_delay = 30s`、`keyingtries = 0`、
   `start_action = none`、`dpd_action = restart`、`close_action = start`。
   旧密文里的 `clear`/`none` 无需解密改写；server ID 和域名仍只在密文中。

当前所有连接共用这个 IKEv2/EAP 模板。它显式定义的公共字段以模板为准，
不要在密文中尝试覆盖；需要不同认证方式或流量范围时，应先扩展公共模板
选择机制。

加载会读取全部已声明的配置，只有指定连接被 initiate；全量加载避免
`--load-conns` 删除其他连接定义。不要在加密配置里加入自动启动或 trap
策略。并行 VPN 的远端流量选择器应避免重叠；默认路由重叠不能保证分流。

## 认证、路由和 DNS

沿用原配置的 IKEv2、EAP、IPv4/IPv6 虚拟地址请求和服务端证书认证。
EAP 具体方法由服务端协商，IKE/ESP 使用 strongSwan 默认提案。
从 Guix nss-certs 加载 ISRG Root X1/X2，并保留加密配置中的服务端
身份校验；服务端需发送中间证书链。

远端选择器允许 IPv4/IPv6 全网，由服务端收窄，因此是否全隧道取决于协商。
客户端加载 `resolve` 插件，请求并通过 Guix `openresolv` 应用服务端
下发的 IPv4/IPv6 DNS。`lo.strongswan-charon` 通过 `resolvconf -x` 注册为独占
条目：存在时不把物理网络 DNS 混入系统 resolv.conf。`resolvconf -l` 仍会
列出被保存的物理网络条目，这不表示它们正在使用；以 `/etc/resolv.conf`
为准。连接断开时撤销对应 DNS，多条连接共用的 DNS 会保留到最后一个
使用者断开。
这不是按域名分流的 split DNS，多 VPN 的 DNS 仍共享系统解析器。

休眠后原 IKE 消失时，插件撤销 DNS 条目是正常清理；重新建立 IKE 并收到
DNS 后会再次注册。DNS 条目消失不应靠长期保留旧 DNS 来掩盖。若隧道
仍是 ESTABLISHED 但条目缺失，则应另查 openresolv/网络管理器更新，不能
仅归因于断线。不保留断开后的 VPN DNS，也不提供断线期间的 kill switch。

服务端使用 `pools = dhcp, v6pool` 时，DHCP 返回的 DNS 可以下发给客户端；
仅设置全网流量选择器并不保证下发 DNS。若连接后 `resolvconf -l` 没有
`lo.strongswan-charon`，检查服务端 DHCP 是否提供 DNS，或在服务端 pool/attr
配置中指定 VPN 内可达的 DNS。不要为修复客户端 DNS 改写服务端身份校验。

若正在运行旧名 `uraj-charon` 的版本，先在重新部署前执行
`sudo herd stop uraj-charon`，让旧实例释放 VICI socket 和 DNS 条目。
重新部署后使用下面的新服务名。

更新系统配置后，需重启 charon 并重新协商（会断开它管理的所有 VPN）：

```sh
sudo herd stop strongswan-charon
sudo herd start vpn-fwd2home
sudo resolvconf -l
getent ahosts example.org
sudo herd stop vpn-fwd2home
sudo resolvconf -l
```

手动编辑 `/etc/resolv.conf` 只是临时措施，openresolv 下次更新会覆盖它。
断开恢复的是网络管理器登记的 DNS，不是该文件的手工修改；必要时重连
物理网络，让网络管理器重新登记 DNS。诊断输出中的内部 DNS 地址也应
按敏感信息处理。客户端的 `remote_addrs`、`remote.id` 和用户名仍仅存于
SOPS 加密字符串及 root 可读的运行时文件，不写入公开配置或 Guix store。

真实 VPN 连接仍需在填写密码并部署后验证。

参考：[swanctl 配置](https://docs.strongswan.org/docs/latest/swanctl/swanctlConf.html)、
[加载连接](https://docs.strongswan.org/docs/latest/swanctl/swanctlLoadConns.html)、
[DNS resolve 插件](https://docs.strongswan.org/docs/latest/plugins/resolve.html)、
[DHCP 下发 DNS](https://docs.strongswan.org/docs/latest/plugins/dhcp.html)。
