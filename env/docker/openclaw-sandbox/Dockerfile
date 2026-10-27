# OpenClaw tool sandbox, based on upstream scripts/docker/sandbox/Dockerfile,
# plus browser automation for the agent-browser skill.
# UID/GID must match the Guix openclaw-configuration.  The Gateway mounts the
# skill; keep AGENT_BROWSER_VERSION equal to the Guix agent-browser package so
# the CLI serves the matching skill content.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
ARG UID=2010
ARG GID=2010
ARG AGENT_BROWSER_VERSION=0.38.2
ARG AGENT_BROWSER_SHA256=993d462f4dcfc19860d93a6521a452eba4502bfc449fe0120303c2ccb998e675
# Google's pool drops superseded builds: when the download fails, take the
# current Version and SHA256 from dists/stable/main/binary-amd64/Packages.
ARG CHROME_VERSION=156.0.8078.47-1
ARG CHROME_SHA256=6c92cd22e90c6e3e255d782991543fa2091db8614e8536a971a7433a5c4d7ac8
ENV DEBIAN_FRONTEND=noninteractive
# xvfb serves headed Chrome; Mesa and cage are for the GPU rendering
# experiment, which needs trixie's newer Mesa.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 ripgrep procps less file unzip \
      xvfb fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
      libegl1 libgl1-mesa-dri mesa-vulkan-drivers cage \
    && curl -fsSLo /tmp/chrome.deb \
      "https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}_amd64.deb" \
    && echo "${CHROME_SHA256}  /tmp/chrome.deb" | sha256sum -c - \
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm -f /tmp/chrome.deb /etc/apt/sources.list.d/google-chrome.list \
    && curl -fsSLo /usr/local/bin/agent-browser \
      "https://github.com/vercel-labs/agent-browser/releases/download/v${AGENT_BROWSER_VERSION}/agent-browser-linux-musl-x64" \
    && echo "${AGENT_BROWSER_SHA256}  /usr/local/bin/agent-browser" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/agent-browser \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "$GID" sandbox \
    && useradd --uid "$UID" --gid "$GID" --create-home --shell /bin/bash sandbox
USER $UID:$GID
# The root filesystem is read-only; /tmp is the sandbox's writable tmpfs.
# Without DISPLAY, headed Chrome gets a private Xvfb.  Each agent has its own
# sandbox and workspace, hence its own profile and logins.  agent-browser's
# default idle timeout never closes headed browsers, so set one explicitly.
ENV HOME=/tmp \
    LANG=C.UTF-8 \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    AGENT_BROWSER_HEADED=1 \
    AGENT_BROWSER_PROFILE=/workspace/.agent-browser/profile \
    AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
