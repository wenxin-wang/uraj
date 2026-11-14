# storie 从旧 paseo 账号切换到 wenxin 的 Home

以下段落原在 [daemon-guide](../../../paseo/daemon-guide.md) 的 Storie 一节和 [relay-guide](../../../paseo/relay-guide.md) 的 Layout 一节，2026-10-09 随 272f58d 写入，原文未改。前四段出自 daemon-guide，最后一段出自 relay-guide。

There is no dedicated `paseo` account declaration, separate Home activation,
old-data migration, or host bind mount for `/home/paseo` or `/workspace`.
The old `/data/paseo` contents are not read, copied, deleted or chowned.

The daemon listens on **storie's address**, port 6767. The old
`172.31.0.7` is unused by this service. Pair clients through the relay; the old
account's connection state is not migrated.

The separate relay service is unchanged at `172.31.0.8:4000`. A macvlan host
cannot directly reach that child, so the new daemon does not inherit the old
private relay environment overrides. Configure
a relay endpoint reachable from the host. Previously issued private-relay
pairing links are not automatically migrated.

The daemon now shares the host network and cannot directly reach this macvlan
child. Direct LAN/VPN access works; relay use requires an endpoint reachable
from the host. Existing private-relay pairing links need reconfiguration.
