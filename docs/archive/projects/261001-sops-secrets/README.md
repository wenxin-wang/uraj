# SOPS 秘密

已完成的历史项目，按 `git log` 和迁移前的 `secrets/README.org` 重建；时间线以
提交日期为准，没有提交可查的事实写“未确认”。

## 目标

用 SOPS 管理进仓库的秘密：管理员用 GPG 子钥，各 Guix System 主机用从 SSH host
key 派生的 age identity；agent 用的 GitHub token、沙箱策略和 Paseo 配置也走这条路。
现状见 [sops-guide](../../../secrets/sops-guide.md) 和
[agent-secrets-guide](../../../secrets/agent-secrets-guide.md)。

## 背景

- 服务的密码和 token 不能进 Guix store，也不能明文进公开仓库。
- 主机不应持有管理员私钥，所以主机密文同时给管理员 PGP 和本机 age 作 recipient。

## 主要决定

- 10/01：`.sops.yaml` 和管理员公钥（ae545fc）；`(uraj system secrets)` 的
  `host-sops-services` 和 lappie 接入（5865b9f，见
  [lappie-onboard-deploy-20261001](lappie-onboard-deploy-20261001.md)）。
  三把管理员子钥的验证状态见
  [admin-key-verification-measure-20261001](admin-key-verification-measure-20261001.md)。
- 10/02：storie 接入（9ddc3b6），Immich 数据库密码是第一个业务秘密（db94041，
  见 [rollout-status-deploy-20261002](rollout-status-deploy-20261002.md)）。
- 10/07：hypie 接入（4c6dce8）。
- 10/13：`shared/github.yaml` 三级 GitHub token 和 `scripts/secrets/github_token.py`
  （72e534b）。
- 10/14：contained-agent 和 Paseo 的私有沙箱策略改用 SOPS（cfa7c09、778022e）。
- 10/16：Paseo 的 per-host YAML 配置，激活时合并（638bd14，#19）。
- 10/20：OpenClaw 的飞书凭据和身份（f47d331，#15）。
- 后来 `.sops.yaml` 改用锚点（`&lappie-age` 等），具体提交未确认。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [rollout-status-deploy-20261002](rollout-status-deploy-20261002.md)：SOPS 刚启用时 sops-guide 的状态说明。
- [admin-key-verification-measure-20261001](admin-key-verification-measure-20261001.md)：管理员子钥的验证状态。
- [lappie-onboard-deploy-20261001](lappie-onboard-deploy-20261001.md)：把 lappie 公钥接入 `.sops.yaml` 的过程。
