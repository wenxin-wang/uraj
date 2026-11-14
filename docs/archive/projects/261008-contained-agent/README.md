# contained-agent：容器、项目配置和项目 SSH agent

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

在 `guix shell --container` 里运行 Codex、Claude Code、OpenCode 和 Pi，让 agent 只
看到当前项目和必须持久的自身状态；同一个命令既给终端用，也给 Paseo 远程启动。现状见
[overview-guide](../../../contained-agent/overview-guide.md)、
[container-guide](../../../contained-agent/container-guide.md)、
[project-config-guide](../../../contained-agent/project-config-guide.md)、
[agent-specs-guide](../../../contained-agent/agent-specs-guide.md) 和
[ssh-agent-guide](../../../contained-agent/ssh-agent-guide.md)。

## 背景

- 威胁模型是 agent 照着日志、网页或第三方代码里的指令行事（prompt injection），或者
  出于好意做破坏性改动，沙箱不能依赖 agent 配合。
- 9 月底 Codex、Claude Code 先以普通包装进了 Home（48614be 等）；10/08 起改成
  `contained-agent`（275cd6d）。
- 启动 agent 的一侧，daemon 在容器里之后由 broker 接手，见
  [paseo-broker](../261008-paseo-broker/README.md)。

## 主要决定

- 10/08：`contained-agent` 是不依赖 `(guix ...)` 模块的纯 Guile 程序，调用 `guix shell -C`；
  按调用名分派 agent，覆盖层（overlay）加 `persist` 路径让状态可写但不污染主机
  （275cd6d）。
- 10/08：`.git` 的 `hooks/`、`config` 等用只读挂载保护，要求从受保护路径到可写共享
  根的每一级目录都是挂载点（275cd6d）。
- 10/08：项目级 `ssh-agent` 子句和 `contained-ssh.scm` 在首个提交里就有；10/09 起长驻的
  `ssh-service` 给所有会话准备 SSH agent（275cd6d、1e624f0）。首个提交之外的细节未确认。
- 10/12：Codex 的 `~/.codex` 改用 overlayfs 可写，运行时数据库放进持久的
  `contained-sqlite/`，整个目录一起挂，保证 SQLite 的 WAL 和锁（9f2a598）。
- 10/13–10/14：凭据（git 的 HTTPS token、`gh`）和 SOPS 管理的沙箱设置（72e534b、cfa7c09、
  778022e）。
- 10/15：会话里支持 direnv（#8）；对精确的 `--version` 探测绕过容器启动，免得冷 profile
  让 Paseo 把新 Codex 判成太旧（#10）；会话里启用 coding-style 钩子（#4）。
- 10/16：授权按 worktree 隔离（#22）；10/17 未配置的 worktree 继承主 worktree 的策略
  （ba6f572）；10/19 链接 worktree 自动只读暴露主 worktree（#32）；10/23 继承 Paseo
  创建它的来源 checkout 的策略（ede97c2）。
- 10/20：OpenCode 和 Pi 随 Home 安装并由 contained-agent 包装（#34）。
- 10/22：worktree 相对的挂载映射（#40），私有策略文件里可写内联环境变量值（#43）。
- 10/26：新 worktree 的批准在内容相同时沿用来源 worktree 的批准，即继承批准（#52）；
  10/29 替换继承链接改为原子的（#63）。
- 11/04：挂载按顺序排，父目录不能盖住子目录（#85）。
- 11/01：broker 的共享 SSH 服务加 `ssh-refresh`（#78，属于 paseo-broker 一侧的改动）。
- 早期踩过的坑记录在 [pitfalls-debug-20261008](pitfalls-debug-20261008.md)，
  版本探测的坑在 [version-probe-debug-20261015](version-probe-debug-20261015.md)。

## 待定

无。open items 里的 Paseo 在容器外（broker）和项目专用 SSH agent 已完成；容器自己的
网络命名空间加白名单代理没有做，现状是 agent 共用主机网络。

## 文档

- [TODO](TODO.md)：进度。
- [open-items-design-20261012](open-items-design-20261012.md)：当时的待办清单（已过时）。
- [pitfalls-debug-20261008](pitfalls-debug-20261008.md)：早期踩过的坑。
- [version-probe-debug-20261015](version-probe-debug-20261015.md)：Paseo 版本探测的坑。
- [codex-state-debug-20261012](codex-state-debug-20261012.md)：Codex 首次启动的 backfill。
