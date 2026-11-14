# 第 4 步：手册瘦身、过时内容和历史项目

迁移后的手册（`*-guide.md`）里混着大量过程：带日期的排查和验证、“先试 X 再改 Y”、
一次性的迁移步骤、某个版本的观察、被取代的设计。第 4 步把手册压到只写 `main`
上的现状，过程按当时的项目归档，同时修掉过时内容。

调研由每个模块一个便宜模型的 agent 做，逐条对照代码和 git 历史；本 session
抽查了影响大的结论（storie 经 `host0` 能连 relay、broker 根目录含 `~/spaces`、
`codex-desktop` 10/10 起不在 Home 里、hypie 开机连 fwd2home、`.sops.yaml` 用锚点），
都成立。

## 规则

- 手册只留用法、限制和必要的理由。过程段落三选一：删掉（git 历史里有）；
  压成一句现状；整段搬进历史项目。
- 历史项目放 `docs/archive/projects/<yymmdd>-<project>/`，日期取第一个相关提交。
  只写 `README.md`（目标、背景、主要决定和日期）和 `TODO.md`（按步列出做了什么、
  PR 号、结论），不写交接。从手册搬出的段落原文不改，存成项目里带日期的过程文档。
- 已完成项目的带日期文档（`docs/archive/<module>/` 下的，以及 `docs/<module>/`
  下描述实现前状态的）移进对应的历史项目；`docs/archive/<module>/` 清空。
  `docs/<module>/` 只剩手册和仍有参考价值、不属于某个项目的过程文档。
- 模块索引 `docs/<module>.md` 末尾加一节“历史项目”，一行一个链接。
- 改写手册时不翻译，保持原语言；新写的 README、TODO 用中文。
- 只改文档和指向文档的注释，不改代码行为。

## 历史项目

| 模块 | 项目 | 包含 |
|---|---|---|
| guix | `260921-storie-server` | storie 上线、Immich、首次 `guix deploy` |
| guix | `261003-strongswan-vpn` | fwd2home、开机连接 |
| guix | `261007-hypie-onboard` | ZFS、NVIDIA、部署 |
| guix | `261021-nfs-lan-shares` | NFS 服务和客户端自动挂载、NFS 检查记录 |
| secrets | `261001-sops-secrets` | SOPS 布局、三台机器接入、agent 的秘密 |
| contained-agent | `261008-contained-agent` | 容器、项目配置和策略、项目 SSH agent、open items |
| contained-agent | `261017-contained-podman` | Podman 运行时、Harbor 实测 |
| contained-agent | `261028-agent-browser` | contained-agent 和 OpenClaw 两边的浏览器、GPU、dashboard |
| desktop | `261009-ssh-keyring` | GNOME Keyring 存 SSH 口令 |
| paseo | `261004-paseo-daemon-container` | daemon 进容器、relay、storie 切换、附件 |
| paseo | `261008-paseo-broker` | broker 首版、执行层、host cgroup、OpenCode |
| openclaw | `261020-openclaw-feishu-bot` | 上线、prompt cache、图像生成设计 |
| openclaw | `261024-openclaw-podman-sandbox` | engine 容器、UID 迁移 |
| openclaw | `261027-openclaw-personas` | 家庭成员 persona、话题、进度卡片 |
| maa | `261010-redroid-maa` | hypie 上的 redroid、ARM 转译、每日任务、storie 备用 |
| restricted-network | `261015-restricted-network` | 共享 nft 服务、旧表迁移、验证 |

太小的不单开（branch GC、Paseo 升级、new-api、日志和镜像、Home-only 部署、
codex-desktop 打包、非 Guix 桌面 playbook），手册里的过程直接删或压成一句。

## 主要的过时内容

完整清单在各模块 PR 里；影响大的：

- storie 的 daemon 经 `host0` 能连 macvlan 上的 relay，`daemon-guide`、`relay-guide`
  还说连不上。
- broker 的默认根目录漏了 `~/spaces`；共享 SSH 服务按 worktree 顶层分 agent，
  `broker-guide` 写成归到主仓库。
- `sops-guide` 只讲 lappie，没有 hypie、锚点写法；`strongswan-guide` 说不开机连接；
  `immich-guide` 说在 storie 上构建，和 `build-locally? #t` 矛盾。
- OpenClaw 的“部署声明、主机未运行”早已过时；镜像 tag 和 ID、断言计数是旧值。
- `restricted-network` 网络表缺 `sandboxed-agents`、redroid 网络，hypie 部署块已启用。
- `codex-desktop` 不再装进 Home；MAA 文档引用从未提交的 `scripts/redroid/` 脚本。
- 部署命令七种写法，统一链到 `guix/deploy-guide.md` 新加的“命令速查”，并补 hypie。
- 公开仓库里不该出现的私人名字（`foreign-desktop-guide` 等处）删掉。

## PR 划分

一个模块一个 PR（guix 和 secrets 合一个，maa 和 restricted-network、new-api 合一个），
先做 paseo 作为试用批次，人看过再放其余模块。每个 PR 三类提交分开：
建历史项目并搬段落、压手册、修过时内容。
