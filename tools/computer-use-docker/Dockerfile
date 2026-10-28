FROM debian:bookworm-slim

# A tiny computer-use sandbox: a virtual X desktop (Xvfb + a light window
# manager), the X automation tools (xdotool, scrot), a browser to control,
# and Node 22 for the MCP server. No GPU, no systemd; ~1 GB image, runs in
# 512 MB of RAM at idle.

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        xvfb x11-utils x11-xserver-utils xdotool scrot dbus at-spi2-core \
        openbox xterm gtk-3-examples \
        firefox-esr \
        procps tini socat \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# The MCP computer-use server: opensymph/open-computer-use, pinned.
# It is a node CLI; its native app launcher is not used here — we point the
# MCP_STDIO bridge at its node script directly, so no quarantine/exec issues.
WORKDIR /srv/ocu
RUN npm init -y >/dev/null \
    && npm install --no-audit --no-fund --loglevel=error @opensymph/open-computer-use@1.3.0 \
    && chmod -R a-w /srv/ocu/node_modules/@opensymph/open-computer-use

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 1280x800x24 keeps screenshots small and models accurate.
ENV SCREEN_WIDTH=1280 SCREEN_HEIGHT=800 SCREEN_DEPTH=24
ENV MCP_PORT=8766

EXPOSE 8766

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
