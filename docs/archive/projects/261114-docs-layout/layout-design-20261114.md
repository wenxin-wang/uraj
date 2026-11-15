# 目录、文档和协作约定提案（2026-11-14）

本提案只描述目标布局和取舍，确认前不移动、不删除现有文档。相关文档：

- [glossary-design-20261114.md](glossary-design-20261114.md)：术语表初版。
- [migration-design-20261114.md](migration-design-20261114.md)：
  现有文档逐个去向、拆分方案、链接修复清单和提交顺序。
- [agents-md-design-20261114.md](agents-md-design-20261114.md)：
  `AGENTS.md` 新结构全文草稿。
- [templates-design-20261114.md](templates-design-20261114.md)：子项目三件套模板。

## 目录布局

现有顶层目录全部保留，这次迁移只动 `docs/`、`README.org` 和
各处的 org 文档。代码目录的偏差只登记，不搬家：搬动 `scripts/` 或测试会改变
Guix 的 `local-file` 路径和测试入口，属于代码行为改动，不在本项目范围内。

| 目录 | 约定 | uraj 现状 | 处理 |
|---|---|---|---|
| `src/<lang>/uraj/...` | 代码，`<lang>` 为 `c`、`guile`、`guix`、`python` | 已是这样 | 不变 |
| `test/<lang>/uraj/...` | 与 `src` 一一对应 | 大体如此；偏差见下 | 登记偏差，新测试按约定放 |
| `scripts/` | 薄入口、开发工具、被部署的运行时资源 | 见下“scripts” | 不冻结，规则见下 |
| `env/` | 部署配置 | `guix/`、`dotfiles/`、`emacs/`、`docker/`、`maa/`、`paseo/`、`playbooks/`、`strongswan/`、`desktop/` | 不变；`env/guix/os/README.org`、`env/playbooks/README.org` 移到 `docs/` |
| `exp/<名字>_<yyyymmdd>/` | 一次性实验，`src` 不引用 | 只有 `exp/bqn/uraj/`（BQN 的 Guix 环境） | 待定 1 |
| `secrets/` | SOPS 密文 | 含 `README.org` | 说明移到 `docs/secrets/`，目录只留密文和公钥 |
| `vendor/` | 第三方，不改 | 一个子模块 | 不变 |
| `out/`、`tmp/` | 运行产物，不进 git | `.gitignore` 里是 `/output/`、`/tmp/`、`.tmp`；仓库里目前没有工具往这里写 | 待定 2 |
| `docs/` | 见下 | 平铺 org | 本项目迁移 |

### 偏差

- **Guix 代码按层分目录。** Guix 的模块名就是路径（`(uraj services openclaw)`），
  一个 uraj 模块的代码分布在 `packages/`、`services/`、`home/`、`system/`、
  `build/` 几层里，不可能是 `src/guix/uraj/<module>/`。这是 Guix 的惯例，
  保留；模块对应哪些文件以模块表为准。
- **测试的位置。** `test/openclaw/`、`test/maa/`、`test/redroid/` 按模块而不按语言分；
  `test/python/uraj/guix/contained-agent/` 里放着 Paseo 的测试（`paseo-*.py`、
  `parent-death-namespace.py`），用 Python 测 Guix 服务。登记在模块表备注里；
  以后改到这些测试时再收敛，不专门搬。
- **入口不薄。** `src/guile/uraj/bin/contained-agent.scm` 一千多行，逻辑都在里面；
  `scripts/openclaw/*.mjs` 是插件逻辑。同上，只登记。

### scripts

`scripts/` 里不是冻结的旧代码，有三类仍在用的东西：

1. 开发工具：`scripts/coding_style/`（pre-commit 钩子通过 `core.hooksPath` 指过来）。
2. 被 Guix 打包进部署的运行时资源：`scripts/contained-agent/skills/`
   （`src/guix/uraj/home/llm.scm` 的 `local-file`）、`scripts/openclaw/config-plugin/`、
   `config.mjs`、`config-policy.mjs`（`src/guix/uraj/services/openclaw.scm`）。
3. 薄入口和主机上手动跑的检查：`scripts/paseo/branch-gc`、`scripts/secrets/github_token.py`、
   `scripts/openclaw/try-*`、`scripts/contained-agent/try-browser`。

规则：新逻辑写进 `src/`，`scripts/` 只放入口、工具和打包资源；`SKILL.md`
是 agent 运行时读的 skill 定义，不算文档，留在原处，不受“不在代码目录放 README”
和“文档放 docs/”约束。

## docs 布局

```
docs/
  glossary.md                              术语表
  <module>.md                              模块总览：一行一个链接加一句说明
  <module>/<topic>-guide.md                用法手册（不带日期，跟着 main 更新）
  <module>/<topic>-<kind>-<yyyymmdd>.md    带日期的过程文档，写完不改
  projects/template/                       三件套模板
  projects/<yymmdd>-<project>/
    README.md                              目标、背景、待定（含人的决定和日期）
    TODO.md                                按步编号的进度
    step-<n>-handoff.md                    第 n 步的交接
    <topic>-<kind>-<yyyymmdd>.md           过程文档
```

### 命名

- 全部小写 kebab-case，和现有 `docs/`、`scripts/`、Guix 模块的文件名一致；
  只有 `README.md`、`TODO.md` 大写（GitHub 在目录页自动渲染 `README.md`）。
- 参考约定里的 `step_<n>_handoff` 改为 `step-<n>-handoff.md`，与其他文件名统一。
- 日期：文件名 `yyyymmdd`，子项目目录 `yymmdd`，正文 `yyyy-mm-dd`；
  README 待定项里的“11/02 定”沿用参考写法。
- `<kind>` 取固定集合：

  | kind | 用途 | 例 |
  |---|---|---|
  | `design` | 设计、方案、取舍 | `broker-design-20261017.md` |
  | `measure` | 实测、验收、部署后的运行证据 | `harbor-measure-20261025.md` |
  | `review` | 评审 | |
  | `debug` | 排查记录、已知问题 | `known-problems-debug-20261004.md` |
  | `deploy` | 一次性的部署、切换、迁移记录（做完就成为历史） | `legacy-tables-deploy-20261015.md` |

  不用 `test` 作为 kind，免得和 `test/` 目录及“测试”混淆。`deploy` 是参考约定之外
  加的：uraj 的文档里有很多“首次切换”“从旧表迁移”这类只做一次的步骤，
  放进手册会让手册里混着已经不该再执行的命令。可重复执行的部署步骤（例如重装后的
  首次部署）仍属于手册。

### 用法手册：参考约定之外加的一类

uraj 的文档大半是“当前该怎么用”的手册（例如 `docs/contained-agent.org` 的
项目配置子句、凭据、SSH agent 各节），会随代码持续更新。参考约定里只有
带日期的过程文档，手册放进去会出现两种坏结果：要么按日期分文件后“现在怎么用”
散在多份文档里，要么带日期的文件被反复修改，日期失去意义。

所以加一类不带日期的 `<topic>-guide.md`：

- 只写 `main` 上的现状：怎么用、配置子句、必须知道的限制和坑。
- 不写历史、理由和实验过程；需要理由时链到带日期的 `design`/`debug`/`measure`。
- 改变用法的 PR 同时改对应的手册，这条写进 AGENTS.md 的文档规则。
- 一个模块的手册按主题拆，单个手册控制在几百行内。

“当前该怎么用”从 `docs/<module>.md` 的索引进：索引第一组链接就是该模块的手册。

### 格式

- markdown（GitHub 方言）。表格用管道表格；代码块用围栏并标语言；
  站内链接用相对路径，指向标题时用 GitHub 生成的锚点。
- 正文语言：新文档用中文，与 `AGENTS.md` 一致；代码标识符、命令、路径保持原样。
  转换旧文档时不翻译，英文文档转换后仍是英文（待定 3）。
- 不在文档里写断行敏感的结构（org 的 `#+begin_example` 改为围栏代码块）。

## 模块登记表初版

模块名同时是 `docs/<module>.md` 的文件名和 PR 标题的 topic。

| 模块 | 说明 | 代码 | 测试 | 备注 |
|---|---|---|---|---|
| `contained-agent` | coding agent 的 Guix 容器、项目配置、项目 SSH agent、Podman 运行时、浏览器 skill | `src/guile/uraj/bin/contained-agent.scm`、`contained-ssh.scm`；`src/guix/uraj/home/llm.scm`；`src/guix/uraj/packages/llm.scm`；`src/python/uraj/contained_podman.py`、`container/seccomp.py`；`scripts/contained-agent/`；`env/dotfiles/llm/` | `test/python/uraj/guix/contained-agent/contained-agent-*.py`、`podman-runtime-*.py` | 入口不薄；`container/seccomp.py` 也被 OpenClaw 用 |
| `paseo` | Paseo daemon 容器、broker、分支清理、relay | `src/python/uraj/paseo/`；`src/c/uraj/paseo/`；`src/guile/uraj/bin/paseo-sandbox.scm`；`src/guix/uraj/home/paseo.scm`、`paseo-broker.scm`；`src/guix/uraj/services/paseo.scm`、`paseo-relay.scm`；`scripts/paseo/`；`env/paseo/` | `test/python/uraj/guix/contained-agent/paseo-*.py`、`parent-death-namespace.py`；`test/guix/uraj/services/paseo*.scm` | 测试在 contained-agent 目录下 |
| `openclaw` | storie 上的飞书 bot：Gateway、执行沙箱、插件 | `src/guix/uraj/services/openclaw.scm`；`src/guix/uraj/build/openclaw.scm`；`scripts/openclaw/`；`env/docker/openclaw-*` | `test/openclaw/`；`test/python/uraj/openclaw/`；`test/guix/uraj/openclaw-*.scm`、`services/openclaw.scm` | 测试按模块不按语言；插件逻辑在 `scripts/` |
| `maa` | redroid 上的 MAA 日常任务 | `src/guix/uraj/services/maa.scm`、`redroid.scm`；`src/guix/uraj/packages/maa.scm`、`redroid.scm`、`android.scm`；`src/guix/uraj/build/redroid.scm`；`env/maa/` | `test/maa/`、`test/redroid/`；`test/guix/uraj/build/redroid.scm`、`services/redroid.scm` | 测试按模块不按语言 |
| `new-api` | storie 上的模型网关 | `src/guix/uraj/services/new-api.scm` | `test/guix/uraj/services/new-api.scm` | |
| `restricted-network` | Docker/Podman 应用的受限网络 | `src/guix/uraj/services/restricted-network.scm`；`src/guix/uraj/build/restricted-network*.scm`；`src/guix/uraj/network-policy.scm` | `test/guix/uraj/network-policy.scm`、`restricted-network-*`、`services/restricted-network.scm`；`test/python/uraj/guix/restricted-network.py` | |
| `secrets` | SOPS 密钥布局、接入机器、各服务的秘密 | `secrets/`、`.sops.yaml`；`src/guix/uraj/system/secrets.scm`；`src/guix/uraj/common/agent-secrets.scm`；`scripts/secrets/` | `test/guix/uraj/system/secrets.scm`；`test/python/uraj/config/sops-yaml.py` | |
| `config` | JSON/YAML 分层配置的合并和写出 | `src/python/uraj/config/` | `test/python/uraj/config/` | |
| `guix` | System/Home 骨架、主机配置、部署、channels、通用包和服务、局域网和 NFS、strongSwan、Immich | `src/guix/uraj/{system,common,hardware,utils}/`；`src/guix/uraj/services/` 其余服务；`src/guix/uraj/packages/` 其余包；`src/guix/uraj/home/basic-*.scm`；`src/guix/uraj/build/crate-mirrors.scm`；`src/guile/uraj/{maak,utils}/`；`src/python/uraj/home/`；`env/guix/`；`env/strongswan/`；`manifest.scm`、`.envrc` | `test/guix/uraj/{system,services,utils}/` 其余；`test/guix/deploy-target.scm`；`test/guile/`；`test/python/uraj/home/`、`guix/shell/` | 最大的模块；文档按主题分 |
| `desktop` | 桌面会话、niri、输入法、SSH 口令存储、桌面应用打包（Codex 桌面版、飞书） | `src/guix/uraj/home/{basic-desktop,niri,keyring,camera}.scm`；`src/guix/uraj/services/desktop.scm`；`src/guile/uraj/desktop/`；`src/guix/uraj/packages/` 中桌面相关；`env/desktop/`；`env/dotfiles/desktop/` | `test/guix/uraj/system/desktop.scm`；`test/python/uraj/guix/keyring/` | |
| `emacs` | Emacs 配置 | `env/emacs/`；`src/guix/uraj/home/emacs.scm` | | |
| `dotfiles` | 不属于以上模块的 dotfiles | `env/dotfiles/{common,dev}/` | | `desktop/`、`llm/` 子目录归对应模块 |
| `playbooks` | 非 Guix 发行版上的桌面准备 | `env/playbooks/` | | |
| `coding-style` | 代码风格检查和钩子 | `scripts/coding_style/`；`.clang-format`、`CPPLINT.cfg`、`ruff.toml` | | |

PR topic 的变化：近两个月的提交里 `agents:` 占大半，覆盖了
contained-agent、Paseo、OpenClaw 三个模块，`gaming:` 指 MAA，`services:` 指
具体服务。以后改用模块名；跨模块的改动用主要模块名，正文说明影响的其他模块。

## 协作规则逐条判断

参考约定的协作规则整体写进 `AGENTS.md`（见草稿）。下面只列需要按 uraj 调整
或不适用的条目。

| 条目 | 判断 | 理由 |
|---|---|---|
| 长任务交给 Shepherd 或 tmux，配查状态命令 | **部分适用，改写** | contained-agent 会话的容器随 session 退出（PID 1 是 `guix shell` 容器），容器里没有 tmux，也看不到主机的 Shepherd。Guix 构建本来就在 guix-daemon 里跑；其余长任务由 agent 写好启动命令和查状态命令，交给人在主机上启动 |
| worktree 共享主仓库的 `out/`、`instances/`、`tmp/`（用 `share` 映射） | **暂不配置** | 仓库里目前没有工具往这些目录写产物，配置 `share` 只增加挂载。等第一个需要跨 worktree 产物的模块出现时，再在 `projects.scm` 的 uraj 条目加 `(share ("~/src/uraj/out" "out"))`，那是 `env/` 改动，单独 PR |
| 审查贴到 PR | **适用，加一条** | 所有 session 用同一个 GitHub 账号，GitHub 不允许 approve 自己的 PR；审查一律用 `gh pr comment`，不用 review approve/request changes |
| 批量操作先跑试用批次 | **适用，举 uraj 的例子** | uraj 的批量操作主要是多台主机的部署和批量改配置：先部署一台 |
| 不直接提交到 `main` | **适用于 agent** | 人仍会直接在 `main` 上提交小改动（例如 Emacs 配置），规则只约束 agent |
| `src`/`test` 一一对应、薄入口 | **新代码适用** | 现有偏差见上，只登记不搬 |
| 模块登记表写在 `AGENTS.md` | **适用** | 表较宽，`AGENTS.md` 只放模块、说明、代码、测试四列的精简版；备注随表一起 |

另外加入 `AGENTS.md`“必须遵守”的 uraj 红线（参考约定里没有）：

- 不提交明文秘密和主机私有配置（仓库公开）。
- 不在未被要求时对主机部署或重启服务。
- 不改 `vendor/`。

## 待定

1. `exp/bqn/uraj/` 是否改名为 `exp/bqn_20261014/`。建议改：它是 BQN 的一次性
   Guix 环境，日期取首次提交。改名不是文档改动，放在迁移之后单独一个 `layout` PR。
2. 运行产物目录名：建议把 `.gitignore` 的 `/output/` 改为 `/out/`，与约定一致；
   `.tmp` 和 `/tmp/` 保留。同样放在单独的 `layout` PR。
3. 转换旧文档时是否顺便翻译成中文。建议不翻译：翻译会让“格式转换”的 diff
   混入内容改动，审阅时看不出是否丢了信息；以后重写成手册时再用中文。
4. 用法手册（`<topic>-guide.md`）这一类是否接受。不接受的话，替代做法是手册也带日期，
   每次更新另起新文件，索引指向最新的一份。
