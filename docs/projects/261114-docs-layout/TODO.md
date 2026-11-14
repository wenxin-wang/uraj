# 文档布局和协作约定 进度

当前：第 4 步，按模块调研过时内容和手册里的过程记录。

1. ~~提案：目录和 docs 布局、术语表初版、模块登记表初版、三件套模板、
   `AGENTS.md` 新结构、现有文档去向表~~ 已完成。PR #97 合并，待定项按建议执行。
   产物：本目录下的 `*-design-20261114.md`。
2. ~~迁移：按 [去向表](migration-design-20261114.md) 转换和拆分现有文档，
   修好文档间链接和代码注释里的路径，新写术语表、模块索引、模板、`AGENTS.md`。~~
   PR #98 已合并。结论：
   - 20 篇 org 全部转成 markdown，转换器按作者意图识别 verbatim（org 解析器在
     紧贴汉字、`=a=/=b=`、`=x=y=` 处会漏掉或拆错）；逐词对照原文无增删。
   - 拆出 61 篇文档、13 个模块索引；内容逐词守恒。拆出的文件不注明来源节，
     来源看 git 历史（README 待定 7）。
   - 和去向表的偏差：只按整节拆，节内夹着的带日期段落留在手册里
     （见第 4 步）；`openclaw.org` 的“状态与验证”留在 `persona-guide.md`，
     “验证”整节进 `testing-guide.md`；MAA 的 Runtime evidence 整节留在
     `redroid-guide.md`，因为 `remote-maa` 的用法在里面。
   - 代码注释里 13 个文件的文档路径已改；其中 `contained-agent.scm`、
     `env/maa/profiles/default.toml`、`projects.scm`、`remote-maa` 会原样进 store，
     下次部署会重建，内容只差注释。
3. ~~目录收敛：`exp/bqn/uraj/` 改名为 `exp/bqn_20261014/`，`.gitignore` 的
   `/output/` 改 `/out/`。~~ 单独的 `layout` PR。
4. 修过时内容和整理手册：按模块分 PR，改迁移后的手册。
   - 逐条处理 [发现的过时内容](migration-design-20261114.md#发现的过时内容)。
   - 把夹在手册里的带日期记录拆成过程文档：`maa/daily-tasks-guide.md` 的
     CA bundle 排查和 depot 测试，`guix/storie-network-guide.md` 的 NFS 检查，
     `restricted-network/networks-guide.md` 的旧表迁移，`paseo/broker-guide.md` 的
     2026-10-09 试运行验证，`openclaw/persona-guide.md` 的进度卡片验证，
     `openclaw/testing-guide.md` 的验证计数。
   - 部署命令统一到 `guix/deploy-guide.md` 的写法。
