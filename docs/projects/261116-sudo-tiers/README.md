# sudo-tiers

## 目标

主机上的 root 操作按风险分级：低风险的免口令，中等的用本地因素确认，高风险的
要在手机上签名审批。人自己敲的 sudo 和 agent 经特权执行器请求的 root 操作用
同一套分级和同一个审批通道。

## 背景

- 现在的 sudoers 只有 Guix 默认的 `%sudoers-specification`（`wheel` 组任何命令都要
  口令）加 guix-deploy 账号的白名单（`src/guix/uraj/system/base.scm` 的
  `%deploy-sudoers`）。`sudo herd status` 和 System 部署要的是同一个口令，没有分级。
- [contained-agent-v2](../261115-contained-agent-v2/README.md) 里需要 root 的操作
  （部署、`sudo` 一类）交给特权执行器，要人在手机上批准；盒子级的请求（拷主机目录
  进盒子等）也要一个盒子外面的审批通道。两件事一起讨论，审批通道在这里定，v2 引用。
- 11/16 讨论的前提：
  - 只靠 Paseo 的权限框不够安全：主机 daemon 没设密码时回环上的连接都是 owner，
    v1 容器和主机共享网络，能代答；盒子里也能伪造长得一样的卡片。
  - 统一机制的方向是“批准就是对请求内容 hash 的签名”，通道本身不可信也行。
  - 不自建 server；可以借公开服务和现成 app。不用飞书，Slack 可以。Slack 和 Paseo
    在人的手机上通知都偶尔不到。
  - agent 的请求经 Paseo 推送通知是合理的。

## 待定

- 分级怎么划？草案：
  - 只读：`herd status`、`journalctl`、`swanctl --list-sas` 等。免口令。
  - 服务启停：`herd start/stop/restart <服务>`。本地因素。
  - 改系统：System 部署、任意 shell、改 `/etc`。手机签名。
  - 要逐条列现在实际用到的 sudo 命令（各 guide 里有一批），再定每条归哪级。
    注意白名单命令能不能间接执行任意代码（参考 `%deploy-sudoers` 的注释）。
- ~~本地因素用什么？~~ 11/16 定：不用口令、电脑上的指纹（采集不了）和硬件 key
  （怕丢）。只剩两种：免口令，或者手机签名（手机上按指纹）。草案的中间一级要么
  并入免口令，要么并入手机签名；可以配合“一次批准管一段时间”减少打扰。免口令的
  范围要想清楚谁能借用：主机上以人的身份跑的任何进程（包括不在容器里的程序）
  都能调。
- 手机审批通道，不自建 server 的候选：
  1. **passkey + 静态页 + ntfy**：GitHub Pages 上放一个静态页，请求内容放在 URL
     fragment 里；页面显示内容、算 hash，用手机 passkey（WebAuthn，`rpId` 是
     `<user>.github.io`）对 hash 签名，再把签名 POST 到 ntfy.sh 的一个 topic；
     主机订阅 topic，用登记过的公钥验签并核对 origin 和 hash。通知用 ntfy app
     （带“打开链接”按钮），也可以经 Paseo 或 Slack 发同一个链接。好处：签名在
     手机安全芯片里，ntfy、GitHub、通知通道都不需要可信；页面显示什么就签什么。
     代价：要写静态页和验签（有现成库）；ntfy.sh 能看到消息，请求内容要加密或只放
     摘要；页面代码被改就能骗签，页面仓库的写权限要和 agent 隔开。
  2. **Duo**（`pam_duo`）：现成的 PAM 模块和 app，push 可带命令信息，批准由手机上的
     设备密钥签名。免费档用户数有限（待查证）；第三方云服务；Guix 没有包，要自己打。
     只管 PAM，agent 请求要另接。
  3. **Slack Socket Mode bot**：bot 主动连 Slack，不需要公网端点；卡片按钮，Slack
     核实点按钮的用户。信任的是 Slack 账号本身；通知偶尔不到；不是签名。
  4. Telegram bot（长轮询）：和 Slack 类似，在国内要代理。
  5. Pushover 紧急通知的回执：只有“确认”没有“拒绝”，不够用。
  - 静态页的部署（11/16 讨论）：WebAuthn 要求 https 页面和域名，`file:`、`data:`
    都不行，所以页面必须托管，但只部署一次：页面是一个不需要构建的 HTML 加 JS，
    放在本仓库里，由 GitHub Actions 只从 `main` 发布到 Pages，push 后一两分钟生效，
    之后很少改。`main` 只有人能合并，agent 改页面要走 PR，正好满足“页面写权限和
    agent 隔开”，不需要单独的仓库。
  - 页面是通用的，不带任何请求：请求内容（命令、脚本、cwd、有效期、请求 id）
    在 URL 的 `#` 后面，浏览器不会把它发给 GitHub。页面解码、显示、自己算 hash
    再签名，主机只执行 hash 对得上的快照。sudo 脚本也照此审：几 KB 的脚本压缩后
    放进 fragment（ntfy 单条消息上限 4096 字节，待查证）；更长的照 v2 已定的做法
    另开 PR，fragment 只放 PR 链接和文件 hash，页面去取内容并核对 hash，内容来源
    不需要可信。内容要对 ntfy.sh 保密，就用存在手机页面本地的密钥加密 fragment。
  - 建议：先做 1，在 lappie 上试一个最小原型（注册 passkey、签一次、主机验签）。
    通知送达不稳的问题和通道解耦：同一个链接可以经多个通道发，任一个到了就行。
- 特权执行器的形态：sudo 的 PAM 模块（人在终端敲 sudo 时触发手机审批）和独立的
  请求队列（agent 提交请求、人批准后主机执行快照）是不是同一个程序？
- 审批的有效期、一次批准能不能覆盖一段时间内的同类命令（例如 10 分钟内的
  `herd restart`）。

## 文档

- [TODO](TODO.md)：进度。
- [step-1-handoff](step-1-handoff.md)：第 1 步的交接。
