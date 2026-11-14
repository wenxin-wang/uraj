# 文档布局和协作约定

## 目标

uraj 的文档按模块和日期组织，有术语表、模块登记表和子项目三件套；
`AGENTS.md` 写明文档规则和 agent 协作规则。新 session 从 `AGENTS.md`
的“入口”能找到现行用法和进行中的工作。

## 背景

- `docs/` 是十几个平铺的 org 文件，加上 `docs/guix/`、`docs/strongswan/` 两个
  markdown 目录；设计、部署说明、调试记录和过时的计划混在一起。
  `secrets/`、`env/guix/os/`、`env/playbooks/` 里还各有一篇 README。
- `AGENTS.md` 只有代码风格。
- uraj 主要由 agent 开发、人在 GitHub 上审阅，文档首先写给 agent 和审阅者。
- 文档格式改用 markdown，迁移时所有 org 文档都转换，不长期并存。

## 待定

提案见 [layout-design-20261114.md](layout-design-20261114.md) 的“待定”一节和
[glossary-design-20261114.md](glossary-design-20261114.md) 的“待人定的统一”，
汇总如下：

1. 是否接受不带日期的用法手册 `<topic>-guide.md` 和 `deploy` 这个 kind。
2. 子项目交接文件用 `step-<n>-handoff.md`（kebab-case）而不是 `step_<n>_handoff`。
3. 旧文档转换时不翻译，保持原语言；新文档用中文。
4. `exp/bqn/uraj/` 改名、`.gitignore` 的 `/output/` 改 `/out/`：迁移后单独的 `layout` PR。
5. 术语表里 4 处冲突的统一方式。
6. `paseo-broker.org` 的“Acceptance before enabling the broker”清单是否已全部做完；
   决定它迁移后是验收记录还是待办。

## 文档

- [TODO](TODO.md)：进度。
- [layout-design-20261114](layout-design-20261114.md)：目录、docs 布局和命名、
  模块登记表初版、协作规则逐条判断。
- [migration-design-20261114](migration-design-20261114.md)：现有文档的去向表、
  拆分方案、链接修复清单、提交顺序、发现的过时内容。
- [glossary-design-20261114](glossary-design-20261114.md)：术语表初版。
- [agents-md-design-20261114](agents-md-design-20261114.md)：`AGENTS.md` 新结构草稿。
- [templates-design-20261114](templates-design-20261114.md)：子项目三件套模板。
