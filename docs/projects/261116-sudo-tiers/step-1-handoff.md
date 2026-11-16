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
| 审批通道 | 列了候选，倾向 passkey + 静态页 + ntfy，待人定 | |

## 下一步

和人讨论 README 的待定项。定了通道之后做第 3 步的原型；原型放
`exp/sudo-tiers-approval_<yyyymmdd>/`。

## 已知的坑

- 不对主机执行部署；改 sudoers 和 PAM 的验证要人在主机上做，改坏了可能锁住 sudo，
  验证时保留一个已开的 root shell。
