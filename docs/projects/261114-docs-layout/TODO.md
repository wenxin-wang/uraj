# 文档布局和协作约定 进度

当前：第 4 步的收尾 PR 等审阅；之后本项目完成。

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
   `/output/` 改 `/out/`。~~ PR #99 已合并。
4. ~~修过时内容和整理手册：按模块分 PR，改迁移后的手册。~~ 做法和历史项目清单见
   [cleanup-design-20261114.md](cleanup-design-20261114.md)。调研和改写由每个模块一个
   便宜模型的 agent 做，本 session 对照代码审查。结论：
   - PR #100（paseo，试用批次）、#101（maa、restricted-network、new-api）、#102（openclaw）、
     #103（contained-agent、desktop、coding-style、config、emacs、playbooks）、
     #104（guix、secrets），全部合并；收尾 PR 统一剩下两处部署命令、术语表链到命令速查。
   - 建了 16 个历史项目，放 `docs/archive/projects/`；`docs/archive/<module>/` 已清空，
     各模块索引末尾有“历史项目”一节。日期取第一个相关提交，和计划里有三处不同：
     `261007-agent-browser`、`261014-restricted-network`、`261015-openclaw-feishu-bot`。
   - `contained-agent/pitfalls-guide.md` 拆掉，仍有效的坑并入对应手册（README 待定 13）。
   - 部署命令以 `guix/deploy-guide.md` 的“命令速查”为准，其他手册链过去。
   - 审查中发现便宜模型的主要问题是删多了：几处排查提示和理由被当成过程删掉，
     审查时恢复。核对过程和档案搬迁基本准确。
   - 没做、留给以后：
     - 长手册的拆分（`paseo/daemon-guide.md`、`contained-agent/project-config-guide.md`、
       `openclaw/feishu-guide.md`）和几处跨手册的重复说明；手册仍保持原语言。
     - 不属于文档的问题：`scripts/redroid/migrate-houdini-data`、`retire-trials` 从未进仓库，
       `test/redroid/retire-trials.sh` 仍引用；`secrets/keys/hosts/` 没有 `storie.age.pub`。
