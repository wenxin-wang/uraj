# 子项目三件套模板（2026-11-14）

迁移时放到 `docs/projects/template/`，新项目复制后改名为
`docs/projects/<yymmdd>-<project>/`。`<project>` 用 kebab-case 的语义名，
`<yymmdd>` 是开项目的日期。三个文件的名字固定：`README.md`、`TODO.md`、
`step-<n>-handoff.md`。

## README.md

```markdown
# <项目名>

## 目标

一两句话：做完之后什么事成立。

## 背景

为什么要做；现状和限制。链接相关的模块文档和设计文档，不复述。

## 待定

人定下的事保留问题，划掉后写日期和结论：

- ~~某接口要不要兼容旧格式？~~ 11/02 定：不兼容，一次迁完。
- 仍待定的问题：可选方案、各自代价、建议。

## 文档

- [TODO](TODO.md)：进度。
- [<topic>-design-<yyyymmdd>](<topic>-design-<yyyymmdd>.md)：一句说明。
```

## TODO.md

```markdown
# <项目名> 进度

当前：第 2 步。下一步要人定：<一句话，链到 README 的待定项>。

1. ~~语义名：一句话~~ 已完成。结论：……；数字：……；
   产物：`path/to/file`；PR #123。
2. 语义名：一句话。进行中，见 [step-2-handoff](step-2-handoff.md)。
3. 语义名：一句话。
```

每一步以语义名开头（“1. 去向表：……”），不只写编号。做完的划掉，注明结论、
数字、产物路径和 PR 号。`TODO.md` 是进度的唯一来源，PR 描述和 handoff 链到它，
不各写一份进度。

## step-<n>-handoff.md

```markdown
# 第 <n> 步交接：<语义名>（<yyyy-mm-dd>）

先读：

1. [README](README.md)
2. [TODO](TODO.md)
3. 其他必须读的设计文档

## 现在在哪

| 环节 | 状态 | 代码 |
|---|---|---|
| 某环节 | 已合并（#123） | `src/...` |
| 某环节 | PR #125 draft，等 #124 | 分支 `foo` |
| 某环节 | 未开始 | |

## 下一步

可直接执行的命令，每条说明预期结果：

    git switch -c <branch> origin/main
    guix shell -m manifest.scm -- python3 test/python/uraj/...

## 已知的坑

- 现象、原因、绕法。
```
