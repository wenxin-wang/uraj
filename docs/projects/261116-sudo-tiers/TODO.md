# sudo-tiers 进度

当前：第 1 步和第 3 步并行。第 3 步的原型写好了，等人建 `arbiter` 仓库、配域名并在
手机上试。

1. 讨论设计：分级、本地因素、手机审批通道。进行中，见
   [step-1-handoff](step-1-handoff.md)。
2. 盘点 sudo 用法：列出各 guide 和日常用到的 sudo 命令，按分级归类。
3. 审批通道原型：passkey + Pages 静态页 + ntfy.sh，在 lappie 上试登记、签名、验签。
   进行中。已有：`exp/sudo-tiers-approval_20261116/` 的主机脚本 `approve.py` 和离线
   验签自测 `selftest.py`（6 例通过）；静态页 `index.html` 放单独的 `arbiter` 仓库，
   还没建。
   经真的 ntfy.sh 用软件密钥模拟手机，批准、验签、执行走通；最短请求的链接 364 字节。
   没测：页面在手机浏览器里跑（WebAuthn、`DecompressionStream`）。
4. 分级落地：sudoers 和 PAM 配置进主机配置。
5. 和 contained-agent-v2 的特权执行器接上。
