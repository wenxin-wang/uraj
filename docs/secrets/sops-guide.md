# SOPS secrets

仓库根目录的 `.sops.yaml` 定义收件人；`keys/admin.asc` 只包含公钥。
lappie、hypie、storie 的系统配置都使用 sops-guix（`host-sops-services`），
从各自的 Ed25519 SSH host key 派生 age identity；各机器的密文在
`hosts/<主机>/`。

管理员主钥指纹：`8684C377E0C1D6B0EBAD9025619576F03756BFE4`。
以下三把加密子钥均为全局 recipient，任意一把即可解密：

- `26A5DFBA3B06CF2A99D33CAC103496B20BF0307F`
- `87503C3C845B0F82DBA771F3ED48AC445C42128D`
- `7F26222A047E9F5EDFA496D00273036A1927C05B`

配置中指纹末尾的 `!` 用于强制指定子钥，不能省略。签名和认证子钥
不作为 SOPS recipient。登记多个子钥不会把私钥复制到当前卡上。

## 布局与权限

OpenClaw 使用 `hosts/storie/openclaw.yaml`，同一份密文内
分别保存飞书 App Secret、new-api token 和 Gateway token。服务启用后
才声明这三个 secret，运行时各自解密；创建流程及挂载权限见
[OpenClaw 部署说明](../openclaw/deploy-guide.md)。新建密文只需收件人公钥，
编辑已有密文才需要可用的解密私钥。

OpenClaw 身份标识另存于 `hosts/storie/openclaw-identities.yaml`：
`openclaw.feishu-app-id` 是飞书 App ID，`openclaw.command-owners` 是
管理员渠道 ID 的 JSON 数组字符串。它们不是登录凭据，但与个人或应用
有关，因此不在公开配置中明文保存。运行时解密并注入 Gateway 配置，
不进入 Guix store。群 ID 留在受保护的运行状态中动态管理。
无需解密原有凭据文件就能用公钥重建这份身份文件；重建时必须包含所有
需要保留的管理员。不要重建或覆盖未知明文的 App Secret/token 密文。

- `hosts/<主机>/*.yaml`：管理员，以及该主机的 age key；lappie、hypie、storie
  各有一条规则（`hosts/hypie/` 有 Paseo 和 strongSwan 的密文）。
- `shared/*.yaml`：目前仅管理员；共享时为具体文件添加参与机器的规则。
- `shared/github.yaml`：管理员，以及 lappie、storie、hypie 的 age key；见下文。
- `keys/hosts/<主机>.age.pub`：记录机器的 age 公钥，目前有 lappie 和 hypie；
  storie 的公钥只在 `.sops.yaml` 里。SOPS 不会自动读取这些文件，授权以
  `.sops.yaml` 为准。

SOPS 权限边界是文件：能解密某个文件，就能读取其中全部内容。
不同机器的专属 secrets 必须分文件。新增主机必须显式添加路径规则；
没有匹配规则的路径不会默认获得任何 recipient。

## 编辑与验证

在仓库根目录操作。SOPS 已在 `manifest.scm` 中声明，进入
项目的 direnv / Guix shell 环境后使用 `sops`。

```sh
gpg --import secrets/keys/admin.asc
gpg --card-status
sops secrets/hosts/lappie/system.yaml
```

编辑器退出后 SOPS 保存密文。不要把私钥或明文文件提交到仓库。
`hosts/lappie/check.yaml` 是无敏感信息的加解密检查文件，未被系统服务引用：

```sh
sops decrypt --extract '["check"]' secrets/hosts/lappie/check.yaml
```

预期输出 `uraj-sops-card-check-v1`。该文件可以有多个 recipient，解密成功
只证明至少一个可用；要分别验证子钥，需要每次仅以一个 recipient
创建测试密文，并在对应卡或私钥环境中解密。

## 接入机器

lappie、hypie、storie 都使用 `(uraj system secrets)` 的 `host-sops-services`。
OpenSSH 在系统激活时生成缺失的 host keys；Shepherd 随后启动
`sops-secrets-host-key`，从 `/etc/ssh/ssh_host_ed25519_key` 派生 age
identity，保存到 `/var/lib/sops/age/keys.txt`。目录归 root 所有、权限
0700，sops-guix 将私钥文件设为 0400。同一 SSH key 重复派生不会重复
追加 identity。构建过程不读取目标私钥，Live ISO 不启用这些服务。

按 [deploy-guide 的命令速查](../guix/deploy-guide.md#命令速查)部署该主机的
System 配置，然后在目标机器上运行：

```sh
sudo herd start sops-secrets-host-key
sudo test -s /var/lib/sops/age/keys.txt
```

派生也会在启动时自动运行。手动 start 可确保 reconfigure 后立即完成。
如果文件没有生成，检查 `/etc/ssh/ssh_host_ed25519_key` 是否存在及
Shepherd 日志；不要只凭 one-shot 服务状态判断成功，上游在源 key 缺失
时可能仅记录消息。

读取当前 SSH host key 对应的 age 公钥不需要读取私钥或使用 sudo：

```sh
ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub
```

核对本机派生文件包含同一公钥（下面只输出公钥）：

```sh
sudo age-keygen -y /var/lib/sops/age/keys.txt
```

只把公钥登记到 `keys/hosts/<主机>.age.pub`，并在 `.sops.yaml` 中接入；
保留 `pgp: *admin`，两者任意一个即可解密。

```sh
mkdir -p secrets/keys/hosts
ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub > secrets/keys/hosts/<主机>.age.pub
```

### 将公钥接入 .sops.yaml

添加 `.age.pub` 文件只是记录公钥，尚未授予机器解密权限。需要完成
“配置 recipient → 更新已有密文 → 用机器私钥验证”这三个步骤。

第一步：把公钥写成 `.sops.yaml` `keys` 里的锚点，并在该主机的规则里引用。
以 hypie 为例：

```yaml
keys:
  - &hypie-age >-
      age1…（该主机 .age.pub 的完整一行）
creation_rules:
  - path_regex: ^secrets/hosts/hypie/[^/]+\.yaml$
    pgp: *admin
    age: *hypie-age
```

这是在已有的 `keys` 和 `creation_rules` 里增加条目，不要另外添加
`creation_rules`，也不要覆盖已有的管理员 `keys` 定义和其他主机的规则。
`age` 与 `pgp` 同级；保留 `pgp: *admin` 后，任意一把管理员加密子钥或
该机器的 age identity 都可以解密这些文件。锚点里填写公钥本身，不能填写
`.age.pub` 的文件路径。SOPS 使用首条匹配的 creation rule，规则之间不会
自动合并。

第二步：更新已有密文。修改规则只影响之后创建的文件，不会自动给
现有文件添加 recipient。在仓库根目录插入管理员卡，以普通用户对该主机目录下
每个已有文件执行：

```sh
sops updatekeys secrets/hosts/<主机>/<文件>.yaml
```

确认预览中只新增预期的 age recipient，三把管理员 PGP recipients
仍被保留，再确认更新。首次添加机器 recipient 时必须用已有的管理员
私钥解开数据密钥；刚加入的机器 key 尚不能解开旧密文。
无需为尚不存在的文件执行该命令。

检查改动：

```sh
git diff -- .sops.yaml secrets/hosts/<主机>
```

密文的 `sops.age` 元数据应出现上述公钥，`sops.pgp` 仍包含三把管理员
子钥。私钥不会写入密文或 `.sops.yaml`。`updatekeys` 更新数据密钥的
recipient 包装，不修改业务明文。

共享文件为每个用途单独创建规则，放在 shared fallback 之前，明确列出
获准机器（例如 `shared/github.yaml` 的 `age: [*lappie-age, *storie-age,
*hypie-age]`）；不会把所有机器的公钥加入每一个文件。

第三步：在该机器上使用机器 identity 验证。下面禁用外部 GPG 调用，
避免正常的管理员卡解密路径；`<键>` 取该文件中的任一键，lappie 的
`check.yaml` 是专门的检查文件（键 `check`，预期输出 `uraj-sops-card-check-v1`）：

```sh
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt \
  SOPS_GPG_EXEC=/run/current-system/profile/bin/false \
  sops decrypt --extract '["<键>"]' secrets/hosts/<主机>/<文件>.yaml
```

如果无法解密，先核对
`sudo age-keygen -y /var/lib/sops/age/keys.txt` 的公钥是否与密文的
`sops.age` recipient 一致，并确认已执行 `updatekeys`。
单纯修改 recipient 不需要再次 reconfigure；只有新增或修改系统的
`sops-secret` 声明时才需要部署新的系统配置。

### 声明业务 secrets 与换钥匙

以后把 `sops-secret` 列表传给 `host-sops-services`，由 sops-guix 在
启动时解密到 `/run/secrets/`。消费服务应声明解密依赖以及适当的
`owner`、`group` 和 `mode`。
私钥和明文均不得通过 `local-file` 等方式进入 Guix store。

SSH host key 不变时，age identity 丢失可以重新派生。更换 SSH host key
后公钥也改变，sops-guix 会将新 identity 追加到已有文件，并保留旧的
identity；仍需由管理员更新公钥登记和密文 recipients。SSH host 私钥
因此也能解密分配给这台机器的 secrets。
移除泄露的 recipient 不会撤销其对旧 Git 历史密文的解密能力；若涉及泄露，
还需要更换相关业务凭据并轮换 SOPS 数据密钥。
