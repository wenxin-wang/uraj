# Repair SDK resolution from /app/dist in the locally built v2026.10.3 image.
# Version from upstream extensions/feishu/package.json at
# 59cb44796b0f1f0daa0e37af8b1495abb45d9bc1.
ARG BASE_IMAGE=localhost/openclaw-gateway:2026.10.3
FROM ${BASE_IMAGE}

USER root
# Use a separate dependency tree to avoid rewriting OpenClaw's pnpm install.
RUN npm install --prefix /opt/openclaw-feishu-sdk --omit=dev \
      --no-audit --no-fund --save-exact @larksuiteoapi/node-sdk@1.74.0 \
    && mkdir -p /app/node_modules/@larksuiteoapi \
    && ln -s /opt/openclaw-feishu-sdk/node_modules/@larksuiteoapi/node-sdk \
      /app/node_modules/@larksuiteoapi/node-sdk

# The Podman sandbox backend runs `podman` against the engine's socket.
# Match the engine image's Podman version.
ARG PODMAN_REMOTE_VERSION=5.8.9
ARG PODMAN_REMOTE_SHA256=251efcf491bcae6f324c05380ca23ed4be30bd89cda8db0e1e6d58b0bba2c595
RUN curl -fsSLo /tmp/podman-remote.tar.gz \
      "https://github.com/containers/podman/releases/download/v${PODMAN_REMOTE_VERSION}/podman-remote-static-linux_amd64.tar.gz" \
    && echo "${PODMAN_REMOTE_SHA256}  /tmp/podman-remote.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/podman-remote.tar.gz -C /tmp \
    && install -m 0755 /tmp/bin/podman-remote-static-linux_amd64 /usr/local/bin/podman \
    && rm -rf /tmp/podman-remote.tar.gz /tmp/bin

COPY feishu-topic-chat.mjs /tmp/feishu-topic-chat.mjs
RUN node /tmp/feishu-topic-chat.mjs /app/dist && rm /tmp/feishu-topic-chat.mjs

USER 1000:1000
WORKDIR /app/dist
RUN node --input-type=module -e 'await import("@larksuiteoapi/node-sdk")' \
    && podman --version
WORKDIR /app
