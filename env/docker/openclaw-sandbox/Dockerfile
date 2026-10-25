# OpenClaw tool sandbox, based on upstream scripts/docker/sandbox/Dockerfile.
# UID/GID must match the Guix openclaw-configuration.
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
ARG UID=2010
ARG GID=2010
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 ripgrep procps less file unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "$GID" sandbox \
    && useradd --uid "$UID" --gid "$GID" --create-home --shell /bin/bash sandbox
USER $UID:$GID
# The root filesystem is read-only; /tmp is the sandbox's writable tmpfs.
ENV HOME=/tmp
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
