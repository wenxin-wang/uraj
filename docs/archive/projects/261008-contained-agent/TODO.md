# contained-agent 进度

全部完成。

1. ~~容器、agent spec 和 overlay~~ 已完成。10/08 Claude 和 Codex，275cd6d；10/09 加上
   contain paseo（1e624f0）；10/20 OpenCode 和 Pi，PR #34。
2. ~~Codex 状态持久化~~ 已完成。10/12 overlayfs 和 `contained-sqlite/`，9f2a598；首次启动的
   backfill 见 [codex-state-debug-20261012](codex-state-debug-20261012.md)。
3. ~~凭据和 SOPS 设置~~ 已完成。10/13–10/14，72e534b、cfa7c09、778022e。
4. ~~direnv、coding-style 钩子、版本探测~~ 已完成。10/15，PR #8、#4、#10；见
   [version-probe-debug-20261015](version-probe-debug-20261015.md)。
5. ~~按 worktree 隔离授权和继承策略~~ 已完成。10/16 PR #22；10/17 ba6f572；10/19 PR #32；
   10/22 PR #40、#43；10/23 ede97c2。
6. ~~继承批准~~ 已完成。10/26 PR #52；10/29 PR #63。
7. ~~项目 SSH agent~~ 已完成。10/08 随首个提交，10/09 加长驻的 `ssh-service`；11/01
   broker 共享服务的刷新命令 PR #78。首个提交之后的单独步骤未确认。
8. ~~挂载顺序~~ 已完成。11/04 PR #85。
9. ~~整理 open items~~ 已完成。Paseo 在容器外由
   [paseo-broker](../261008-paseo-broker/TODO.md) 完成；每个 agent 一个 SSH agent 已有；
   容器自有网络加白名单代理未做，要做时另开项目。
