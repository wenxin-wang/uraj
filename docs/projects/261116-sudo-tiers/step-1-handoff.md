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
| 审批通道 | 定为 passkey + 静态页 + ntfy；原型写完，页面没在手机上跑过 | `exp/sudo-tiers-approval_20261116/`；页面在 `arbiter` 仓库（未建） |

## 下一步

人在手机上试原型：

1. 建公开仓库 `arbiter`，放入静态页 `index.html`（PR #109 里从 uraj 删掉的那份，
   agent 可以代建）。Settings → Pages 选 “Deploy from a branch”，`main`、`/`。
   账号 Settings → Pages 验证 `arbiter.wenxinwang.me`（按提示加 TXT 记录）；DNS 加
   CNAME `arbiter.wenxinwang.me` → `wenxin-wang.github.io`；仓库 Pages 填同一个
   Custom domain，证书签下来后勾 “Enforce HTTPS”。
2. 手机装 ntfy app，订阅一个自己起的通知 topic（下面的 `N`）；回复 topic 用另一个
   （`R`）。topic 名不进仓库。
3. 主机上登记 passkey，按提示在手机上打开链接、创建 passkey，核对指纹后输入 `y`：

   ```sh
   cd exp/sudo-tiers-approval_20261116
   guix shell python python-cryptography -- python3 approve.py register \
     --page https://arbiter.wenxinwang.me/ --reply R \
     --keys ~/.config/sudo-tiers/keys.json
   ```

4. 发一个请求，手机收到通知后点开批准，终端打印 `Approved.` 后执行 `id`：

   ```sh
   guix shell python python-cryptography -- python3 approve.py request \
     --page https://arbiter.wenxinwang.me/ --notify N --reply R \
     --keys ~/.config/sudo-tiers/keys.json --exec -- id
   ```

然后继续讨论 README 的待定项：回退到口令的 PAM 做法、`guix-deploy` 旁路。

## 已知的坑

- 不对主机执行部署；改 sudoers 和 PAM 的验证要人在主机上做，改坏了可能锁住 sudo，
  验证时保留一个已开的 root shell。
