# 把 lappie 的公钥接入 .sops.yaml

添加 `.age.pub` 文件只是记录公钥，尚未授予机器解密权限。需要完成
“配置 recipient → 更新已有密文 → 用机器私钥验证”这三个步骤。

第一步：读取 `secrets/keys/hosts/lappie.age.pub` 的完整一行，填入仓库
根目录 `.sops.yaml` 的 lappie 规则。按目前登记的公钥，该条规则应为：

```yaml
creation_rules:
  - path_regex: ^secrets/hosts/lappie/[^/]+\.yaml$
    pgp: *admin
    age: age14xfjfwayact80jcp84ck2kj8ue469kwfsn9ngyxkt6curgm324fsnqcswt
```

这是现有 `creation_rules` 内 lappie 条目的修改示例，不要另外添加一个
`creation_rules`，也不要覆盖已有的管理员 `keys` 定义或 storie/shared
规则。`age` 与 `pgp` 同级；保留 `pgp: *admin` 后，任意一把管理员
加密子钥或 lappie 的 age identity 都可以解密这些文件。
这里填写公钥本身，不能填写 `.age.pub` 的文件路径。

storie 接入时，在本机导出 `storie.age.pub`，再将其公钥只填入 storie
规则。SOPS 使用首条匹配的 creation rule，规则之间不会自动合并。

第二步：更新已有密文。修改规则只影响之后创建的文件，不会自动给
现有文件添加 recipient。在仓库根目录插入管理员卡，以普通用户执行：

```sh
sops updatekeys secrets/hosts/lappie/check.yaml
```

确认预览中只新增预期的 lappie age recipient，三把管理员 PGP recipients
仍被保留，再确认更新。首次添加机器 recipient 时必须用已有的管理员
私钥解开数据密钥；刚加入的机器 key 尚不能解开旧密文。
如果以后已有 `system.yaml` 等其他文件，也要逐个执行 `sops updatekeys`。
无需为尚不存在的文件执行该命令。

检查改动：

```sh
git diff -- .sops.yaml secrets/hosts/lappie/check.yaml
```

密文的 `sops.age` 元数据应出现上述公钥，`sops.pgp` 仍包含三把管理员
子钥。私钥不会写入密文或 `.sops.yaml`。`updatekeys` 更新数据密钥的
recipient 包装，不修改业务明文。

共享文件为每个用途单独创建规则，放在 shared fallback 之前，明确列出
获准机器；不会把所有机器的公钥加入每一个文件。

第三步：在 lappie 上使用机器 identity 验证。下面禁用外部 GPG 调用，
避免正常的管理员卡解密路径：

```sh
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt \
  SOPS_GPG_EXEC=/run/current-system/profile/bin/false \
  sops decrypt --extract '["check"]' secrets/hosts/lappie/check.yaml
```

预期输出 `uraj-sops-card-check-v1`。如果无法解密，先核对
`sudo age-keygen -y /var/lib/sops/age/keys.txt` 的公钥是否与密文的
`sops.age` recipient 一致，并确认已执行 `updatekeys`。
单纯修改 recipient 不需要再次 reconfigure；只有新增或修改系统的
`sops-secret` 声明时才需要部署新的系统配置。
