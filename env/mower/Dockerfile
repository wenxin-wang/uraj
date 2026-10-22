# Source and MaaCore archives are supplied by the Guix build context.
FROM docker.io/library/python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258 AS base
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 PYTHONUNBUFFERED=1 TZ=Asia/Shanghai
RUN apt-get update && apt-get install -y --no-install-recommends \
    adb ca-certificates libzbar0 libglib2.0-0 libgomp1 libatomic1 \
    tzdata util-linux \
    && rm -rf /var/lib/apt/lists/*

FROM docker.io/library/node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS ui
WORKDIR /app/ui
COPY source/ui/package.json source/ui/package-lock.json ./
RUN npm ci
COPY source/ui/ ./
RUN npm run build

FROM base AS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential binutils && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY source/requirements.txt source/requirements.in ./
COPY source/docker/gen_server_requirements.py ./
COPY source/scripts/prune_opencv.py scripts/prune_opencv.py
RUN python gen_server_requirements.py requirements.txt requirements-server.txt \
    && python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --no-deps -r requirements-server.txt \
    && /opt/venv/bin/python scripts/prune_opencv.py

FROM base
ENV PATH="/opt/venv/bin:${PATH}" MOWER_DATA_DIR=/mower-data HOME=/mower-data
WORKDIR /app
COPY --from=dependencies /opt/venv /opt/venv
COPY --from=ui /app/ui/dist ui/dist
COPY source/arknights_mower arknights_mower
COPY source/server.py source/webview_ui.py source/manager.py ./
COPY source/requirements.txt source/requirements.in ./
COPY maa.tar.gz /tmp/maa.tar.gz
RUN mkdir /opt/maa && tar -xzf /tmp/maa.tar.gz -C /opt/maa \
    && rm /tmp/maa.tar.gz && /opt/maa/maa version \
    && ln -s /mower-data/maa-cache /opt/maa/cache
COPY bootstrap.py /app/uraj-bootstrap.py
COPY entrypoint /usr/local/bin/uraj-mower
# Invoked via sh because Guix's store files need not retain executable bits.
ENTRYPOINT ["/bin/sh", "/usr/local/bin/uraj-mower"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:58000/', timeout=3)"
