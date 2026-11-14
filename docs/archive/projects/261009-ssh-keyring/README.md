# GNOME Keyring 存 SSH 口令

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

桌面上给 SSH 私钥输入过口令后可以记住，由 GNOME Keyring 保存；不启用 GNOME 的 SSH agent，
coding agent 的 `ssh-add -h` 仍然在主机上解密并加载受限的 agent。现状见
[ssh-keyring-guide](../../../desktop/ssh-keyring-guide.md)。

## 背景

- 之前桌面上用 `sshpass` 和 gpg agent 的 SSH 支持（9 月底的若干提交）；项目 SSH agent 需要一个能在
  主机上弹出口令对话框并记住口令的 askpass，见
  [261008-contained-agent](../261008-contained-agent/README.md)。

## 主要决定

- 10/09：引入 `ksshaskpass-with-qtkeychain`（把上游 46c7a429 移植到 Guix 的 ksshaskpass），
  经 libsecret 存进 GNOME Keyring，不是 KWallet；Guix System 上由 greetd 的 PAM 解锁或创建
  `login` keyring；foreign distro 沿用主机的 `gnome-keyring` 并由 playbook 安装
  （044751e）。
- 10/09：Home 禁用旧的 `gnome-keyring-ssh` 自启动并 mask `gcr-ssh-agent`（044751e）。
  迁移时的注意事项见 [migration-deploy-20261009](migration-deploy-20261009.md)。
- 11/09：SSH 登录的 shell 补上桌面会话的 D-Bus 地址（`65-session-bus.sh`），使 `gh` 能从
  keyring 读 token（#93，c2487ea）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [migration-deploy-20261009](migration-deploy-20261009.md)：启用 PAM 登录和旧条目的迁移步骤。
- [validation-measure-20261009](validation-measure-20261009.md)：测试怎么验证的。
