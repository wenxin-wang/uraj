# Rootless Podman API for OpenClaw sandboxes, run nested in Docker.
# UID/GID must match the Guix openclaw-configuration.
FROM quay.io/podman/stable:v5.8.9@sha256:55d98815a34b8f796d9bc3130e7ea5eb070ec388c64124d12e876d07df8b7834
ARG UID=2010
ARG GID=2010
USER root
# Without a Docker user namespace, subordinate IDs are real host IDs: keep
# them away from host accounts and the main user's own ranges.
RUN groupmod --gid "$GID" podman \
    && usermod --uid "$UID" --gid "$GID" podman \
    && chown -R "$UID:$GID" /home/podman \
    && printf 'podman:524288:65536\n' > /etc/subuid \
    && cp /etc/subuid /etc/subgid \
    && printf '%s\n' '[engine]' 'cgroup_manager="cgroupfs"' \
      'events_logger="file"' '[containers]' 'cgroups="disabled"' \
      > /etc/containers/openclaw.conf \
    && printf '%s\n' '[storage]' 'driver="vfs"' \
      'graphroot="/home/podman/.local/share/containers/storage"' \
      "runroot=\"/run/user/$UID/storage\"" \
      > /etc/containers/openclaw-storage.conf
ENV HOME=/home/podman \
    XDG_RUNTIME_DIR=/run/user/$UID \
    CONTAINERS_CONF=/etc/containers/openclaw.conf \
    CONTAINERS_STORAGE_CONF=/etc/containers/openclaw-storage.conf
USER $UID:$GID
ENTRYPOINT ["podman", "system", "service", "--time=0", \
            "unix:///run/openclaw-engine/podman.sock"]
