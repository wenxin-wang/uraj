# OpenClaw tool sandbox, based on upstream scripts/docker/sandbox/Dockerfile,
# plus browser automation for the agent-browser skill.
# UID/GID must match the Guix openclaw-configuration.  The Gateway mounts the
# skill; keep AGENT_BROWSER_VERSION equal to the Guix agent-browser package so
# the CLI serves the matching skill content.
FROM docker.io/library/debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
ARG UID=2010
ARG GID=2010
ARG AGENT_BROWSER_VERSION=0.38.2
ARG AGENT_BROWSER_SHA256=993d462f4dcfc19860d93a6521a452eba4502bfc449fe0120303c2ccb998e675
# Source archive for skill-data, which serves `agent-browser skills get`.
ARG AGENT_BROWSER_SOURCE_SHA256=a3a347ed468fcc2e593e3ae95a6a08df1efeb94d57b33fbc48627b889ea0ec48
ENV DEBIAN_FRONTEND=noninteractive
# Debian's chromium follows security updates; builds are not reproducible.
# xvfb serves headed Chromium; Mesa and cage are for the GPU rendering
# experiment, which needs trixie's newer Mesa.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 ripgrep procps less file unzip \
      chromium xvfb fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
      libegl1 libgl1-mesa-dri mesa-vulkan-drivers cage \
    && mkdir -p /opt/agent-browser/bin \
    && curl -fsSLo /opt/agent-browser/bin/agent-browser \
      "https://github.com/vercel-labs/agent-browser/releases/download/v${AGENT_BROWSER_VERSION}/agent-browser-linux-musl-x64" \
    && echo "${AGENT_BROWSER_SHA256}  /opt/agent-browser/bin/agent-browser" | sha256sum -c - \
    && chmod 0755 /opt/agent-browser/bin/agent-browser \
    && curl -fsSLo /tmp/agent-browser.tar.gz \
      "https://github.com/vercel-labs/agent-browser/archive/refs/tags/v${AGENT_BROWSER_VERSION}.tar.gz" \
    && echo "${AGENT_BROWSER_SOURCE_SHA256}  /tmp/agent-browser.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/agent-browser.tar.gz -C /opt/agent-browser --strip-components=1 \
      "agent-browser-${AGENT_BROWSER_VERSION}/skills" \
      "agent-browser-${AGENT_BROWSER_VERSION}/skill-data" \
    && rm /tmp/agent-browser.tar.gz \
    && ln -s /opt/agent-browser/bin/agent-browser /usr/local/bin/agent-browser \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "$GID" sandbox \
    && useradd --uid "$UID" --gid "$GID" --create-home --shell /bin/bash sandbox
COPY browser-profile /usr/local/bin/browser-profile
RUN chmod 0755 /usr/local/bin/browser-profile
USER $UID:$GID
# The root filesystem is read-only; /tmp is the sandbox's writable tmpfs.
# Without DISPLAY, headed Chromium gets a private Xvfb.  Each agent has its own
# sandbox and workspace. browser-profile manages login snapshots and task
# copies there. agent-browser's
# default idle timeout never closes headed browsers, so set one explicitly.
# It adds neither flag below in headed mode: hide navigator.webdriver, which
# remote debugging sets, and allow SwiftShader WebGL without a GPU.
ENV HOME=/tmp \
    LANG=C.UTF-8 \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium \
    AGENT_BROWSER_HEADED=1 \
    AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000 \
    AGENT_BROWSER_ARGS=--disable-blink-features=AutomationControlled,--enable-unsafe-swiftshader
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
