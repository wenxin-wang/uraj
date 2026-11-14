# relay 上线时 docker_lan 的接管说明

Both Compose projects now treat the network as external, so removing either
project does not remove the network. Stopping `docker-lan` leaves it intact.

After migration, use the current `/etc/immich/compose` wrapper; an old generation's
Compose file still describes the network as owned by Immich.
