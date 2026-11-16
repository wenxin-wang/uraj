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
| 审批通道 | 定为 passkey + 静态页 + ntfy；原型写完，页面没在手机上跑过 | `exp/sudo-tiers-approval_20261116/`、`.github/workflows/approval-page.yml` |

## 下一步

人在手机上试原型（PR 合并后）：

1. GitHub 仓库 Settings → Pages → Source 选 “GitHub Actions”，再在 Actions 里手动跑
   一次 `approval-page`。页面在 `https://wenxin-wang.github.io/uraj/`。
2. 手机装 ntfy app，订阅一个自己起的通知 topic（下面的 `N`）；回复 topic 用另一个
   （`R`）。topic 名不进仓库。
3. 主机上登记 passkey，按提示在手机上打开链接、创建 passkey，核对指纹后输入 `y`：

   ```sh
   cd exp/sudo-tiers-approval_20261116
   guix shell python python-cryptography -- python3 approve.py register \
     --page https://wenxin-wang.github.io/uraj/ --reply R \
     --keys ~/.config/sudo-tiers/keys.json
   ```

4. 发一个请求，手机收到通知后点开批准，终端打印 `Approved.` 后执行 `id`：

   ```sh
   guix shell python python-cryptography -- python3 approve.py request \
     --page https://wenxin-wang.github.io/uraj/ --notify N --reply R \
     --keys ~/.config/sudo-tiers/keys.json --exec -- id
   ```

然后继续讨论 README 的待定项：回退到口令的 PAM 做法、`guix-deploy` 旁路。

## 已知的坑

- 不对主机执行部署；改 sudoers 和 PAM 的验证要人在主机上做，改坏了可能锁住 sudo，
  验证时保留一个已开的 root shell。
