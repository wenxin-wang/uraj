# Paseo daemon 进 Guix 容器 进度

全部完成。

1. ~~打包 Paseo 并装到 lappie~~ 已完成。10/04，c198420。
2. ~~relay 上 storie~~ 已完成。10/04，`paseo-relay` 服务和 `docker-lan` 服务，relay 固定
   到官方仓库的一个 commit，地址 172.31.0.8:4000；同日 e64d873 改了 storie LAN 的名字。
   产物：`src/guix/uraj/services/paseo-relay.scm`、`docker-lan.scm`；提交 062e053。
3. ~~storie 部署 daemon（Guix 系统容器）~~ 已完成。10/05，独立 macvlan 接口 `paseo0`、
   172.31.0.7、`paseo` 账号和 `/data/paseo`；直接提交，没有 PR；9cdfaea。10/09 被第 4 步取代。
4. ~~改成带 `guix shell --container` 的服务~~ 已完成。10/09，lappie 和 storie 都用，
   去掉客户机系统和独立 IP，状态放在目标用户的 `~/.paseo`；272f58d。
   同日 5af0b24 给 storie 加 `host0`，主机因此能访问 relay 的 macvlan。
5. ~~切换现有部署~~ 已完成。切换步骤见
   [daemon-cutover-deploy-20261015](daemon-cutover-deploy-20261015.md)，lappie 的迁移见
   [lappie-migration-deploy-20261009](lappie-migration-deploy-20261009.md)，storie 的见
   [storie-cutover-deploy-20261009](storie-cutover-deploy-20261009.md)。各主机实际切换的
   日期未确认，仓库里没有记录。
6. ~~运行时的小修~~ 已完成。10/10 worktree 目录移到 `~/.local/share/paseo/worktrees`
   （889b2df），foreign distro 上关掉容器服务（c4738d4）；10/12 服务日志（14f814f）、
   Claude 会话历史（762d1cb）；10/13 读 syslog（0d88ed9）、回滚 Claude 对话（f6c1507）；
   10/14 `gh` 访问（af4b1dd）。
7. ~~配置管理~~ 已完成。10/14 daemon 沙箱设置改由 SOPS 管理（cfa7c09、778022e）；
   10/16 公共层和私有层 YAML 在 Home 激活时合并，PR #19。
8. ~~启动顺序~~ 已完成。10/20 等 Home 激活成功再启动，PR #33。
9. ~~附件~~ 已完成。10/21 `~/.paseo/uploads` 只读挂给 contained agent，PR #36；
   daemon 仍在主机上跑时的过渡做法见
   [attachments-host-transition-deploy-20261009](attachments-host-transition-deploy-20261009.md)。
