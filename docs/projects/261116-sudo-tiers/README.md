# sudo-tiers

## 目标

主机上的 root 操作分两级：低风险的免口令，其余的要在手机上用 passkey 签名审批。
人自己敲的 sudo 和 agent 经特权执行器请求的 root 操作用同一套分级和同一个审批通道。

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

- ~~分级怎么划？~~ 11/16 定两级，服务启停免口令：
  - 免口令：只读（`herd status`、`journalctl`、`swanctl --list-sas` 等）和服务启停
    （`herd start/stop/restart <服务>`）。
  - 手机签名：System 部署、任意 shell、改 `/etc` 等其余一切。
  - 现有命令的归类见 [sudo-inventory-review](sudo-inventory-review-20261117.md)（第 2 步，
    盘点 sudo 用法）。注意白名单命令能不能间接执行任意代码（参考
    `%deploy-sudoers` 的注释）。
- ~~本地因素用什么？~~ 11/16 定：不用口令、电脑上的指纹（采集不了）和硬件 key
  （怕丢）。只剩两种：免口令，或者手机签名（手机上按指纹）。手机签名一级可以配合
  “一次批准管一段时间”减少打扰。免口令的范围要想清楚谁能借用：主机上以人的身份
  跑的任何进程（包括不在容器里的程序）都能调。
- ~~手机审批通道用什么？~~ 11/16 定：passkey + 静态页 + ntfy.sh，原型见第 3 步
  （审批通道原型）。
  - 做法：静态页上的请求内容放在 URL fragment 里；页面显示内容、算 hash，用手机
    passkey（WebAuthn，`rpId` 是页面的域名）对 hash 签名，再把签名 POST 到 ntfy.sh
    的一个 topic；主机订阅 topic，用登记过的公钥验签并核对 origin 和 hash。通知用
    ntfy app（带“打开链接”按钮），也可以经 Paseo 或 Slack 发同一个链接。
  - 好处：签名在手机安全芯片里，ntfy、GitHub、通知通道都不需要可信；页面显示什么
    就签什么。通知送达不稳的问题和通道解耦：同一个链接可以经多个通道发，任一个到了
    就行。
  - 代价：要写静态页和验签；页面代码被改就能骗签，页面仓库的写权限要和 agent 隔开。
    11/16 定：请求内容不算敏感，明文经 ntfy.sh 可以接受，不加密。
  - 没选的候选：Duo（`pam_duo`，第三方云服务，Guix 没有包，只管 PAM）；Slack Socket
    Mode bot（信任的是 Slack 账号，不是签名，通知偶尔不到）；Telegram bot（同 Slack，
    国内要代理）；Pushover 紧急通知回执（没有“拒绝”）。
  - 页面是通用的，不带任何请求：请求内容（命令、脚本、cwd、有效期、请求 id、回复
    topic、登记过的 credential id）在 URL 的 `#` 后面，浏览器不会把它发给 GitHub。
    sudo 脚本也照此审：几 KB 的脚本压缩后放进 fragment（ntfy 单条消息上限 4096
    字节，待查证）；更长的照 v2 已定的做法另开 PR，fragment 只放 PR 链接和文件
    hash，页面去取内容并核对 hash，内容来源不需要可信。
- ~~静态页放哪？~~ 11/16 定：单开仓库 `arbiter`，自定义域名
  `arbiter.wenxinwang.me`，不放 uraj；11/17 上线。WebAuthn 要求 https 页面和域名，
  页面必须托管，但只部署一次：一个不需要构建的 HTML 加 JS，Pages 直接从 `main`
  分支发布。
  - 不用 `<user>.github.io/<仓库>`：passkey 绑定整个域名，同一账号的主站和别的
    仓库的 Pages 都在这个域名下，都能用同一个 passkey 骗签。自定义子域名单独成
    一个域名；也不绑到上一级的 `wenxinwang.me`。域名定了不再改，改了要在手机上
    重新登记。
  - 在 GitHub 账号设置里验证域名，防止被别人接管；DNS 不走 Cloudflare 代理（代理会
    解开 TLS、能改页面）。
  - 页面的安全取决于谁能推 `arbiter`：agent 不在这个仓库里跑，agent 的 GitHub
    身份不装到这个仓库（见 contained-agent-v2 的“agent 的 GitHub 身份”）。在那
    之前，agent 和人共用一个 GitHub 账号，技术上仍能推。
- ~~拒绝要不要签名？~~ 11/17 定：不要。伪造拒绝最多让一次请求失败，而能伪造的人
  （知道随机回复 topic 的 ntfy.sh）本来就能丢掉消息；拒绝要按指纹只会让人懒得拒绝。
  同理，无效或畸形的回复只忽略，继续等。
- 手机找不到时怎么回退到口令？建议分三种情况：
  - 手机在、通知没到：终端打印审批链接（以后加二维码），手机扫码或手动打开，
    签名照样经 ntfy 回来。不需要口令。
  - 手机暂时不在手边：sudo 的 PAM 栈里手机签名在前（`sufficient`），等到超时或人在
    终端按回车放弃，就落到 `pam_unix` 口令。口令只作应急，平时不输。PAM 模块等
    签名的同时读终端输入，`pam_exec` 做不到，要写一个小 PAM 模块或包装程序，待定。
  - 手机丢了：passkey 如果同步在手机账号的密码管理器里，新手机登录后就能恢复；
    另外可以登记第二个 passkey（平板或另一台手机）。在那之前用应急口令。口令要
    保证还记得，或者放在密码管理器里。
  - 特权执行器（agent 的请求）不回退到口令：手机不在就等，或者人在主机终端确认。
- `guix-deploy` 账号的旁路要不要收紧？它能免口令以 root 执行 Guix 代码（见
  `%deploy-sudoers` 注释），持有部署 SSH key 的主机可以经它部署，不经分级。
- 特权执行器的形态：sudo 的 PAM 模块（人在终端敲 sudo 时触发手机审批）和独立的
  请求队列（agent 提交请求、人批准后主机执行快照）是不是同一个程序？
  - 验签和执行要在 root 一侧，请求在等签名期间由它保存。原型的 `approve.py` 以人的
    身份跑，不是边界。
  - 执行的必须是快照：原型只签了 `argv` 和 `cwd`，`--exec` 用当前的 `PATH` 和 env，
    `argv[0]` 解析到哪个文件、`argv` 引用的脚本批准后能不能被改，都不在签名范围内；
    `--script` 只展示不执行。落地时签名要覆盖 env、解析后的绝对路径（或 store
    路径），脚本执行的就是签名里的内容。
- 审批的有效期、一次批准能不能覆盖一段时间内的同类命令（例如 10 分钟内的
  `herd restart`）。
- 手机上 ntfy 在后台收不到消息（见 [step-1-handoff](step-1-handoff.md) 的已知的坑），
  要查 ROM 的自启动设置或换推送渠道。

## 文档

- [TODO](TODO.md)：进度。
- [step-1-handoff](step-1-handoff.md)：第 1 步的交接。
- [sudo-inventory-review](sudo-inventory-review-20261117.md)：现有 sudo 命令按两级归类，
  标出能间接执行任意代码的（11/17）。
