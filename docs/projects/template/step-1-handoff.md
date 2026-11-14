# 第 1 步交接：<语义名>（<yyyy-mm-dd>）

<!-- 文件名 step-<n>-handoff.md；第 n 步交给下一个 session 时写。 -->

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

```sh
git switch -c <branch> origin/main
python3 test/python/uraj/...
```

## 已知的坑

- 现象、原因、绕法。
