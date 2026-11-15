# AGENTS.md 新结构草稿（2026-11-14）

本文是迁移后 `AGENTS.md` 的全文草稿，供审阅；确认前不替换现有 `AGENTS.md`。
取舍理由见 [layout-design-20261114.md](layout-design-20261114.md)
的“协作规则逐条判断”。模块表在迁移时按最终的
[模块登记表](layout-design-20261114.md#模块登记表初版) 填入，这里只留结构。

---

````markdown
# uraj

公开仓库：Guix System/Home 配置、自建服务、coding agent 沙箱、dotfiles 和
Emacs 配置。主要由 agent 开发，人在 GitHub 上审阅和合并。

## 入口

新 session 从这里进。最重要的设计文档和进行中的子项目各一行。

- [术语表](docs/glossary.md)：一个概念一个名字；新词先登记再用。
- [contained-agent](docs/contained-agent.md)：coding agent 的 Guix 容器沙箱。
- [Paseo](docs/paseo.md)：Paseo daemon、broker、relay 和分支清理。
- [OpenClaw](docs/openclaw.md)：storie 上的飞书 bot。
- [guix](docs/guix.md)：主机配置、部署、已知问题。
- [secrets](docs/secrets.md)：SOPS 布局和接入新机器。
- 进行中：[261114-docs-layout](docs/projects/261114-docs-layout/TODO.md)
  文档布局和协作约定迁移。

## 目录

| 目录 | 放什么 |
|---|---|
| `src/<lang>/uraj/...` | 代码。`<lang>` 为 `c`、`guile`、`guix`、`python`。 |
| `test/<lang>/uraj/...` | 测试，和 `src` 路径一一对应。 |
| `scripts/` | 薄入口、开发工具和被 Guix 打包进部署的运行时资源（skill、插件）。 |
| `env/` | 部署配置：`guix/`（channels、`os/` 主机配置）、`dotfiles/`、`emacs/`、`docker/` 等。 |
| `secrets/` | SOPS 密文；说明在 `docs/secrets.md`。 |
| `docs/` | 文档，规则见下文。 |
| `exp/<名字>_<yyyymmdd>/` | 一次性脚本和实验；`src`、`env` 不引用它。 |
| `vendor/` | 第三方代码和子模块，不改，不套本仓库风格。 |
| `out/`、`tmp/` | 运行产物，不进 git。 |

Guix 代码按 Guix 的层次分目录（`packages/`、`services/`、`home/`、`system/`、
`build/`），一个模块的代码分布在几层里；模块对应哪些文件以下面的模块表为准。
新代码的逻辑放 `src`，`scripts` 和 `src/guile/uraj/bin/` 里的入口只解析参数、
调用 `src`。已有的偏差列在模块表的“备注”里，改动时顺手收敛，不专门搬家。

## 模块

新加模块先在这里登记，再写代码和文档。模块名也是 PR 标题的 topic 和
`docs/<module>.md` 的文件名。

| 模块 | 说明 | 代码 | 测试 | 备注 |
|---|---|---|---|---|
| …… | 迁移时按模块登记表填入 | | | |

## 文档规则

- 格式一律 markdown。文档放 `docs/`，代码目录里不放 README。
- `docs/glossary.md` 是硬约束：一个东西只有一个名字，一个名字只指一个东西；
  新词先登记再用；编号前必须带语义名；代码标识符跟着术语走。
- `docs/<module>.md` 只做索引：一行一个链接加一句说明。
- `docs/<module>/<topic>-guide.md`：用法手册，不带日期，始终描述 `main`
  上的现状；改变用法的 PR 同时改它。只写怎么用和必须知道的限制，理由链到设计文档。
- `docs/<module>/<topic>-<kind>-<yyyymmdd>.md`：带日期的过程文档，写完后不再改，
  过时了就写新的。`<kind>` 取 `design`（设计）、`measure`（实测、验收）、
  `review`（评审）、`debug`（排查记录）。
- `docs/projects/<yymmdd>-<project>/`：子项目，`README.md`、`TODO.md`、
  `step-<n>-handoff.md` 三件套，加上带日期的过程文档。模板在
  `docs/projects/template/`。已有项目的后续工作在原项目里加一步，
  只有独立的新方向才开新项目。
- 旧文档只读：还要用的内容在新文档里重写，旧的以后删掉。
- 不链接、不提及仓库外的私人资料；project 文档只写可以公开的技术内容。

## 必须遵守

- 不直接提交到 `main`，不合并 PR；合并由人做。
- 不提交明文秘密、私钥、token 和主机私有配置；秘密只以 SOPS 密文进 `secrets/`，
  主机私有的配置放仓库外（例如 `~/.config/contained-agent/projects.local.scm`）。
- 不对主机执行部署或重启服务（`guix system reconfigure`、`guix deploy`、
  `guix home reconfigure`、`herd restart` 等），除非人在本 session 里明确要求。
- 不改 `vendor/`。
- commit 或开 PR 前重读 `origin/main` 的 `AGENTS.md`。
- 先确认范围再动手；会改变人已定事项的地方先停下来问。

## 提代码

### 代码风格

（现有“Coding style”一节原样保留。）

### 分支和 PR

- 一个 session 一个 worktree，在分支上开发；提交前 rebase 到最新的 `main`，
  用 `gh pr create` 开 PR。
- PR 标题 `<topic>: <简短描述>`，topic 是模块名，或 `docs`、`env`、`layout`、`exp`。
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
  的任务写成命令和查状态的命令，交给人在主机上用 Shepherd 或 tmux 启动。
- 共享的产物目录（`out/`、`tmp/`）里每个 session 用自己的子目录。
````
