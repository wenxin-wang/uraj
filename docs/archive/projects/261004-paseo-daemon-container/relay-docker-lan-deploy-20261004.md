# relay 上线时 docker_lan 的接管说明

以下段落原在 [relay-guide](../../../paseo/relay-guide.md) 的 Layout 和 Operation and updates 两节，2026-10-04 随 062e053 写入，原文未改。第一段出自 Layout，第二段出自 Operation and updates。

Both Compose projects now treat the network as external, so removing either
project does not remove the network. Stopping `docker-lan` leaves it intact.

After migration, use the current `/etc/immich/compose` wrapper; an old generation's
Compose file still describes the network as owned by Immich.
