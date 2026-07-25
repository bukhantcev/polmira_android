#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/config}"
export USER="${USER:-abc}"
export POLMIRA_USER_HOME="${POLMIRA_USER_HOME:-$HOME}"
export POLMIRA_FILE_WATCHER_STATE="${POLMIRA_FILE_WATCHER_STATE:-$HOME/.cache/polmira-file-watcher.json}"

log_dir="$HOME/.cache/polmira/logs"
mkdir -p "$HOME/Downloads" "$HOME/.local/share/ONEME" "$log_dir"

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ "${POLMIRA_DBUS_SESSION:-}" != "1" ]; then
    export POLMIRA_DBUS_SESSION=1
    exec dbus-run-session -- "$0" "$@"
fi

if ! pgrep -u "$(id -u)" -f 'python3 /usr/local/bin/polmira-notification-daemon' >/dev/null; then
    python3 /usr/local/bin/polmira-notification-daemon \
        >>"$log_dir/notifications.log" 2>&1 &
fi

if ! pgrep -u "$(id -u)" -f 'python3 /usr/local/bin/polmira-file-watcher' >/dev/null; then
    python3 /usr/local/bin/polmira-file-watcher \
        >>"$log_dir/file-watcher.log" 2>&1 &
fi

printf '\n' | gnome-keyring-daemon --login --components=secrets \
    >>"$log_dir/keyring.log" 2>&1 || true

fit_max_window() {
    set +e

    local last_geometry=""
    local last_media_state=""
    local last_media_heartbeat=0
    local media_state_file="$HOME/.cache/polmira/media-state"

    while sleep 0.5; do
        local display_geometry window_id target_height geometry_key
        local active_window active_class
        local candidate_id media_state now window_name window_width

        display_geometry="$(xdotool getdisplaygeometry 2>/dev/null || true)"
        [ -n "$display_geometry" ] || continue
        read -r display_width display_height <<<"$display_geometry"
        target_height=$((display_height - 26))
        [ "$target_height" -gt 0 ] || continue

        window_id=""
        media_state="no"
        while read -r candidate_id; do
            [ -n "$candidate_id" ] || continue
            window_name="$(
                xdotool getwindowname "$candidate_id" 2>/dev/null || true
            )"
            window_width="$(
                xdotool getwindowgeometry --shell "$candidate_id" \
                    2>/dev/null \
                    | sed -n 's/^WIDTH=//p' \
                    | head -n 1
            )"
            [ "${window_width:-0}" -ge 320 ] || continue

            if [ "$window_name" = "MAX" ]; then
                window_id="$candidate_id"
            elif [ "$window_name" = "max" ]; then
                media_state="yes"
            fi
        done < <(
            xdotool search --onlyvisible --class max 2>/dev/null || true
        )

        now="$(date +%s)"
        if [ "$media_state" != "$last_media_state" ] \
            || [ $((now - last_media_heartbeat)) -ge 2 ]; then
            printf '%s\n' "$media_state" > "${media_state_file}.tmp"
            mv -f "${media_state_file}.tmp" "$media_state_file"
            last_media_state="$media_state"
            last_media_heartbeat="$now"
        fi

        [ -n "$window_id" ] || continue

        active_window="$(xdotool getactivewindow 2>/dev/null || true)"
        active_class="$(
            [ -n "$active_window" ] \
                && xprop -id "$active_window" WM_CLASS 2>/dev/null \
                || true
        )"
        if [[ "${active_class,,}" != *'"max"'* ]]; then
            xdotool windowactivate --sync "$window_id" 2>/dev/null || true
        fi

        geometry_key="${window_id}:${display_width}x${target_height}"
        [ "$geometry_key" != "$last_geometry" ] || continue

        xdotool windowmove --sync "$window_id" 0 26 2>/dev/null || continue
        xdotool windowsize --sync \
            "$window_id" "$display_width" "$target_height" 2>/dev/null \
            || continue
        last_geometry="$geometry_key"
    done
}

if [ "${1:-}" = "--window-monitor" ]; then
    fit_max_window
    exit 0
fi

fit_max_window >>"$log_dir/window-fit.log" 2>&1 &

exec /usr/share/max/bin/max >>"$log_dir/max.log" 2>&1
