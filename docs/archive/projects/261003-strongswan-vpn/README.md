# strongSwan VPN

已完成的历史项目，按 `git log` 和迁移前的文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

在 Guix System 上用 strongSwan 连家里的 IKEv2/EAP 全隧道 VPN（`fwd2home`），
密码等私密字段放 SOPS，公共配置在仓库模板里。现状见
[strongswan-guide](../../../guix/strongswan-guide.md)。

## 背景

- 此前的连接配置是手写草稿，其中的域名、身份和密码需要迁进 SOPS。
- 笔记本休眠、换网络后隧道和 DNS 要能自己恢复；有些网络封了 500/4500，
  需要走服务端 routie 转发的端口。

## 主要决定

- 10/03：首版 `strongswan-services`，公共模板加 SOPS 私密片段，运行时由 swanctl
  合并，同名节以模板为准（eb65493）；已有的完整密文保持可用，见
  [ciphertext-compat-design-20261003](ciphertext-compat-design-20261003.md)。
- 10/06：固定连接服务端 UDP 32495，本地 4500（e5b8f18）。
- 10/07：hypie 声明同样的连接并开机连接（4c6dce8）。
- 10/08：开机连接前等待服务端域名可解析，避免需要 portal 登录的网络上立刻失败
  （d7428c2）。
- 10/13：虚拟 IP 装在 `lo` 上，避免 NetworkManager 在休眠时清掉（a492941）；
  休眠后 DNS 条目的处理见 [dns-after-hibernate-debug-20261003](dns-after-hibernate-debug-20261003.md)。
- 10/22：charon 日志写到 log-readers 可读的文件（46b7e8d）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [ciphertext-compat-design-20261003](ciphertext-compat-design-20261003.md)：兼容已有完整密文的合并方式。
- [dns-after-hibernate-debug-20261003](dns-after-hibernate-debug-20261003.md)：休眠后 DNS 条目消失的解释。
