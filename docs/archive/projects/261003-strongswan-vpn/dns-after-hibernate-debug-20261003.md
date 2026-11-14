# 休眠后 DNS 条目的处理

休眠后原 IKE 消失时，插件撤销 DNS 条目是正常清理；重新建立 IKE 并收到
DNS 后会再次注册。DNS 条目消失不应靠长期保留旧 DNS 来掩盖。若隧道
仍是 ESTABLISHED 但条目缺失，则应另查 openresolv/网络管理器更新，不能
仅归因于断线。不保留断开后的 VPN DNS，也不提供断线期间的 kill switch。
