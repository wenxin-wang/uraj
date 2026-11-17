# 第 1 步交接：讨论设计（2026-11-17）

先读：

1. [README](README.md)
2. [TODO](TODO.md)
3. [contained-agent-v2 README](../261115-contained-agent-v2/README.md) 里
   “agent 创建 workspace 的流程细节”“agent 的 GitHub 身份”和特权执行器相关的条目。

## 现在在哪

| 环节 | 状态 | 代码 |
|---|---|---|
| 分级 | 定了两级，命令没盘点 | `src/guix/uraj/system/base.scm`（现有 sudoers） |
| 审批通道 | 原型在手机上通过（第 3 步，审批通道原型） | `exp/sudo-tiers-approval_20261116/`；`wenxin-wang/arbiter` |
| 回退、旁路、特权执行器 | 只有建议 | |

## 下一步

1. 和人讨论 README 的待定项：回退到口令的 PAM 做法（等签名的同时读终端输入）、
   `guix-deploy` 旁路要不要收紧、特权执行器和 PAM 模块是不是一个程序。
2. 第 2 步（盘点 sudo 用法）guide 部分已写：
   [sudo-inventory-review](sudo-inventory-review-20261117.md)。等人补 shell 历史、定文末
   待定项。

## 原型怎么跑

在 lappie 的主机终端（不是容器里）：

```sh
cd exp/sudo-tiers-approval_20261116
# 登记 passkey：手机打开打印的链接，创建 passkey，指纹一致再输入 y。
# 公钥存到 ~/.config/sudo-tiers/keys.json（公钥不是秘密）。
guix shell python python-cryptography -- python3 approve.py register

# 发请求。没有管理员卡时用 lappie 的 age identity（要 sudo）：
topic=$(sudo env SOPS_AGE_KEY_FILE=/var/lib/sops/age/keys.txt \
  SOPS_GPG_EXEC=/run/current-system/profile/bin/false \
  sops decrypt --extract '["sudo-tiers"]["ntfy-topic"]' \
  ../../secrets/shared/sudo-tiers.yaml)
guix shell python python-cryptography -- \
  python3 approve.py request --notify "$topic" --exec -- id
```

批准后终端打印 `Approved.` 并执行 `id`；拒绝打印 `Rejected.`、退出码 1。回复 topic
每次随机生成，写在被签名的请求里。

换通知 topic：在主机终端生成新名字（不进对话和明文仓库），
`echo arbiter-$(head -c 15 /dev/urandom | base32 | tr -d = | tr A-Z a-z)`，用
`sops secrets/shared/sudo-tiers.yaml` 改 `sudo-tiers.ntfy-topic`，手机 ntfy app 订阅
新名字并打开 instant delivery。

## 已知的坑

- 页面一开始没传 `allowCredentials`，手机 Firefox 报“没有发现任何通行密钥”；现在
  请求里带登记过的 credential id。
- ntfy 默认优先级的消息只进通知栏、不弹出；请求用优先级 4。
- 11/17 人的手机上，ntfy 在后台收不到消息：杀掉 app 后 instant delivery 的常驻通知
  消失、不再重连，打开 app 才补收；已关电池限制、给全通知权限，重启手机后仍不弹。
  疑似 ROM 杀后台，和人说的 Slack、Paseo 通知偶尔不到可能同因。暂时搁置，终端打印的
  链接手动打开作为兜底。
- 不对主机执行部署；改 sudoers 和 PAM 的验证要人在主机上做，改坏了可能锁住 sudo，
  验证时保留一个已开的 root shell。
