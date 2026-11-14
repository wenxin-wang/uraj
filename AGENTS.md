# uraj

公开仓库：Guix System/Home 配置、自建服务、coding agent 沙箱、dotfiles 和
Emacs 配置。主要由 agent 开发，人在 GitHub 上审阅和合并。

## 入口

新 session 从这里进。最重要的设计文档和进行中的子项目各一行。

- [术语表](docs/glossary.md)：一个概念一个名字；新词先登记再用。
- [contained-agent](docs/contained-agent.md)：coding agent 的 Guix 容器。
- [Paseo](docs/paseo.md)：Paseo daemon、broker、relay 和分支清理。
- [OpenClaw](docs/openclaw.md)：storie 上的飞书 bot。
- [guix](docs/guix.md)：主机配置、部署、已知问题。
- [secrets](docs/secrets.md)：SOPS 布局和接入新机器。
- 进行中：[261114-docs-layout](docs/projects/261114-docs-layout/TODO.md)，
  文档布局和协作约定的迁移和后续整理。

## 目录

| 目录 | 放什么 |
|---|---|
| `src/<lang>/uraj/...` | 代码。`<lang>` 为 `c`、`guile`、`guix`、`python`。 |
| `test/<lang>/uraj/...` | 测试，和 `src` 路径一一对应。 |
| `scripts/` | 薄入口、开发工具和被 Guix 打包进部署的运行时资源（skill、插件）。 |
| `env/` | 部署配置：`guix/`（channels、`os/` 主机配置）、`dotfiles/`、`emacs/`、`docker/` 等。 |
| `secrets/` | SOPS 密文和公钥；说明在 `docs/secrets.md`。 |
| `docs/` | 文档，规则见下文。 |
| `exp/<名字>_<yyyymmdd>/` | 一次性脚本和实验；`src`、`env` 不引用它。 |
| `vendor/` | 第三方代码和子模块，不改，不套本仓库风格。 |
| `out/`、`tmp/` | 运行产物，不进 git。 |

Guix 代码按 Guix 的层次分目录（`packages/`、`services/`、`home/`、`system/`、
`build/`），一个模块的代码分布在几层里；模块对应哪些文件以下面的模块表为准。
新代码的逻辑放 `src`，`scripts/` 和 `src/guile/uraj/bin/` 里的入口只解析参数、
调用 `src`。已有的偏差列在模块表的“备注”里，改动时顺手收敛，不专门搬家。
`scripts/**/SKILL.md` 是 agent 运行时读的 skill 定义，不是文档。

## 模块

新加模块先在这里登记，再写代码和文档。模块名也是 PR 标题的 topic 和
`docs/<module>.md` 的文件名。

| 模块 | 说明 | 代码 | 测试 | 备注 |
|---|---|---|---|---|
| `contained-agent` | coding agent 的 Guix 容器、项目配置、项目 SSH agent、Podman 运行时、浏览器 skill | `src/guile/uraj/bin/contained-agent.scm`、`contained-ssh.scm`；`src/guix/uraj/home/llm.scm`；`src/guix/uraj/packages/llm.scm`；`src/python/uraj/contained_podman.py`、`container/seccomp.py`；`scripts/contained-agent/`；`env/dotfiles/llm/` | `test/python/uraj/guix/contained-agent/contained-agent-*.py`、`podman-runtime-*.py` | 入口不薄；`container/seccomp.py` 也被 OpenClaw 用 |
| `paseo` | Paseo daemon 容器、broker、分支清理、relay | `src/python/uraj/paseo/`；`src/c/uraj/paseo/`；`src/guile/uraj/bin/paseo-sandbox.scm`；`src/guix/uraj/home/paseo.scm`、`paseo-broker.scm`；`src/guix/uraj/services/paseo.scm`、`paseo-relay.scm`；`scripts/paseo/`；`env/paseo/` | `test/python/uraj/guix/contained-agent/paseo-*.py`、`parent-death-namespace.py`；`test/guix/uraj/services/paseo*.scm` | 测试在 contained-agent 目录下 |
| `openclaw` | storie 上的飞书 bot：Gateway、执行沙箱、插件 | `src/guix/uraj/services/openclaw.scm`；`src/guix/uraj/build/openclaw.scm`；`scripts/openclaw/`；`env/docker/openclaw-*` | `test/openclaw/`；`test/python/uraj/openclaw/`；`test/guix/uraj/openclaw-*.scm`、`services/openclaw.scm` | 测试按模块不按语言；插件逻辑在 `scripts/` |
| `maa` | redroid 上的 MAA 日常任务 | `src/guix/uraj/services/maa.scm`、`redroid.scm`；`src/guix/uraj/packages/maa.scm`、`redroid.scm`、`android.scm`；`src/guix/uraj/build/redroid.scm`；`env/maa/` | `test/maa/`、`test/redroid/`；`test/guix/uraj/build/redroid.scm`、`services/redroid.scm` | 测试按模块不按语言 |
| `new-api` | storie 上的模型 API 网关 | `src/guix/uraj/services/new-api.scm` | `test/guix/uraj/services/new-api.scm` | |
| `restricted-network` | Docker/Podman 应用的受限网络 | `src/guix/uraj/services/restricted-network.scm`；`src/guix/uraj/build/restricted-network*.scm`；`src/guix/uraj/network-policy.scm` | `test/guix/uraj/network-policy.scm`、`restricted-network-*`、`services/restricted-network.scm`；`test/python/uraj/guix/restricted-network.py` | |
| `secrets` | SOPS 密钥布局、接入机器、各服务的秘密 | `secrets/`、`.sops.yaml`；`src/guix/uraj/system/secrets.scm`；`src/guix/uraj/common/agent-secrets.scm`；`scripts/secrets/` | `test/guix/uraj/system/secrets.scm`；`test/python/uraj/config/sops-yaml.py` | |
| `config` | JSON/YAML 分层配置的合并和写出 | `src/python/uraj/config/` | `test/python/uraj/config/` | |
| `guix` | System/Home 骨架、主机配置、部署、channels、通用包和服务、局域网和 NFS、strongSwan、Immich | `src/guix/uraj/{system,common,hardware,utils}/`；`src/guix/uraj/services/` 其余服务；`src/guix/uraj/packages/` 其余包；`src/guix/uraj/home/basic-*.scm`；`src/guix/uraj/build/crate-mirrors.scm`；`src/guile/uraj/{maak,utils}/`；`src/python/uraj/home/`；`env/guix/`；`env/strongswan/`；`manifest.scm`、`.envrc` | `test/guix/uraj/{system,services,utils}/` 其余；`test/guix/deploy-target.scm`；`test/guile/`；`test/python/uraj/home/`、`guix/shell/` | |
| `desktop` | 桌面会话、niri、输入法、SSH 口令存储、桌面应用打包 | `src/guix/uraj/home/{basic-desktop,niri,keyring,camera}.scm`；`src/guix/uraj/services/desktop.scm`；`src/guile/uraj/desktop/`；`src/guix/uraj/packages/` 中桌面相关；`env/desktop/`；`env/dotfiles/desktop/` | `test/guix/uraj/system/desktop.scm`；`test/python/uraj/guix/keyring/` | |
| `emacs` | Emacs 配置 | `env/emacs/`；`src/guix/uraj/home/emacs.scm` | | |
| `dotfiles` | 不属于以上模块的 dotfiles | `env/dotfiles/{common,dev}/` | | `desktop/`、`llm/` 子目录归对应模块 |
| `playbooks` | 非 Guix 发行版上的桌面准备 | `env/playbooks/` | | |
| `coding-style` | 代码风格检查和钩子 | `scripts/coding_style/`；`.clang-format`、`CPPLINT.cfg`、`ruff.toml` | | |

## 文档规则

- 格式一律 markdown。文档放 `docs/`，代码目录里不放 README。
- [`docs/glossary.md`](docs/glossary.md) 是硬约束：一个东西只有一个名字，
  一个名字只指一个东西；新词先登记再用；编号前必须带语义名；代码标识符跟着术语走。
- `docs/<module>.md` 只做索引：一行一个链接加一句说明，手册在前，
  过程文档按日期倒序在后。
- `docs/<module>/<topic>-guide.md`：用法手册，不带日期，始终描述 `main`
  上的现状；改变用法的 PR 同时改它。只写怎么用和必须知道的限制，理由链到过程文档。
- `docs/<module>/<topic>-<kind>-<yyyymmdd>.md`：带日期的过程文档，写完后不再改，
  过时了就写新的。`<kind>` 取 `design`（设计）、`measure`（实测、验收）、
  `review`（评审）、`debug`（排查记录）、`deploy`（一次性的部署、切换、迁移记录）。
- 文件名小写 kebab-case；只有 `README.md`、`TODO.md` 大写。
- `docs/projects/<yymmdd>-<project>/`：子项目，`README.md`（目标、背景、待定）、
  `TODO.md`（进度的唯一来源）、`step-<n>-handoff.md`（交接）三件套，加上带日期的
  过程文档。模板在 [`docs/projects/template/`](docs/projects/template/README.md)。
  已有项目的后续工作在原项目里加一步，只有独立的新方向才开新项目。
- 新文档用中文；代码标识符、命令、路径保持原样。
- 不链接、不提及仓库外的私人资料；project 文档只写可以公开的技术内容。

## 必须遵守

- 不直接提交到 `main`，不合并 PR；合并由人做。
- 不提交明文秘密、私钥、token 和主机私有配置；秘密只以 SOPS 密文进 `secrets/`，
  主机私有的配置放仓库外（例如 `~/.config/contained-agent/projects.local.scm`）。
- 不对主机执行部署或重启服务（`guix system reconfigure`、`guix deploy`、
  `guix home reconfigure`、`herd restart` 等），除非人在本 session 里明确要求。
- 不改 `vendor/`。
- commit 或开 PR 前重读 `origin/main` 的 `AGENTS.md`，老 session 可能漏掉新规则。
- 先确认范围再动手；会改变人已定事项的地方先停下来问。

## 提代码

### 代码风格

- C/C++ 遵循 Google C++ Style Guide 中适用于该语言的规则；Python 遵循
  Google Python Style Guide。配置见 `.clang-format`、`CPPLINT.cfg`、
  `ruff.toml`，不对 `vendor/` 应用本仓库风格。
- C/C++ 使用 clang-format 和 cpplint；Python 使用 Ruff 格式化和 lint，
  80 列、双引号；不强制 docstring，已有 docstring 按 Google 风格检查。
  Ruff 只覆盖部分 Google 规则，其余靠审查。
- 首次开发运行 `scripts/coding_style/install-hooks`（contained-agent 会话
  已通过 `core.hooksPath` 启用，脚本直接返回）。提交前运行
  `scripts/coding_style/check --staged`；检查只报错，不修改文件或暂存区。
- 可显式运行 `scripts/coding_style/fix <file.py> ...` 应用 Ruff 安全修复，
  剩余 lint 按诊断手动修复；需要格式化时显式运行
  `scripts/coding_style/format <file> ...`，检查 diff 后重新暂存。
- 不要顺手格式化与任务无关的文件；部分暂存时尤其要保留用户未暂存的改动。

### 分支和 PR

- 一个 session 一个 worktree，在分支上开发；提交前 rebase 到最新的 `main`，
  用 `gh pr create` 开 PR。
- PR 标题 `<topic>: <简短描述>`，topic 是模块名，或 `docs`、`env`、`layout`、`exp`；
  跨模块的改动用主要模块名，正文说明影响的其他模块。
- PR 描述写给下一个接手的 agent，三段：改了什么、为什么（链到 `docs/projects/`）；
  怎么验证的（没验证的直接说）；没做完的和要注意的。
- 堆叠在未合并分支上的 PR 保持 draft；base 合并后立刻把子 PR 的目标改成 `main`。
- agent 只给出能不能合的判断。

### 审查

- 审查直接用 `gh pr comment` 贴到 PR 里，标题“第 N 轮审查”，不先问。
  所有 session 用同一个 GitHub 账号，不能 approve 自己的 PR，不要用 review approve。
- 作者 session 对同意的修改直接改，按轮次回复；涉及范围或接口的改动仍要先问。
- 审查不改共享 worktree：作者 session 可能正在 rebase，审查方的实验放到 `/tmp` 里做。

### 运行和验证

- 测试失败保留完整输出；性能问题先测量再下结论。
- 批量操作（例如多台主机的部署、批量改配置）先做一个试用批次给人审阅，
  人明确说跳过才跳过。
- 长任务不依赖 session 存活。contained-agent 的容器随 session 退出，容器里
  没有 tmux 和主机 Shepherd：Guix 构建交给 guix-daemon；其余要跨 session
  的任务写好启动命令和查状态的命令，交给人在主机上用 Shepherd 或 tmux 启动。
- 共享的产物目录（`out/`、`tmp/`）里每个 session 用自己的子目录。
