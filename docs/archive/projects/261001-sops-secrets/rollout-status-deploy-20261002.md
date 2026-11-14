# SOPS 首次启用的状态

管理员 GPG recipients 已接入。lappie 和 storie 的系统配置已启用
sops-guix，从各自的 Ed25519 SSH host key 派生 age identity；需要在
目标机器 reconfigure 后生效。storie 已声明 Immich 数据库密码，密文位于
`hosts/storie/immich.yaml`，启动时解密到 `/run/secrets/immich/db-password`
（root 0400）；Immich 等待解密完成后启动。
