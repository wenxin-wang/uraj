# 现有文档的去向和迁移方案（2026-11-14）

基于 `origin/main` 5445dd2 的文档。布局和命名见
[layout-design-20261114.md](layout-design-20261114.md)。

## 迁移原则

1. **只搬不改。** 迁移提交只做格式转换、按节拆分和改链接，不改写内容。
   调研中发现的过时内容（见文末“发现的过时内容”）不在迁移里修，
   列为本项目后面的步骤，各自单独 PR，方便审阅时对照。
2. **按节拆分，不拆节。** 拆分的最小单位是 org 的一个标题节，整节搬走，
   节内文字不动；拆出的文件开头一行注明来源，例如
   “从 `docs/contained-agent.org` 的 Pitfalls 一节迁来（5445dd2）”。
3. **日期。** 拆出的过程文档：正文写了日期的用正文日期；没写的用该节最后一次
   实质修改的提交日期（`git log -L`）。
4. **旧文档。** 已知过时或描述已完成一次性步骤的内容，迁移后仍是只读的带日期文档，
   文件第一行加“旧文档：……现状见 [链接]”。迁移不删除任何内容；
   删除留到对应手册重写之后，由人决定。
5. **格式检查。** 没有现成工具能可靠处理 uraj 的 org 写法（`=a=/=b=` 相邻
   verbatim、跨行 verbatim、`=` 里含 `=` 或反引号、`--` 区间、`*粗体*`），
   转换用 `guix shell pandoc` 起草后逐文件人工核对表格、代码块（保留语言标注）、
   链接和锚点；核对清单见“转换时要注意的写法”。

## 去向表

“动作”取：移动（整篇转换后换位置）、拆分（按节分到几个文件）、并入（进别的文档）、
旧文档（转换后标为只读）、保留（原处不动）。路径都相对 `docs/`，`<m>` 是模块目录。

### 仓库根和代码目录里的文档

| 现有文档 | 动作 | 去向 | 理由 |
|---|---|---|---|
| `README.org` | 移动 | `/README.md` | GitHub 首页；只转格式，加一行指向 `AGENTS.md` 和 `docs/` |
| `AGENTS.md` | 重写 | `/AGENTS.md` | 按 [草稿](agents-md-design-20261114.md)；现有“Coding style”一节原样并入“提代码” |
| `secrets/README.org` | 拆分 | `secrets.md`（索引）；`secrets/sops-guide.md`（SOPS secrets 引言、布局与权限、编辑与验证、接入机器、将公钥接入 .sops.yaml、声明业务 secrets 与换钥匙）；`secrets/agent-secrets-guide.md`（contained agent 与 Paseo 的 GitHub token、私有沙箱策略、Paseo 的 per-host YAML 配置） | 不在代码/数据目录放 README；后三节是 agent 相关的秘密，单独成篇 |
| `env/guix/os/README.org` | 拆分 | `guix/logs-guide.md`（系统日志读取）；`guix/crate-mirrors-guide.md`（crates 下载镜像）；`guix/iso-substitutes-guide.md`（Live ISO 的内网 substitutes）；`guix/immich-guide.md`（storie 的 Immich 及子节）；`guix/deploy-guide.md`（用 guix deploy 远程更新及子节） | 五个互不相关的主题；不在代码目录放 README |
| `env/playbooks/README.org` | 移动 | `playbooks/foreign-desktop-guide.md` | 不在代码目录放 README；`env/playbooks/foreign-desktop.yml` 的注释改指新路径 |
| `scripts/contained-agent/skills/agent-browser/SKILL.md` | 保留 | 原处 | agent 运行时读的 skill 定义，由 `src/guix/uraj/home/llm.scm` 打包，不是文档 |
| `scripts/openclaw/skills/agent-browser/SKILL.md` | 保留 | 原处 | 同上，由 OpenClaw 部署使用 |

### docs/

| 现有文档 | 动作 | 去向 | 理由 |
|---|---|---|---|
| `coding-style.org` | 拆分 | `coding-style.md`（索引）；`coding-style/checks-guide.md`（Coding style 一节）；`guix/runtime-modules-guide.md`（Guix runtime modules 一节） | 后一节是 Guix 代码的约定，属于 guix 模块；`restricted-network` 手册链到它 |
| `contained-agent.org` | 拆分 | 见下“contained-agent 的拆法” | 1229 行持续维护的手册 |
| `paseo-broker.org` | 拆分 | 见下“Paseo 的拆法” | 现行用法和 10 月初的设计、实验混在一起 |
| `paseo-daemon.org` | 拆分 | 见下“Paseo 的拆法” | |
| `paseo-gc.org` | 移动 | `paseo/branch-gc-guide.md` | 全篇是现行用法 |
| `paseo-relay.org` | 移动 | `paseo/relay-guide.md` | 全篇是现行用法；首次部署步骤重装时仍要用，留在手册里 |
| `openclaw.org` | 拆分 | 见下“OpenClaw 的拆法” | 1390 行，设计、部署、实验、验收混在一起 |
| `maa.org` | 拆分 | 见下“MAA 的拆法” | |
| `new-api.org` | 移动 | `new-api/deploy-guide.md` | 全篇是部署和运维用法 |
| `restricted-network.org` | 拆分 | `restricted-network/networks-guide.md`（除下一项外全部）；`restricted-network/legacy-tables-deploy-20261015.md`（Lifecycle and migration 中从旧 `uraj_redroid` 表迁移的段落，旧文档） | 一次性迁移已完成 |
| `storie-network.org` | 拆分 | `guix/storie-network-guide.md`（全部，除下一项）；`guix/nfs-measure-20261021.md`（NFS data shares 里 2026-10-21 的检查记录） | |
| `home-only-deployment.org` | 移动 | `guix/home-only-deploy-guide.md` | 全篇是现行用法 |
| `codex-desktop.org` | 移动 | `desktop/codex-desktop-guide.md` | 短，全篇是用法和限制 |
| `ssh-keyring.org` | 移动 | `desktop/ssh-keyring-guide.md` | 全篇是用法；Stored SSH passwords 的迁移说明只有几行，随篇保留 |
| `json-config.org` | 移动 | `config/json-config-guide.md` | |
| `emacs-bqn.org` | 移动 | `emacs/bqn-guide.md` | |
| `guix/system/known-problems.md` | 移动 | `guix/known-problems-debug-20261004.md` | 正文写明“更新：2026-10-04”，是排查记录；以后的新问题另起带日期的 `debug` 文件 |
| `strongswan/README.md` | 移动 | `guix/strongswan-guide.md` | 不在 `docs/` 下用 README 当文档；修相对链接 `../../env/...` |

### contained-agent 的拆法

`docs/contained-agent.md` 只做索引，第一组链接是手册，“当前该怎么用”从这里查：

| 去向 | 来自 `contained-agent.org` 的节 | 类别 |
|---|---|---|
| `contained-agent/overview-guide.md` | 引言和威胁模型、Components、Use、What agents cannot do | 手册：是什么、怎么启动、做不到什么 |
| `contained-agent/container-guide.md` | The container（Working directory、Git、direnv） | 手册 |
| `contained-agent/agent-specs-guide.md` | Agent specs（OpenCode and Pi、Claude Code、Codex） | 手册 |
| `contained-agent/project-config-guide.md` | Project configuration（含 Fixed worktrees、Additional central configuration、Credentials、Inherited approvals） | 手册；最常查的一篇 |
| `contained-agent/browser-guide.md` | Browser tasks、Operate an agent's browser yourself | 手册 |
| `contained-agent/podman-guide.md` | Local Podman runtime 及子节（除 Harbor acceptance） | 手册 |
| `contained-agent/harbor-measure-20261025.md` | Harbor acceptance | 验收记录 |
| `contained-agent/guix-daemon-guide.md` | Optional Guix daemon access | 手册 |
| `contained-agent/ssh-agent-guide.md` | Per-project SSH agents（含 Destination patterns、Verification） | 手册 |
| `contained-agent/pitfalls-guide.md` | Pitfalls（Paseo、Guix、Mounts、Agents） | 手册：仍成立的坑；每条的来历以后拆成 `debug` 文档 |
| `contained-agent/development-guide.md` | Development | 手册：怎么改和测 contained-agent |
| `contained-agent/open-items-design-20261012.md` | Open items | 待办，旧文档（第一条 broker 已实现） |

拆完后每篇手册几十到两百多行，最长的是 `project-config-guide.md`（约 250 行）。

### Paseo 的拆法

| 去向 | 来源 | 类别 |
|---|---|---|
| `paseo.md` | 新写 | 索引 |
| `paseo/daemon-guide.md` | `paseo-daemon.org`：Layout、Configuration 及子节、Image attachments、Daemon mounts and independent SSH agent、Storie、Verification | 手册 |
| `paseo/upgrade-0.15.4-measure-20261113.md` | `paseo-daemon.org`：Upgrade from 0.11.4 to 0.15.4 | 升级和验证记录 |
| `paseo/daemon-cutover-deploy-20261015.md` | `paseo-daemon.org`：First transition and operation | 一次性切换，旧文档 |
| `paseo/broker-guide.md` | `paseo-broker.org`：Implemented trial and lappie commands（现行命令部分）、SSH passphrase prompts、Broker sandbox policy、Shared project SSH agents、Execution tiers | 手册 |
| `paseo/broker-design-20261017.md` | `paseo-broker.org`：Status and scope、Observed Paseo contract、Launch and transport、Host policy and integration、Cleanup boundary、What cgroups add、Parent-death signal: preferred implementation direction | 设计，旧文档（基于 Paseo 0.10.3，部分已被实现取代） |
| `paseo/pid-namespace-debug-20261008.md` | `paseo-broker.org`：Investigation: Guix PID namespace versus cgroup | 调查记录 |
| `paseo/parent-death-measure-20261009.md` | `paseo-broker.org`：Parent-death experiment results，及 Implemented trial 一节里 2026-10-09 的验证记录 | 实验记录 |
| `paseo/broker-acceptance-design-20261016.md` | `paseo-broker.org`：Acceptance before enabling the broker | 验收清单；哪些已做完不清楚，见待定 |
| `paseo/branch-gc-guide.md`、`paseo/relay-guide.md` | 见上表 | 手册 |

### OpenClaw 的拆法

| 去向 | 来自 `openclaw.org` 的节 | 类别 |
|---|---|---|
| `openclaw.md` | 新写 | 索引 |
| `openclaw/scope-guide.md` | 当前范围 | 手册：部署了什么、开放了哪些工具 |
| `openclaw/config-guide.md` | 可写配置、不变量与命令执行 | 手册 |
| `openclaw/persona-guide.md` | 群聊角色与私人身份、首次提示和成员变化、处理进度卡片（除验证记录） | 手册 |
| `openclaw/progress-card-measure-20261106.md` | 处理进度卡片里 2026-11-05/06 的验证记录、状态与验证 | 验收记录 |
| `openclaw/sandbox-guide.md` | 执行沙箱 | 手册 |
| `openclaw/engine-params-debug-20261024.md` | 引擎参数的验证 | 调查记录 |
| `openclaw/browser-guide.md` | 沙箱里的浏览器、手动接管沙箱浏览器 | 手册 |
| `openclaw/image-generation-design-20261020.md` | 图片生成接入 | 未实施的方案 |
| `openclaw/images-guide.md` | 镜像准备、沙箱引擎与沙箱镜像 | 手册 |
| `openclaw/feishu-guide.md` | 飞书与模型及全部子节 | 手册 |
| `openclaw/deploy-guide.md` | 秘密、配置存储与启动、版本切换与备份 | 手册 |
| `openclaw/missing-shepherd-debug-20261020.md` | 部署后没有 Shepherd 服务 | 排查记录 |
| `openclaw/testing-guide.md` | 验证：测试命令和验收清单 | 手册 |
| `openclaw/validation-measure-20261106.md` | 验证：本轮验证的计数和结果 | 验收记录 |
| `openclaw/profile-snapshot-deploy-20261029.md` | Profile 快照方案上线（原挂在“参考”下） | 一次性上线，旧文档 |
| 各篇末尾 | 参考 | 链接跟着引用它的篇 |

### MAA 的拆法

| 去向 | 来自 `maa.org` 的节 | 类别 |
|---|---|---|
| `maa.md` | 新写 | 索引 |
| `maa/redroid-guide.md` | Design、Networking、Control plane、Implementation and first deployment、ARM translation、storie standby | 手册 |
| `maa/daily-tasks-guide.md` | Scheduled daily tasks（除下一项的调查记录） | 手册 |
| `maa/ca-bundle-debug-20261017.md` | Scheduled daily tasks 里 2026-10-17 的 CA bundle 排查和 2026-10-20 的 depot 手动测试 | 排查记录 |
| `maa/remote-access-guide.md` | Runtime evidence 里 adb/scrcpy、`remote-maa`、`hack-fsync` 的用法 | 手册 |
| `maa/runtime-measure-20261017.md` | Runtime evidence 的其余部分、Production recipe checks, 2026-10-17 | 实测记录 |
| `maa/trial-migration-deploy-20261017.md` | Move from the trials to production | 一次性迁移，旧文档；引用的 `scripts/redroid/` 脚本从未进仓库 |
| `maa/validation-measure-20261009.md` | Validation status | 旧文档（原文自称 historical） |

## 新写的文件

迁移时新写，不来自旧文档：

- `docs/glossary.md`：按 [术语表初版](glossary-design-20261114.md)，经人确认后定稿。
- `docs/<module>.md`：每个模块的索引，一行一个链接加一句说明，手册在前、
  过程文档按日期倒序在后。模块：`contained-agent`、`paseo`、`openclaw`、`maa`、
  `new-api`、`restricted-network`、`secrets`、`config`、`guix`、`desktop`、`emacs`、
  `playbooks`、`coding-style`（`dotfiles` 目前没有文档，不建索引）。
- `docs/projects/template/`：三件套模板。
- `AGENTS.md`：新结构。

## 链接修复清单

迁移后 `git grep` 不应再找到下列旧路径（`docs/projects/` 里本项目的文档除外）。

文档之间的链接：`contained-agent.org`、`paseo-broker.org`、`paseo-daemon.org`、
`paseo-relay.org`、`openclaw.org`、`maa.org`、`restricted-network.org`、
`secrets/README.org`、`env/guix/os/README.org`、`env/playbooks/README.org`
里的 `[[file:...]]` 链接和 `[[*标题]]` 锚点，按去向表改到新文件和 GitHub 锚点。
`[[file:coding-style.org::*Guix runtime modules]]` 改为
`../guix/runtime-modules-guide.md`。

代码、配置和注释里的文档路径：

| 位置 | 现在指向 | 改为 |
|---|---|---|
| `manifest.scm:21` | `docs/coding-style.org` | `docs/coding-style/checks-guide.md` |
| `env/dotfiles/llm/contained-agent/.config/contained-agent/projects.scm:7` | `docs/contained-agent.org` | `docs/contained-agent/project-config-guide.md` |
| `env/dotfiles/desktop/apps/.local/bin/remote-maa:5` | `docs/maa.org` | `docs/maa/remote-access-guide.md` |
| `env/maa/profiles/default.toml:1` | `docs/maa.org` | `docs/maa/redroid-guide.md` |
| `env/guix/os/hypie.scm:362`、`env/guix/os/lappie.scm:98` | `secrets/README.org` | `docs/secrets/agent-secrets-guide.md` |
| `env/guix/os/hypie.scm:378` | `docs/maa.org` | `docs/maa/redroid-guide.md` |
| `env/guix/os/storie.scm:350` | `docs/openclaw.org` | `docs/openclaw/images-guide.md` |
| `env/guix/os/storie.scm:465` | `docs/maa.org` | `docs/maa/redroid-guide.md` |
| `env/guix/os/storie.scm:490` | `docs/new-api.org` | `docs/new-api/deploy-guide.md` |
| `env/playbooks/foreign-desktop.yml:4` | `README.org` | `docs/playbooks/foreign-desktop-guide.md` |
| `scripts/secrets/github_token.py:7` | `secrets/README.org` | `docs/secrets/agent-secrets-guide.md` |
| `src/guile/uraj/bin/contained-agent.scm:575` | `secrets/README.org` | `docs/secrets/agent-secrets-guide.md` |
| `src/guix/uraj/common/agent-secrets.scm:17` | `secrets/README.org` | `docs/secrets/agent-secrets-guide.md` |
| `src/guix/uraj/services/new-api.scm:3` | `docs/new-api.org` | `docs/new-api/deploy-guide.md` |
| `src/guix/uraj/services/openclaw.scm:3` | `docs/openclaw.org` | `docs/openclaw/images-guide.md`、`deploy-guide.md` |
| `src/guix/uraj/services/openclaw.scm:324`、`:475` | `docs/openclaw.org` | 按注释内容指向 `config-guide.md` 或 `sandbox-guide.md` |

以上都是注释，不改变行为。但其中几处文件会原样进 store：
`src/guile/uraj/bin/contained-agent.scm`（`with-uraj-modules`）、
`env/maa/profiles/default.toml`（`local-file`）、`projects.scm` 和 `remote-maa`
（Home 部署的 dotfiles），改注释后下次部署会重建这些 store 项，内容只差注释。
迁移后按行号重新核对一次（`main` 可能已经移动行号）。

## 提交顺序

迁移放在一个 PR 里，分几个提交，每个提交可以单独审：

1. `docs: convert org documents to markdown in place`：只转格式，不改文件位置和名字
   以外的东西（`.org` → `.md`），便于对照原文核对格式。
2. `docs: split documents by section into module directories`：按去向表拆分和移动，
   内容不变；每个新文件首行注明来源。
3. `docs: fix links to moved documents`：文档间链接和代码注释里的路径。
4. `docs: add glossary, module indexes and project templates`：新写的文件。
5. `docs: restructure AGENTS.md`：新结构和协作规则。

第 1 步之后仓库里不再有 org 文档；第 1、2 步之间短暂存在 `.md` 平铺状态，
只在这个 PR 的提交历史里。

## 转换时要注意的写法

| 写法 | 例 | 处理 |
|---|---|---|
| 相邻 verbatim | `=LANG=/=LC_ALL=`（`env/playbooks/README.org:20`） | 拆成两个代码片段 |
| 跨行 verbatim | `=systemd-hwdb\n update=`（`env/playbooks/README.org:67`） | 合成一行 |
| verbatim 内含 `=` 或反引号 | `=sec=sys,root_squash=`、``=crun: readlink ``=`` | 双反引号包裹 |
| verbatim 内含 `**` | `=/gnu/store/**=` | 代码片段内保留，确认没变成粗体 |
| `--` 区间 | `16:20--16:25`（`maa.org:168`） | 改为 `–` |
| `*粗体*` | `home-only-deployment.org:72` | 改为 `**粗体**` |
| `#+begin_example` | `openclaw.org` 的命令示例 | 围栏代码块，`text` |
| `#+begin_src` | `sh`、`scheme`、`json`、`yaml` | 围栏代码块，保留语言 |
| 尖括号占位 | `<secret>`、`<oc_ID>` | 在代码片段里，或转义 |
| 无 `#+title` | `coding-style.org`、`env/guix/os/README.org` | 补一级标题 |
| 表格单元格里的 verbatim | `restricted-network.org:36` | 管道表格里用反引号；单元格内的 `|` 转义 |

## 发现的过时内容

调研时发现、但迁移不修的问题，作为本项目后面的步骤逐个处理：

- `paseo-broker.org` 的 Observed Paseo contract 和若干段落基于 Paseo 0.10.3，
  打包的版本已是 0.15.4；`contained-agent.org` Pitfalls 和 `paseo-daemon.org`
  Image attachments 也提到 0.10.3。
- `paseo-broker.org` 说共享 SSH agent 把链接 worktree 归到主仓库，
  和 `contained-agent.org` 以及代码（`project-mounts` 用 worktree 顶层）不一致。
- `contained-agent.org` 的禁止挂载列表比代码里的 `%denied` 少 5 项。
- `secrets/README.org` 写于 hypie 接入之前：只提两台机器，路径表没有 hypie，
  `keys/hosts/` 没有 storie 的公钥，`.sops.yaml` 示例用字面量而不是锚点。
- `paseo-relay.org`、`paseo-daemon.org` 说 storie 上 daemon 到不了 macvlan 上的 relay，
  但 `env/paseo/config.yaml` 给所有主机配置了同一个 relay 地址。
- `maa.org` 引用的 `scripts/redroid/migrate-houdini-data`、`retire-trials` 从未进仓库，
  `test/redroid/retire-trials.sh` 也引用后者。
- `restricted-network.org` 的网络表缺 `sandboxed-agents`；“hypie 的部署块仍注释掉”已过时。
- `new-api.org` 说 `.7` 留给 Paseo daemon，与 `storie-network.org`、`paseo-daemon.org` 矛盾。
- `openclaw.org` 开头“这些是部署声明，不代表主机已运行该服务”已过时。
- `known-problems.md` 说 kexec 修复只用于桌面配置，`system/server.scm` 也用了。
- `env/playbooks/README.org` 提到不存在的 keyboard role（实为 `basic-system` 里的 tag）。
- `docs/strongswan/README.md` 没提 hypie 开机连接 fwd2home；旧服务名 `uraj-charon` 的说明可删。
- 部署命令有五种写法（`sudo -E guix time-machine ...`、`--preserve-env=GUILE_LOAD_PATH`、
  `-L src/guix -L src/guile`、`uraj-deploy`、“the usual deployment tool”），
  手册重写时统一到 `guix/deploy-guide.md` 的写法，其他手册链过去。
