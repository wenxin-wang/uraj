# 共享的受限网络服务

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

用一个 Guix 服务统一管理 Docker 网桥和 nft 表，限制容器的出站，取代各应用自带的
防火墙规则。现状见 [networks-guide](../../../restricted-network/networks-guide.md)。

## 背景

- redroid 最初带自己的两张表 `inet uraj_redroid` 和 `ip uraj_redroid_nat`（96b3344，10/10）。
  e1e4c79 的提交说明是“reusable restricted workload networks”，把策略和规则生成抽成公共服务；
  其他应用（OpenClaw 沙箱）后来都接入同一个服务。
- 设计起点是 10/14 的 e1e4c79；10/15 以 PR #5 合并（910fadb）。

## 主要决定

- 10/14：服务只管 `restricted_network` 一对表，不碰别的表；旧的 `uraj_redroid` 表由人在停机窗口里
  删除（e1e4c79）。见 [legacy-tables-deploy-20261014](legacy-tables-deploy-20261014.md)。
- 10/15：网络名 `agents` 改为 `static-agent`，`br-agent` 留给以后的 contained-agent 网桥
  （910fadb、2a27c18）。见 [agents-rename-design-20261015](agents-rename-design-20261015.md)。
- 10/15：DNS 可取主机解析快照，`egress-interfaces` 可设为 `#t`（2a27c18）；redroid 的网络记录
  嵌进 `redroid-configuration`（f078ab4）；双栈主机只取 IPv4 的 nameserver（bc00b78，#13）。
- 10/15：可选的 VPN 绕行规则 `vpn-bypass-priority`（d569e92），hypie 在 #14 启用。
- 10/15：运行时模块闭包集中到 `with-uraj-modules`（#12）。
- 10/26：storie 增加 `sandboxed-agents` / `br-sbx-agents` 网络给 OpenClaw 的执行沙箱（29e0548，#48）。

## 待定

无。contained-agent 的 Docker 之外的后端（本服务文档曾提到“future backend”）没有实现；`contained-agent` 会话现在仍共用主机网络的说法未对照代码确认。

## 文档

- [TODO](TODO.md)：进度。
- [agents-rename-design-20261015](agents-rename-design-20261015.md)：`agents` 改名为 `static-agent`。
- [legacy-tables-deploy-20261014](legacy-tables-deploy-20261014.md)：从旧的 redroid 表迁移。
- [validation-measure-20261015](validation-measure-20261015.md)：首次合并时的验证结果。
