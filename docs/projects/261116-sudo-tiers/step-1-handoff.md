# 第 1 步交接：讨论设计（2026-11-16）

先读：

1. [README](README.md)
2. [TODO](TODO.md)
3. [contained-agent-v2 README](../261115-contained-agent-v2/README.md) 里
   “agent 创建 workspace 的流程细节”和特权执行器相关的条目。

## 现在在哪

| 环节 | 状态 | 代码 |
|---|---|---|
| 分级 | 只有草案 | `src/guix/uraj/system/base.scm`（现有 sudoers） |
| 审批通道 | 定为 passkey + 静态页 + ntfy；`arbiter` 已上线，ntfy 通知和打开页面在手机上通过；passkey 已登记（11/17），签名没试 | `exp/sudo-tiers-approval_20261116/`；`wenxin-wang/arbiter` |

## 下一步

人在手机上试原型（国内手机直连 ntfy.sh 和审批页都通过）：

1. ~~`arbiter` 仓库和域名~~ 11/17 完成：`https://arbiter.wenxinwang.me/` 由 GitHub
   签发证书，`wenxinwang.me` 已在账号里验证，DNS 不走 Cloudflare 代理（代理会解开
   TLS、能改页面，Flexible 模式还是明文回源）。
2. 手机装 ntfy app，订阅一个随机名字的通知 topic，打开 instant delivery（不走 FCM）。
   名字在主机终端生成，不进对话和明文仓库：

   ```sh
   echo arbiter-$(head -c 15 /dev/urandom | base32 | tr -d = | tr A-Z a-z)
   ```

   存进 SOPS（在项目 Guix 环境里，要管理员卡；`.sops.yaml` 已有这个文件的规则）：

   ```sh
   sops secrets/shared/sudo-tiers.yaml
   ```

   编辑器里写：

   ```yaml
   sudo-tiers:
     ntfy-topic: arbiter-...
   ```

   回复 topic 不用起名，`approve.py` 每次随机生成，写在被签名的请求里。

3. 主机上登记 passkey，按提示在手机上打开链接、创建 passkey，核对指纹后输入 `y`。
   公钥存到 `~/.config/sudo-tiers/keys.json`（公钥不是秘密）：

   ```sh
   cd exp/sudo-tiers-approval_20261116
   guix shell python python-cryptography -- python3 approve.py register
   ```

4. 发一个请求，手机收到通知后点开批准，终端打印 `Approved.` 后执行 `id`：

   ```sh
   # 没有管理员卡时用 lappie 的 age identity（要 sudo）：
   topic=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt \
     SOPS_GPG_EXEC=/run/current-system/profile/bin/false \
     sops decrypt --extract '["sudo-tiers"]["ntfy-topic"]' \
     ../../secrets/shared/sudo-tiers.yaml)
   guix shell python python-cryptography -- \
     python3 approve.py request --notify "$topic" --exec -- id
   ```

   再试一次拒绝，终端应打印 `Rejected.`、退出码 1。

然后继续讨论 README 的待定项：回退到口令的 PAM 做法、`guix-deploy` 旁路。

## 已知的坑

- 不对主机执行部署；改 sudoers 和 PAM 的验证要人在主机上做，改坏了可能锁住 sudo，
  验证时保留一个已开的 root shell。
