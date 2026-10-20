# Repair SDK resolution from /app/dist in the locally built v2026.10.3 image.
# Version from upstream extensions/feishu/package.json at
# 59cb44796b0f1f0daa0e37af8b1495abb45d9bc1.
ARG BASE_IMAGE=localhost/openclaw-feishu:2026.10.3
FROM ${BASE_IMAGE}

USER root
# Use a separate dependency tree to avoid rewriting OpenClaw's pnpm install.
RUN npm install --prefix /opt/openclaw-feishu-sdk --omit=dev \
      --no-audit --no-fund --save-exact @larksuiteoapi/node-sdk@1.74.0 \
    && mkdir -p /app/node_modules/@larksuiteoapi \
    && ln -s /opt/openclaw-feishu-sdk/node_modules/@larksuiteoapi/node-sdk \
      /app/node_modules/@larksuiteoapi/node-sdk

USER 1000:1000
WORKDIR /app/dist
RUN node --input-type=module -e 'await import("@larksuiteoapi/node-sdk")'
WORKDIR /app
