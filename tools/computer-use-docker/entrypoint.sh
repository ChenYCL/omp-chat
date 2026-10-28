#!/bin/bash
# Starts the virtual desktop, then the pinned computer-use MCP server over
# stdio, bridged to a TCP port by socat so a remote MCP client (OMPChat over
# an SSH tunnel) can reach it. Everything runs as one process group so
# `docker stop` tears the desktop down cleanly.
set -eu

export DISPLAY=:99
# AT-SPI2 (the Linux accessibility layer the server's clicks use) needs a
# session bus; without it every tool call answers
# "missing XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS".
export XDG_RUNTIME_DIR=/tmp/xdg
export NO_AT_BRIDGE=0
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus" 2>/dev/null ||     apt-get install -y -qq dbus >/dev/null 2>&1 && dbus-daemon --session --fork --address="unix:path=$XDG_RUNTIME_DIR/bus"
fi
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
SCREEN="${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}"

# A stale lock survives an unclean stop (docker stop during Xvfb start);
# remove it or Xvfb refuses display :99.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 "$SCREEN" -nolisten tcp &
XVFB_PID=$!

# Wait for the X socket.
for _ in $(seq 1 50); do
    if xset -q >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# The accessibility registry must be running before the X clients start,
# or xterm never appears over AT-SPI and the server sees "no apps".
/usr/libexec/at-spi-bus-launcher --launch-immediately &
sleep 1
openbox &
xsetroot -solid "#1a1a1e"
# A terminal so screenshots show something and clicks have a target.
xterm -geometry 100x30+40+40 -title sandbox-terminal &
xterm -geometry 100x30+560+300 -title scratch &
# A GTK app: only GTK/Qt apps register over AT-SPI (xterm does not), and the
# computer-use server drives the desktop through the accessibility tree.
gtk3-demo-application >/dev/null 2>&1 &

# The computer-use server speaks MCP over stdio. Bridge it to TCP on
# 127.0.0.1 (socat is tiny; the port is only reachable through the SSH
# tunnel because Docker publishes it bound to 127.0.0.1 on the host).
# The npm launcher picks a native per-OS binary; on linux that is a Go
# binary that speaks MCP on stdio and drives X11 directly (no --display
# option; it reads $DISPLAY). The node wrapper stayed silent because it
# execs the binary with the wrong argv on this platform.
OCU_BIN="/srv/ocu/node_modules/@opensymph/open-computer-use/dist/linux/amd64/open-computer-use"
# Bound to 0.0.0.0 inside: docker-proxy connects from the container's
# gateway address, so a 127.0.0.1 bind here is unreachable from the host
# port mapping (that cost a "connection refused" through the SSH tunnel).
# The container port is published on the host bound to 127.0.0.1, so the
# server is still only reachable locally / over the tunnel.
socat TCP-LISTEN:"$MCP_PORT",bind=0.0.0.0,fork,reuseaddr \
    EXEC:"$OCU_BIN mcp",nofork >/dev/null 2>&1 &
SOCAT_PID=$!

shutdown() {
    kill "$SOCAT_PID" 2>/dev/null || true
    kill "$XVFB_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap shutdown TERM INT

wait "$SOCAT_PID"
