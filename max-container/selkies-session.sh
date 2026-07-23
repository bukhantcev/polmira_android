#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/config}"
export USER="${USER:-abc}"
export POLMIRA_USER_HOME="${POLMIRA_USER_HOME:-$HOME}"
export POLMIRA_FILE_WATCHER_STATE="${POLMIRA_FILE_WATCHER_STATE:-$HOME/.cache/polmira-file-watcher.json}"

log_dir="$HOME/.cache/polmira/logs"
mkdir -p "$HOME/Downloads" "$HOME/.local/share/ONEME" "$log_dir"

python3 /usr/local/bin/polmira-notification-daemon \
    >>"$log_dir/notifications.log" 2>&1 &

python3 /usr/local/bin/polmira-file-watcher \
    >>"$log_dir/file-watcher.log" 2>&1 &

gnome-keyring-daemon --start --components=secrets \
    >>"$log_dir/keyring.log" 2>&1 || true

exec /usr/share/max/bin/max >>"$log_dir/max.log" 2>&1
