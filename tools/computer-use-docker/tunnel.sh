#!/bin/bash
# Self-healing SSH tunnel for the computer-use Docker sandbox on the netcup
# VPS. Forwards 127.0.0.1:8766 (local) -> 127.0.0.1:8766 (remote, inside the
# container's host). Runs forever under a LaunchAgent (see
# com.ompchat.tunnel.plist); also usable interactively or via `install`.
#
#   bash tools/computer-use-docker/tunnel.sh          # run the watchdog loop
#   bash tools/computer-use-docker/tunnel.sh install   # install the LaunchAgent
#   bash tools/computer-use-docker/tunnel.sh uninstall # remove it
#
# Why this exists (docs/computer-use.md VPS section):
#   (a) the netcup ControlMaster socket (/tmp/ssh-cm-netcup) times out after
#       ~30 min idle, and dialing the bare hostname again gets hijacked by
#       fake-ip DNS (198.18.x.x), so every new forward must resolve the raw
#       IP itself from ~/.ssh/config instead of letting ssh look it up.
#   (b) the Mac sleeping silently kills the forward.
# This script re-dials whenever the local port stops answering, with a fixed
# backoff, and logs to a rotated file so a human can tell what happened.

set -u

PORT=8766
SSH_CONFIG="$HOME/.ssh/config"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/ompchat-tunnel.log"
LOG_MAX_BYTES=$((1024 * 1024))
BACKOFF_SECONDS=10
CHECK_INTERVAL_SECONDS=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.ompchat.tunnel.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"
LABEL="com.ompchat.tunnel"

log() {
    mkdir -p "$LOG_DIR"
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -ge "$LOG_MAX_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

# Raw IP and identity file for `Host netcup` from ~/.ssh/config. Resolved by
# hand, not left to ssh's own Host matching, because we dial the raw IP
# directly (this machine's resolver hijacks the hostname to a fake-ip
# 198.18.x.x address) and dialing by IP does not match the `Host netcup`
# block, so IdentityFile would otherwise be silently dropped.
netcup_ip() {
    awk '/^Host[[:space:]]+netcup/{f=1; next} /^Host[[:space:]]/{f=0} f && /HostName/{print $2; exit}' "$SSH_CONFIG"
}

netcup_identity() {
    awk '/^Host[[:space:]]+netcup/{f=1; next} /^Host[[:space:]]/{f=0} f && /IdentityFile/{print $2; exit}' "$SSH_CONFIG"
}

# Kill any existing forward on our exact port, matched by exact command line
# (never a bare `pkill ssh`, which would kill unrelated sessions).
kill_existing_forward() {
    local ip
    ip="$(netcup_ip)"
    local pattern="ssh .*-L 127.0.0.1:${PORT}:127.0.0.1:${PORT} root@${ip}"
    local pids
    pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        log "killing existing forward (pid(s): $pids)"
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        sleep 1
    fi
}

port_is_up() {
    nc -z -w2 127.0.0.1 "$PORT" >/dev/null 2>&1
}

start_forward() {
    local ip identity
    ip="$(netcup_ip)"
    identity="$(netcup_identity)"
    if [ -z "$ip" ]; then
        log "ERROR: could not find HostName for 'Host netcup' in $SSH_CONFIG"
        return 1
    fi
    local identity_args=()
    if [ -n "$identity" ]; then
        identity_args=(-i "${identity/#\~/$HOME}" -o IdentitiesOnly=yes)
    fi
    log "starting forward to root@$ip:$PORT"
    ssh -o ControlMaster=no -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
        "${identity_args[@]}" \
        -f -N -L "127.0.0.1:${PORT}:127.0.0.1:${PORT}" "root@$ip" \
        >>"$LOG_FILE" 2>&1
    local status=$?
    if [ $status -ne 0 ]; then
        log "ssh exited $status while starting forward"
        return 1
    fi
    return 0
}

run_watchdog() {
    log "tunnel watchdog starting (pid $$)"
    kill_existing_forward
    while true; do
        if port_is_up; then
            sleep "$CHECK_INTERVAL_SECONDS"
            continue
        fi
        log "port $PORT down, re-establishing"
        kill_existing_forward
        if start_forward; then
            sleep 2
            if port_is_up; then
                log "forward up"
            else
                log "forward started but port still not answering"
            fi
        fi
        sleep "$BACKOFF_SECONDS"
    done
}

install_agent() {
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s#%%SCRIPT_PATH%%#$SCRIPT_DIR/tunnel.sh#g" \
        -e "s#%%LOG_PATH%%#$LOG_FILE#g" \
        "$PLIST_SRC" > "$PLIST_DEST"
    echo "Installed $PLIST_DEST"
    echo "Run:"
    echo "  launchctl bootstrap gui/\$(id -u) $PLIST_DEST"
    echo "  launchctl enable gui/\$(id -u)/$LABEL"
    echo "  launchctl kickstart -k gui/\$(id -u)/$LABEL"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST_DEST"
    echo "Removed $PLIST_DEST (LaunchAgent unloaded if it was loaded)"
}

case "${1:-}" in
    install)
        install_agent
        ;;
    uninstall)
        uninstall_agent
        ;;
    *)
        run_watchdog
        ;;
esac
