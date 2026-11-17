# sudo-tiers 进度

当前：第 1 步和第 3 步并行。第 3 步的页面已上线，等人登记 passkey、试签名。

1. 讨论设计：分级、本地因素、手机审批通道。进行中，见
   [step-1-handoff](step-1-handoff.md)。
2. 盘点 sudo 用法：列出各 guide 和日常用到的 sudo 命令，按分级归类。
3. 审批通道原型：passkey + Pages 静态页 + ntfy.sh，在 lappie 上试登记、签名、验签。
   进行中。已有：`exp/sudo-tiers-approval_20261116/` 的主机脚本 `approve.py` 和离线
   验签自测 `selftest.py`（6 例通过）；静态页在单独的仓库 `wenxin-wang/arbiter`，
   11/17 上线 `https://arbiter.wenxinwang.me/`。回复 topic 每次随机生成；通知 topic
   存 SOPS `secrets/shared/sudo-tiers.yaml`。
   经真的 ntfy.sh 用软件密钥模拟手机，批准、验签、执行走通；最短请求的链接 364 字节。
   没测：页面在手机浏览器里跑（WebAuthn、`DecompressionStream`）。
4. 分级落地：sudoers 和 PAM 配置进主机配置。
5. 和 contained-agent-v2 的特权执行器接上。
