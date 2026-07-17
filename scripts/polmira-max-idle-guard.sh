#!/usr/bin/env bash
set -euo pipefail

INSTANCES_DIR="${POLMIRA_INSTANCES_DIR:-/opt/polmira-docker/instances}"
INTERVAL="${POLMIRA_IDLE_GUARD_INTERVAL:-10}"

has_active_web_client() {
    local port="$1"
    ss -tan 2>/dev/null | awk -v p=":${port}" '
        $1 == "ESTAB" && ($4 ~ p "$" || $5 ~ p "$") { found=1 }
        END { exit found ? 0 : 1 }
    '
}

container_xdo() {
    local container="$1"
    local script="$2"

    docker exec -u polmira "$container" bash -lc "
        set +e
        source /tmp/polmira-session.env 2>/dev/null
        export DISPLAY=\"\${DISPLAY:-:20}\"
        export DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR HOME=/home/polmira USER=polmira
        $script
    " >/dev/null 2>&1 || true
}

minimize_max() {
    local container="$1"
    container_xdo "$container" '
        for w in $(xdotool search --onlyvisible --class max 2>/dev/null); do
            xdotool windowminimize "$w" 2>/dev/null || true
        done
    '
}

restore_max() {
    local container="$1"
    container_xdo "$container" '
        w=$(xdotool search --class max 2>/dev/null | head -n1)
        if [ -n "$w" ]; then
            xdotool windowmap "$w" 2>/dev/null || true
            xdotool windowactivate "$w" 2>/dev/null || true
        fi
    '
}

while true; do
    while IFS= read -r env_file; do
        # shellcheck disable=SC1090
        source "$env_file"
        [ -n "${CONTAINER_NAME:-}" ] && [ -n "${WEB_PORT:-}" ] || continue
        docker inspect -f "{{.State.Running}}" "$CONTAINER_NAME" 2>/dev/null | grep -qx true || continue

        if has_active_web_client "$WEB_PORT"; then
            restore_max "$CONTAINER_NAME"
        else
            minimize_max "$CONTAINER_NAME"
        fi
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    sleep "$INTERVAL"
done
