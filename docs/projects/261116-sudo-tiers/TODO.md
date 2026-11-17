# sudo-tiers 进度

当前：第 1 步（讨论设计）。下一步要人定：回退到口令的 PAM 做法、`guix-deploy` 旁路、
特权执行器的形态，见 [README](README.md) 的待定项；第 2 步（盘点 sudo 用法）等人审。

1. 讨论设计：分级、审批通道、回退、特权执行器。进行中，见
   [step-1-handoff](step-1-handoff.md)。已定：两级；passkey + `arbiter` 静态页 +
   ntfy.sh；拒绝不签名。
2. 盘点 sudo 用法：列出各 guide 和日常用到的 sudo 命令，按两级归类。进行中：guide
   和 shell 历史都盘点了，见 [sudo-inventory-review](sudo-inventory-review-20261117.md)；
   剩 `sudo "$(command ...)"` 是什么、new-api traj 记录给哪个组读。
3. ~~审批通道原型：passkey + Pages 静态页 + ntfy.sh~~ 已完成（11/17）。结论：手机
   Firefox 上登记、批准、拒绝都通过，主机验签后执行；页面要传 `allowCredentials`；
   国内手机直连 ntfy.sh 和审批页可用，但 ntfy 在后台收不到消息，搁置。产物：
   `exp/sudo-tiers-approval_20261116/`（`approve.py`、`selftest.py`）；静态页在仓库
   `wenxin-wang/arbiter`（`https://arbiter.wenxinwang.me/`）；通知 topic 在
   `secrets/shared/sudo-tiers.yaml`；PR #109。
4. 分级落地：sudoers 和 PAM 配置进主机配置。
5. 和 contained-agent-v2 的特权执行器接上。
