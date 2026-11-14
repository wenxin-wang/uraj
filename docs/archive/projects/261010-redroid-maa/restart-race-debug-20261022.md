# 重启时容器名冲突

The production container starts automatically under Shepherd.  Its own
Shepherd service, rather than Guix's OCI service, prepares every `docker run`:
it waits for dockerd to answer, builds the layered image if needed, and
removes a container still named `redroid-maa`.  dockerd removes the `--rm`
container of an unclean shutdown only some time after it restarts, and
Guix's OCI stop launches `docker rm -f` without waiting, so `herd restart`
also raced it; both made `docker run` fail on the name.  Stop now waits for
the removal.
