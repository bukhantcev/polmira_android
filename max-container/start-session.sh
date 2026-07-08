#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:20}"
export HOME=/home/polmira
export USER=polmira
export XDG_RUNTIME_DIR=/tmp/runtime-polmira

mkdir -p "$XDG_RUNTIME_DIR" "$HOME/Downloads" "$HOME/.config/openbox" "$HOME/.cache" "$HOME/.local/share/ONEME" /var/log/polmira
chmod 700 "$XDG_RUNTIME_DIR"
chown -R polmira:polmira "$XDG_RUNTIME_DIR" "$HOME/Downloads" "$HOME/.config" "$HOME/.cache" "$HOME/.local" "$HOME/Desktop" /var/log/polmira

if [ "${1:-}" != "--user-session" ]; then
    exec runuser -u polmira -- env \
        DISPLAY="$DISPLAY" \
        HOME="$HOME" \
        USER="$USER" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        TG_ID="${TG_ID:-}" \
        PHONE_NAME="${PHONE_NAME:-}" \
        TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_PROXY="${TELEGRAM_PROXY:-}" \
        POLMIRA_RELAY_URL="${POLMIRA_RELAY_URL:-}" \
        POLMIRA_RELAY_SECRET="${POLMIRA_RELAY_SECRET:-}" \
        RESOLUTION="${RESOLUTION:-1280x720x24}" \
        dbus-run-session -- "$0" --user-session
fi

cleanup() {
    pkill -TERM -P $$ 2>/dev/null || true
}
trap cleanup EXIT

display_num="${DISPLAY#:}"
if [ -n "$display_num" ] && [ -e "/tmp/.X${display_num}-lock" ]; then
    lock_pid="$(tr -dc '0-9' < "/tmp/.X${display_num}-lock" 2>/dev/null || true)"
    if [ -z "$lock_pid" ] || ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "/tmp/.X${display_num}-lock" "/tmp/.X11-unix/X${display_num}" 2>/dev/null || true
    fi
fi

Xvfb "$DISPLAY" -screen 0 "${RESOLUTION:-1280x720x24}" -ac >/var/log/polmira/xvfb.log 2>&1 &
sleep 1

cat > /tmp/polmira-session.env <<EOF
DISPLAY=$DISPLAY
DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}
XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
EOF

gio set "$HOME/Desktop/MAX.desktop" metadata::trusted true >/dev/null 2>&1 || true

openbox >/var/log/polmira/openbox.log 2>&1 &

pcmanfm --desktop >/var/log/polmira/desktop.log 2>&1 &

python3 /usr/local/bin/polmira-notification-daemon >/var/log/polmira/notifications.log 2>&1 &

python3 /usr/local/bin/polmira-file-watcher >/var/log/polmira/file-watcher.log 2>&1 &

gnome-keyring-daemon --start --components=secrets >/var/log/polmira/keyring.log 2>&1 || true

sleep 1

/usr/share/max/bin/max >/var/log/polmira/max.log 2>&1 &

(
    for _ in $(seq 1 20); do
        if xdotool search --onlyvisible --class max >/tmp/polmira-max-windows 2>/dev/null; then
            xdotool windowactivate "$(head -n1 /tmp/polmira-max-windows)" >/dev/null 2>&1 || true
            xdotool mousemove 640 360 >/dev/null 2>&1 || true
            break
        fi
        sleep 1
    done
) >/var/log/polmira/focus.log 2>&1 &

x11vnc -display "$DISPLAY" \
    -forever \
    -shared \
    -xkb \
    -nopw \
    -noxdamage \
    -rfbport 5900 \
    -listen 127.0.0.1 \
    >/var/log/polmira/x11vnc.log 2>&1 &

exec websockify --web=/usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900
