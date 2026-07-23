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
    exec dbus-run-session -- "$0"
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

exec /usr/share/max/bin/max >>"$log_dir/max.log" 2>&1
