#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/polmira"
PHONES_DIR="$APP_DIR/phones"
SCRIPTS_DIR="$APP_DIR/scripts"
LOGS_DIR="$APP_DIR/logs"
VPN_DIR="$APP_DIR/vpn"
APPS_DIR="$APP_DIR/apps"
BACKUP_DIR="$APP_DIR/backup"
CONFIG_FILE="$APP_DIR/config.env"
BOT_DIR="$APP_DIR/bot"
BOT_ENV_FILE="$BOT_DIR/.env"
BOT_COMPOSE_FILE="$APP_DIR/docker-compose.bot.yml"
WEB_DIR="$APP_DIR/web"
WEB_ENV_FILE="$WEB_DIR/.env"
WEB_COMPOSE_FILE="$APP_DIR/docker-compose.web.yml"
LISTENER_APK_FILE="$APPS_DIR/polmira-listener.apk"
TG_ALLOWED_FILE="$APP_DIR/tg-allowed.txt"
MAX_FILE_SENDERS_FILE="$APP_DIR/max-file-senders.txt"

SELF_PATH="/usr/local/bin/polmira"

NGINX_SITE="/etc/nginx/sites-available/polmira"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/polmira"
NGINX_SNIPPETS_DIR="/etc/nginx/polmira"

ADB_RANGE_START=5556
ADB_RANGE_END=5599
VNC_RANGE_START=5900
VNC_RANGE_END=5999
WEB_RANGE_START=6080
WEB_RANGE_END=6199

SCRCPY_VERSION="3.3.4"
SING_BOX_IMAGE="ghcr.io/sagernet/sing-box:latest"
REDROID_IMAGE="redroid/redroid:11.0.0-latest"
POLMIRA_BOT_IMAGE="chtotos/polmira_bot:latest"
POLMIRA_WEB_IMAGE="chtotos/polmira_web:latest"

DOCKER_NETWORK="polmira-net"
VPN_PROXY_HOST="${VPN_PROXY_HOST:-172.17.0.1}"
VPN_PROXY_PORT="${VPN_PROXY_PORT:-10809}"

PUBLIC_HOST=""
USE_HTTPS="no"
SSL_CERT=""
SSL_KEY=""

SELECTED_PHONE_DIR=""
SELECTED_PHONE_NAME=""
SELECTED_FILE=""
SELECTED_BACKUP_DIR=""

NORMAL='\033[0m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'

say_green() { echo -e "${GREEN}$1${NORMAL}"; }
say_yellow() { echo -e "${YELLOW}$1${NORMAL}"; }
say_red() { echo -e "${RED}$1${NORMAL}"; }

pause() {
    echo
    read -rp "Нажми Enter..." _ || true
}

section() {
    echo
    echo "======================================"
    echo "$1"
    echo "======================================"
}

need_root() {
    if [ "${EUID}" -ne 0 ]; then
        say_red "Запусти через sudo"
        exit 1
    fi
}

exists() {
    command -v "$1" >/dev/null 2>&1
}

systemctl() {
    if [ -f /.dockerenv ] && exists nsenter; then
        command nsenter -t 1 -m -u -i -n -p systemctl "$@"
    else
        command systemctl "$@"
    fi
}

create_dirs() {
    mkdir -p "$APP_DIR" "$PHONES_DIR" "$SCRIPTS_DIR" "$LOGS_DIR" "$VPN_DIR" "$APPS_DIR" "$BACKUP_DIR" "$BOT_DIR" "$WEB_DIR" "$NGINX_SNIPPETS_DIR"
    touch "$TG_ALLOWED_FILE" "$MAX_FILE_SENDERS_FILE" 2>/dev/null || true
}

register_max_file_sender() {
    local tg_id="${1:-}"

    [ -n "$tg_id" ] || return 0
    create_dirs

    if ! grep -Fxq "$tg_id" "$MAX_FILE_SENDERS_FILE" 2>/dev/null; then
        echo "$tg_id" >> "$MAX_FILE_SENDERS_FILE"
    fi
}

tg_is_allowed() {
    local tg_id="${1:-}"

    [ -n "$tg_id" ] || return 1
    create_dirs
    grep -Fxq "$tg_id" "$TG_ALLOWED_FILE"
}

phone_dir_by_tg_id() {
    local tg_id="${1:-}"
    local env_file

    [ -n "$tg_id" ] || return 1

    while IFS= read -r env_file; do
        if grep -Fxq "TG_ID=${tg_id}" "$env_file"; then
            dirname "$env_file"
            return 0
        fi
    done < <(find "$PHONES_DIR" -mindepth 2 -maxdepth 2 -name phone.env 2>/dev/null | sort)

    return 1
}

safe_phone_name_for_tg() {
    local tg_id="$1"
    local base candidate suffix

    base="tg${tg_id}"
    candidate="$base"
    suffix=1

    while [ -d "$PHONES_DIR/$candidate" ]; do
        suffix=$((suffix + 1))
        candidate="${base}${suffix}"
    done

    echo "$candidate"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    PUBLIC_HOST="${PUBLIC_HOST:-}"
    USE_HTTPS="${USE_HTTPS:-no}"
    SSL_CERT="${SSL_CERT:-}"
    SSL_KEY="${SSL_KEY:-}"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
PUBLIC_HOST=${PUBLIC_HOST}
USE_HTTPS=${USE_HTTPS}
SSL_CERT=${SSL_CERT}
SSL_KEY=${SSL_KEY}
EOF
    chmod 600 "$CONFIG_FILE" || true
}

bot_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif exists docker-compose; then
        echo "docker-compose"
    else
        say_red "Docker Compose не найден"
        return 1
    fi
}

write_bot_compose() {
    create_dirs

    cat > "$BOT_COMPOSE_FILE" <<EOF
name: polmira-bot

services:
  polmira-bot:
    image: ${POLMIRA_BOT_IMAGE}
    container_name: polmira-bot
    restart: unless-stopped
    privileged: true
    network_mode: host
    pid: host
    env_file:
      - ${BOT_ENV_FILE}
    environment:
      POLMIRA_BOT_ENV: ${BOT_ENV_FILE}
      POLMIRA_CMD: /usr/local/bin/polmira
      POLMIRA_APP_DIR: ${APP_DIR}
      POLMIRA_USE_SUDO: "no"
    volumes:
      - ${APP_DIR}:${APP_DIR}
      - ${BOT_DIR}:${BOT_DIR}
      - /usr/local/bin/polmira:/usr/local/bin/polmira:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /run/systemd:/run/systemd
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
      - /etc/systemd/system:/etc/systemd/system
      - /etc/nginx:/etc/nginx
      - /dev:/dev
      - /tmp:/tmp
EOF
}

ensure_bot_env() {
    create_dirs

    if [ ! -f "$BOT_ENV_FILE" ]; then
        cat > "$BOT_ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=
TELEGRAM_PROXY=
MAX_DOWNLOAD_PROXY=
POLMIRA_CMD=/usr/local/bin/polmira
POLMIRA_APP_DIR=${APP_DIR}
POLMIRA_USE_SUDO=no
POLMIRA_COMMAND_TIMEOUT=900
TELEGRAM_POLL_TIMEOUT=30
MAX_WATCH_INTERVAL=10
MAX_LOG_LOOKBACK=1800
EOF
        chmod 600 "$BOT_ENV_FILE" || true
    fi

    bot_env_ensure_key TELEGRAM_PROXY ""
    bot_env_ensure_key MAX_DOWNLOAD_PROXY ""
    bot_env_ensure_key MAX_LOG_LOOKBACK "1800"
}

bot_env_ensure_key() {
    local key="$1"
    local default_value="$2"

    if ! grep -qE "^${key}=" "$BOT_ENV_FILE"; then
        echo "${key}=${default_value}" >> "$BOT_ENV_FILE"
        chmod 600 "$BOT_ENV_FILE" || true
    fi
}

bot_env_get() {
    local key="$1"

    ensure_bot_env
    grep -E "^${key}=" "$BOT_ENV_FILE" | tail -n 1 | cut -d= -f2- || true
}

bot_env_set() {
    local key="$1"
    local value="$2"

    ensure_bot_env
    sed -i "/^${key}=/d" "$BOT_ENV_FILE"
    echo "${key}=${value}" >> "$BOT_ENV_FILE"
    chmod 600 "$BOT_ENV_FILE" || true
}

write_web_compose() {
    create_dirs

    cat > "$WEB_COMPOSE_FILE" <<EOF
name: polmira-web

services:
  polmira-web:
    image: ${POLMIRA_WEB_IMAGE}
    container_name: polmira-web
    restart: unless-stopped
    privileged: true
    network_mode: host
    pid: host
    env_file:
      - ${WEB_ENV_FILE}
    environment:
      POLMIRA_APP_DIR: ${APP_DIR}
      POLMIRA_CMD: /usr/local/bin/polmira
      POLMIRA_WEB_HOST: 127.0.0.1
      POLMIRA_WEB_PORT: "8787"
    volumes:
      - ${APP_DIR}:${APP_DIR}
      - /usr/local/bin/polmira:/usr/local/bin/polmira:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - /run/systemd:/run/systemd
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
      - /etc/systemd/system:/etc/systemd/system
      - /etc/nginx:/etc/nginx
      - /dev:/dev
      - /tmp:/tmp
EOF
}

ensure_web_env() {
    create_dirs

    if [ ! -f "$WEB_ENV_FILE" ]; then
        local password
        local listener_secret
        password=$(openssl rand -base64 18 | tr -d '\n')
        listener_secret=$(openssl rand -hex 24 | tr -d '\n')

        cat > "$WEB_ENV_FILE" <<EOF
POLMIRA_WEB_USER=admin
POLMIRA_WEB_PASSWORD=${password}
POLMIRA_LISTENER_SECRET=${listener_secret}
POLMIRA_WEB_COMMAND_TIMEOUT=900
EOF
        chmod 600 "$WEB_ENV_FILE" || true
    fi

    web_env_ensure_key POLMIRA_WEB_USER "admin"
    web_env_ensure_key POLMIRA_LISTENER_SECRET "$(openssl rand -hex 24 | tr -d '\n')"
    web_env_ensure_key POLMIRA_WEB_COMMAND_TIMEOUT "900"
}

web_env_ensure_key() {
    local key="$1"
    local default_value="$2"

    if ! grep -qE "^${key}=" "$WEB_ENV_FILE"; then
        echo "${key}=${default_value}" >> "$WEB_ENV_FILE"
        chmod 600 "$WEB_ENV_FILE" || true
    fi
}

web_env_get() {
    local key="$1"

    ensure_web_env
    grep -E "^${key}=" "$WEB_ENV_FILE" | tail -n 1 | cut -d= -f2- || true
}

web_env_set() {
    local key="$1"
    local value="$2"

    ensure_web_env
    sed -i "/^${key}=/d" "$WEB_ENV_FILE"
    echo "${key}=${value}" >> "$WEB_ENV_FILE"
    chmod 600 "$WEB_ENV_FILE" || true
}

listener_webhook_url() {
    local configured
    configured="$(web_env_get POLMIRA_LISTENER_WEBHOOK_URL || true)"

    if [ -n "$configured" ]; then
        echo "$configured"
        return
    fi

    echo "$(public_base_url)/adminpanel/api/listener/event"
}

ensure_listener_apk() {
    create_dirs
    mkdir -p "$APPS_DIR"

    if [ -f "/app/polmira-listener.apk" ]; then
        cp "/app/polmira-listener.apk" "$LISTENER_APK_FILE"
        chmod 644 "$LISTENER_APK_FILE" || true
        return 0
    fi

    if [ -f "$LISTENER_APK_FILE" ]; then
        return 0
    fi

    return 1
}

configure_listener_for_phone_dir() {
    local phone_dir="$1"

    [ -f "$phone_dir/phone.env" ] || return 1

    source "$phone_dir/phone.env"

    local adb_target webhook secret component current updated
    adb_target="127.0.0.1:${ADB_PORT}"
    webhook="$(listener_webhook_url)"
    secret="$(web_env_get POLMIRA_LISTENER_SECRET)"
    component="ru.polmira.listener/ru.polmira.listener.MaxNotificationListener"

    adb -s "$adb_target" shell am broadcast \
        -a ru.polmira.listener.CONFIGURE \
        -n ru.polmira.listener/.ConfigReceiver \
        --es webhook_url "$webhook" \
        --es secret "$secret" \
        --es phone "$PHONE_NAME" \
        --es target_package ru.oneme.app

    current="$(adb -s "$adb_target" shell settings get secure enabled_notification_listeners 2>/dev/null | tr -d '\r' || true)"
    if [[ "$current" != *"$component"* ]]; then
        if [ -z "$current" ] || [ "$current" = "null" ]; then
            updated="$component"
        else
            updated="${current}:$component"
        fi
        adb -s "$adb_target" shell settings put secure enabled_notification_listeners "$updated" >/dev/null || true
    fi

    adb -s "$adb_target" shell cmd notification allow_listener "$component" >/dev/null 2>&1 || true
}

install_listener_to_phone_dir() {
    local phone_dir="$1"

    [ -f "$phone_dir/phone.env" ] || return 1

    ensure_web_env

    if ! ensure_listener_apk; then
        say_yellow "Polmira Listener APK не найден, пропускаю автоустановку"
        return 0
    fi

    source "$phone_dir/phone.env"

    local adb_target remote_apk
    adb_target="127.0.0.1:${ADB_PORT}"
    remote_apk="/data/local/tmp/polmira-listener.apk"

    wait_phone_ready_by_dir "$phone_dir" || return 1

    echo "Устанавливаю Polmira Listener..."
    adb -s "$adb_target" push "$LISTENER_APK_FILE" "$remote_apk" >/dev/null
    adb -s "$adb_target" shell pm install -r -d -g "$remote_apk" >/dev/null
    adb -s "$adb_target" shell rm -f "$remote_apk" >/dev/null 2>&1 || true

    configure_listener_for_phone_dir "$phone_dir" || true
    say_green "Polmira Listener установлен"
}

install_web_files() {
    create_dirs
    ensure_web_env
    write_web_compose
}

write_adminpanel_nginx_conf() {
    create_dirs

    cat > "${NGINX_SNIPPETS_DIR}/adminpanel.conf" <<EOF
location = /adminpanel {
    return 302 /adminpanel/;
}

location /adminpanel/ {
    proxy_pass http://127.0.0.1:8787/;

    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
EOF

    nginx -t
    systemctl reload nginx
}

start_web_container() {
    local cmd

    install_web_files
    write_adminpanel_nginx_conf
    cmd=$(bot_compose_cmd) || return 1

    $cmd -f "$WEB_COMPOSE_FILE" pull
    docker rm -f polmira-web >/dev/null 2>&1 || true
    $cmd -f "$WEB_COMPOSE_FILE" up -d

    say_green "Web панель запущена"
    echo "URL: $(public_base_url)/adminpanel/"
    echo "Логин: $(web_env_get POLMIRA_WEB_USER)"
    echo "Пароль: $(web_env_get POLMIRA_WEB_PASSWORD)"
    echo "Listener secret: $(web_env_get POLMIRA_LISTENER_SECRET)"
}

configure_web_panel() {
    local user password restart_answer

    section "Настройка web панели"

    install_web_files

    echo "Текущий логин: $(web_env_get POLMIRA_WEB_USER)"
    echo "Listener secret: $(web_env_get POLMIRA_LISTENER_SECRET)"
    read -rp "Новый логин или Enter оставить: " user
    if [ -n "$user" ]; then
        web_env_set POLMIRA_WEB_USER "$user"
    fi

    read -rsp "Новый пароль панели или Enter оставить: " password
    echo
    if [ -n "$password" ]; then
        web_env_set POLMIRA_WEB_PASSWORD "$password"
    fi

    write_adminpanel_nginx_conf

    read -rp "Перезапустить web панель сейчас? [Y/n]: " restart_answer
    if ! [[ "$restart_answer" =~ ^[Nn]$ ]]; then
        start_web_container
    fi
}

install_bot_files() {
    create_dirs
    ensure_bot_env
    write_bot_compose
}

start_bot_container() {
    local cmd

    install_bot_files
    cmd=$(bot_compose_cmd) || return 1

    cd "$APP_DIR"
    $cmd -f "$BOT_COMPOSE_FILE" pull
    docker rm -f polmira-bot >/dev/null 2>&1 || true
    $cmd -f "$BOT_COMPOSE_FILE" up -d
}

restart_bot_container_if_running() {
    if exists docker && docker ps -a --format '{{.Names}}' | grep -Fxq polmira-bot; then
        start_bot_container || true
    fi
}

install_self() {
    local current
    current="$(readlink -f "$0")"

    if [ "$current" != "$SELF_PATH" ]; then
        cp "$current" "$SELF_PATH"
        chmod +x "$SELF_PATH"
        say_green "Команда установлена: $SELF_PATH"
    else
        chmod +x "$SELF_PATH"
    fi
}

find_package() {
    local pkg

    for pkg in "$@"; do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            echo "$pkg"
            return 0
        fi
    done

    return 1
}

fix_phone_permissions() {
    local phone_dir="${1:-}"

    chmod 755 /opt 2>/dev/null || true
    chmod 755 "$APP_DIR" 2>/dev/null || true
    chmod 755 "$PHONES_DIR" 2>/dev/null || true
    chmod 755 "$APPS_DIR" 2>/dev/null || true
    chmod 755 "$BACKUP_DIR" 2>/dev/null || true
    chmod 755 "$NGINX_SNIPPETS_DIR" 2>/dev/null || true

    if [ -n "$phone_dir" ] && [ -d "$phone_dir" ]; then
        chmod 755 "$phone_dir" 2>/dev/null || true
        chmod 755 "$phone_dir/scripts" 2>/dev/null || true
        chmod 755 "$phone_dir/logs" 2>/dev/null || true

        if [ -d "$phone_dir/data" ]; then
            chmod 755 "$phone_dir/data" 2>/dev/null || true
        fi

        if [ -f "$phone_dir/htpasswd" ]; then
            chmod 644 "$phone_dir/htpasswd" 2>/dev/null || true

            if getent group www-data >/dev/null 2>&1; then
                chown root:www-data "$phone_dir/htpasswd" 2>/dev/null || true
            else
                chown root:root "$phone_dir/htpasswd" 2>/dev/null || true
            fi
        fi
    fi
}

fix_all_phone_permissions() {
    local phone_dir
    create_dirs

    for phone_dir in "$PHONES_DIR"/*; do
        [ -d "$phone_dir" ] || continue
        fix_phone_permissions "$phone_dir"
    done
}

preflight() {
    section "Проверка системы"

    if ! exists apt; then
        say_red "Поддерживаются только Debian/Ubuntu"
        exit 1
    fi

    if [ ! -e /dev/kvm ]; then
        say_red "Нет /dev/kvm"
        echo "Попроси провайдера включить nested virtualization / KVM."
        exit 1
    fi

    if ! grep -E '(vmx|svm)' /proc/cpuinfo >/dev/null; then
        say_red "Нет CPU flags vmx/svm"
        echo "Провайдер не пробросил nested virtualization."
        exit 1
    fi

    local ram_mb disk_free
    ram_mb=$(free -m | awk '/Mem:/ {print $2}')
    disk_free=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

    echo "KVM: OK"
    echo "CPU vmx/svm: OK"
    echo "RAM: ${ram_mb} MB"
    echo "DISK FREE: ${disk_free} GB"

    if [ "$ram_mb" -lt 3500 ]; then
        say_yellow "RAM меньше 4 GB. redroid может работать плохо."
    fi

    if [ "$disk_free" -lt 15 ]; then
        say_red "Мало места. Нужно минимум 15 GB."
        exit 1
    fi
}

install_deps() {
    section "Обновление пакетов"
    apt update

    section "Установка зависимостей"

    apt install -y \
        curl wget git python3 python3-pip python3-venv adb xvfb x11vnc novnc websockify \
        netcat-openbsd ffmpeg libsdl2-2.0-0 tar unzip openssl nginx certbot apache2-utils \
        psmisc iproute2 ca-certificates rsync

    if ! exists docker; then
        local docker_pkg
        docker_pkg=$(find_package docker.io docker-ce || true)

        if [ -z "$docker_pkg" ]; then
            say_red "Docker пакет не найден в apt"
            exit 1
        fi

        apt install -y "$docker_pkg"
    fi

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker

    if ! docker compose version >/dev/null 2>&1 && ! exists docker-compose; then
        local compose_pkg
        compose_pkg=$(find_package docker-compose-plugin docker-compose-v2 docker-compose || true)

        if [ -n "$compose_pkg" ]; then
            apt install -y "$compose_pkg"
        else
            say_red "Docker Compose не найден в apt"
            exit 1
        fi
    fi
}

install_scrcpy() {
    section "Установка scrcpy"

    local tmp_dir arch scrcpy_url
    tmp_dir="/tmp/polmira-scrcpy"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    cd "$tmp_dir"

    arch="$(uname -m)"

    if [ "$arch" = "x86_64" ]; then
        scrcpy_url="https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-linux-x86_64-v${SCRCPY_VERSION}.tar.gz"

        if wget -O scrcpy.tar.gz "$scrcpy_url"; then
            tar -xzf scrcpy.tar.gz
            rm -rf /opt/scrcpy
            mv "scrcpy-linux-x86_64-v${SCRCPY_VERSION}" /opt/scrcpy
            ln -sf /opt/scrcpy/scrcpy /usr/local/bin/scrcpy
        else
            say_yellow "Не удалось скачать scrcpy ${SCRCPY_VERSION}, ставлю scrcpy из apt"
            apt install -y scrcpy
        fi
    else
        say_yellow "Архитектура не x86_64, ставлю scrcpy из apt"
        apt install -y scrcpy
    fi

    if ! exists scrcpy; then
        say_red "scrcpy не установлен"
        exit 1
    fi

    scrcpy --version || true
}

install_binderfs_add() {
    cat > "$SCRIPTS_DIR/binderfs-add" <<'PYEOF'
#!/usr/bin/env python3
import fcntl
import struct
import sys

BINDERFS_MAX_NAME = 255
BINDER_CTL_ADD = 0xC1086201

if len(sys.argv) != 2:
    print("usage: binderfs-add <name>")
    sys.exit(1)

name = sys.argv[1].encode("utf-8")

if len(name) > BINDERFS_MAX_NAME:
    print("name too long")
    sys.exit(1)

buf = bytearray(struct.pack("256sII", name, 0, 0))

with open("/dev/binderfs/binder-control", "rb") as f:
    fcntl.ioctl(f, BINDER_CTL_ADD, buf, True)

raw_name, major, minor = struct.unpack("256sII", buf)
print(f"created {sys.argv[1]} major={major} minor={minor}")
PYEOF

    chmod +x "$SCRIPTS_DIR/binderfs-add"
    ln -sf "$SCRIPTS_DIR/binderfs-add" /usr/local/bin/binderfs-add
}

setup_binderfs_now() {
    modprobe binder_linux || true
    mkdir -p /dev/binderfs

    if ! mountpoint -q /dev/binderfs; then
        mount -t binder binder /dev/binderfs
    fi

    [ -e /dev/binderfs/binder ] || binderfs-add binder
    [ -e /dev/binderfs/hwbinder ] || binderfs-add hwbinder
    [ -e /dev/binderfs/vndbinder ] || binderfs-add vndbinder

    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder
}

install_binderfs_service() {
    cat > /etc/systemd/system/polmira-binderfs.service <<'EOF'
[Unit]
Description=Polmira BinderFS
DefaultDependencies=no
After=local-fs.target
Before=docker.service docker.socket containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe binder_linux
ExecStartPre=/bin/mkdir -p /dev/binderfs
ExecStartPre=/bin/sh -c '/bin/mountpoint -q /dev/binderfs || /bin/mount -t binder binder /dev/binderfs'
ExecStartPre=/bin/sh -c '[ -e /dev/binderfs/binder ] || /usr/local/bin/binderfs-add binder'
ExecStartPre=/bin/sh -c '[ -e /dev/binderfs/hwbinder ] || /usr/local/bin/binderfs-add hwbinder'
ExecStartPre=/bin/sh -c '[ -e /dev/binderfs/vndbinder ] || /usr/local/bin/binderfs-add vndbinder'
ExecStartPre=/bin/chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder
ExecStart=/bin/true

[Install]
WantedBy=sysinit.target
EOF

    systemctl daemon-reload
    systemctl enable polmira-binderfs.service >/dev/null 2>&1
}

install_compose_wrapper() {
    create_dirs

    cat > "$SCRIPTS_DIR/polmira-compose" <<'EOF'
#!/usr/bin/env bash
set -e

if docker compose version >/dev/null 2>&1; then
    exec docker compose "$@"
fi

if command -v docker-compose >/dev/null 2>&1; then
    exec docker-compose "$@"
fi

echo "Docker Compose не найден. Установи docker-compose-plugin или docker-compose." >&2
exit 1
EOF

    chmod +x "$SCRIPTS_DIR/polmira-compose"
}

compose_cmd() {
    install_compose_wrapper
    echo "$SCRIPTS_DIR/polmira-compose"
}

ask_nginx_config() {
    load_config

    section "Настройка домена/IP"

    if [ -z "${PUBLIC_HOST:-}" ]; then
        read -rp "Домен или IP для ссылок: " PUBLIC_HOST
    else
        echo "Текущий домен/IP: $PUBLIC_HOST"
        read -rp "Оставить? [Y/n]: " keep_host

        if [[ "$keep_host" =~ ^[Nn]$ ]]; then
            read -rp "Новый домен или IP: " PUBLIC_HOST
        fi
    fi

    if [ -z "$PUBLIC_HOST" ]; then
        say_red "Домен/IP не может быть пустым"
        exit 1
    fi

    echo
    echo "HTTPS нужен только если есть домен и сертификат."
    echo "Для IP обычно выбирай no."
    read -rp "Использовать HTTPS? [y/N]: " https_answer

    if [[ "$https_answer" =~ ^[Yy]$ ]]; then
        USE_HTTPS="yes"

        local default_cert default_key
        default_cert="/etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem"
        default_key="/etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem"

        if [ -f "$default_cert" ] && [ -f "$default_key" ]; then
            SSL_CERT="$default_cert"
            SSL_KEY="$default_key"
        else
            read -rp "Путь к fullchain.pem: " SSL_CERT
            read -rp "Путь к privkey.pem: " SSL_KEY
        fi

        if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
            say_red "Сертификат или ключ не найден"
            exit 1
        fi
    else
        USE_HTTPS="no"
        SSL_CERT=""
        SSL_KEY=""
    fi

    save_config
}

write_nginx_main_config() {
    load_config
    mkdir -p "$NGINX_SNIPPETS_DIR"

    local effective_https effective_cert effective_key default_cert default_key

    effective_https="${USE_HTTPS:-no}"
    effective_cert="${SSL_CERT:-}"
    effective_key="${SSL_KEY:-}"
    default_cert="/etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem"
    default_key="/etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem"

    if [ "$effective_https" != "yes" ] && [ -f "$default_cert" ] && [ -f "$default_key" ]; then
        effective_https="yes"
        effective_cert="$default_cert"
        effective_key="$default_key"
        USE_HTTPS="yes"
        SSL_CERT="$effective_cert"
        SSL_KEY="$effective_key"
        save_config
        say_yellow "Найден Let's Encrypt сертификат, включаю HTTPS для ${PUBLIC_HOST}"
    fi

    if [ "$effective_https" = "yes" ]; then
        cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$polmira_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name ${PUBLIC_HOST};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${PUBLIC_HOST};

    ssl_certificate ${effective_cert};
    ssl_certificate_key ${effective_key};

    client_max_body_size 2G;

    location / {
        return 404;
    }

    include ${NGINX_SNIPPETS_DIR}/*.conf;
}
EOF
    else
        cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$polmira_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name ${PUBLIC_HOST};

    client_max_body_size 2G;

    location / {
        return 404;
    }

    include ${NGINX_SNIPPETS_DIR}/*.conf;
}
EOF
    fi

    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    fix_all_phone_permissions
    nginx -t
    systemctl reload nginx
}

public_base_url() {
    load_config

    if [ "${USE_HTTPS:-no}" = "yes" ]; then
        echo "https://${PUBLIC_HOST}"
    else
        echo "http://${PUBLIC_HOST}"
    fi
}

novnc_url() {
    local web_path="$1"
    local base_url

    base_url=$(public_base_url)
    echo "${base_url}${web_path}"
}

generate_web_path() {
    openssl rand -hex 8 | awk '{print "/polmira/"$1"/"}'
}

set_phone_password_files() {
    local phone_dir="$1"
    local username="$2"
    local password="$3"
    local hash

    hash=$(openssl passwd -apr1 "$password")
    printf "%s:%s\n" "$username" "$hash" > "${phone_dir}/htpasswd"

    fix_phone_permissions "$phone_dir"
}

write_phone_nginx_conf() {
    local phone_name="$1"
    local phone_dir="$2"

    source "${phone_dir}/phone.env"

    cat > "${phone_dir}/nginx.conf" <<EOF
location = ${WEB_PATH} {
    return 302 ${WEB_PATH}vnc.html?autoconnect=1&resize=scale&shared=0&path=${WEB_PATH#/}websockify;
}

location ${WEB_PATH} {
    auth_basic "Polmira ${phone_name}";
    auth_basic_user_file ${phone_dir}/htpasswd;

    proxy_pass http://127.0.0.1:${WEB_PORT}/;

    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
EOF

    ln -sf "${phone_dir}/nginx.conf" "${NGINX_SNIPPETS_DIR}/${phone_name}.conf"

    fix_phone_permissions "$phone_dir"
    nginx -t
    systemctl reload nginx
}

remove_phone_nginx_conf() {
    local phone_name="$1"

    rm -f "${NGINX_SNIPPETS_DIR}/${phone_name}.conf"

    if exists nginx; then
        nginx -t && systemctl reload nginx
    fi
}

find_free_port() {
    local start="$1"
    local end="$2"
    local port used

    for port in $(seq "$start" "$end"); do
        used="no"

        while IFS= read -r env_file; do
            grep -Eq "^(ADB_PORT|VNC_PORT|WEB_PORT)=${port}$" "$env_file" && used="yes"
        done < <(find "$PHONES_DIR" -mindepth 2 -maxdepth 2 -name phone.env 2>/dev/null)

        if [ "$used" = "no" ]; then
            echo "$port"
            return 0
        fi
    done

    return 1
}
find_free_display() {
    local display used

    for display in $(seq 1 99); do
        used="no"

        while IFS= read -r env_file; do
            grep -Eq "^DISPLAY_NUM=${display}$" "$env_file" && used="yes"
        done < <(find "$PHONES_DIR" -mindepth 2 -maxdepth 2 -name phone.env 2>/dev/null)

        if [ "$used" = "no" ]; then
            echo "$display"
            return 0
        fi
    done

    return 1
}
phone_env_set() {
    local phone_dir="$1"
    local key="$2"
    local value="$3"

    touch "$phone_dir/phone.env"
    sed -i "/^${key}=/d" "$phone_dir/phone.env"
    echo "${key}=${value}" >> "$phone_dir/phone.env"
}

ensure_docker_network() {
    if exists docker; then
        docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK" >/dev/null
    fi
}

vpn_is_configured() {
    [ -f "$VPN_DIR/config.json" ]
}

configure_vpn() {
    need_root
    create_dirs

    section "Настройка общего VPN"

    echo "Тип: VLESS Reality через sing-box TUN"
    echo

    local address port uuid public_key short_id server_name fingerprint flow

    read -rp "Server/IP: " address
    read -rp "Port: " port
    read -rp "UUID: " uuid
    read -rp "Reality public key: " public_key
    read -rp "Short ID: " short_id
    read -rp "SNI/serverName: " server_name
    read -rp "Fingerprint [chrome]: " fingerprint
    read -rp "Flow [xtls-rprx-vision или пусто]: " flow

    fingerprint="${fingerprint:-chrome}"

    if [ -z "$address" ] || [ -z "$port" ] || [ -z "$uuid" ] || [ -z "$public_key" ] || [ -z "$server_name" ]; then
        say_red "Поля server/port/uuid/public key/sni обязательны"
        return
    fi

    cat > "$VPN_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "type": "udp",
        "server": "8.8.8.8"
      }
    ],
    "strategy": "ipv4_only",
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singtun0",
      "address": [
        "172.19.0.1/30"
      ],
      "mtu": 1400,
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "${address}/32",
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16"
      ]
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${address}",
      "server_port": ${port},
      "uuid": "${uuid}",
      "flow": "${flow}",
      "tls": {
        "enabled": true,
        "server_name": "${server_name}",
        "reality": {
          "enabled": true,
          "public_key": "${public_key}",
          "short_id": "${short_id}"
        },
        "utls": {
          "enabled": true,
          "fingerprint": "${fingerprint}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": {
      "server": "google"
    },
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_cidr": [
          "${address}/32",
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16"
        ],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
EOF

    chmod 600 "$VPN_DIR/config.json"

    if python3 -m json.tool "$VPN_DIR/config.json" >/dev/null; then
        say_green "VPN config сохранён: $VPN_DIR/config.json"
    else
        say_red "JSON получился битый. Конфиг невалиден."
        return
    fi
}

write_compose() {
    local phone_dir="$1"

    source "$phone_dir/phone.env"

    cat > "$phone_dir/docker-compose.yml" <<EOF
services:
  "${PHONE_NAME}":
    image: ${REDROID_IMAGE}
    container_name: polmira-${PHONE_NAME}
    privileged: true
    ports:
      - "${ADB_PORT}:5555"
    volumes:
      - ${phone_dir}/data:/data
      - /dev/binderfs:/dev/binderfs
      - /dev/kvm:/dev/kvm
    devices:
      - /dev/kvm:/dev/kvm
    networks:
      - polmira-net
    command:
      - androidboot.redroid_gpu_mode=guest
      - androidboot.use_memfd=1
      - androidboot.hardware=redroid
    restart: unless-stopped

networks:
  polmira-net:
    external: true
EOF
}
wait_android_script() {
    local phone_dir="$1"

    cat > "$phone_dir/scripts/wait-ready.sh" <<'EOF'
#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
source ./phone.env

ADB_TARGET="127.0.0.1:${ADB_PORT}"

echo "Ожидание ADB ${ADB_PORT}..."

until nc -z 127.0.0.1 "$ADB_PORT"; do
    sleep 1
done

adb disconnect "$ADB_TARGET" >/dev/null 2>&1 || true
adb connect "$ADB_TARGET" >/dev/null 2>&1 || true

echo "Ожидание Android..."

count=0

while [ "$count" -lt 180 ]; do
    BOOT=$(adb -s "$ADB_TARGET" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)

    if [ "$BOOT" = "1" ]; then
        echo "Android готов"

        VPN_ENABLED="${VPN_ENABLED:-no}"
        VPN_PROXY_HOST="${VPN_PROXY_HOST:-172.17.0.1}"
        VPN_PROXY_PORT="${VPN_PROXY_PORT:-10809}"

        if [ "$VPN_ENABLED" = "yes" ]; then
            echo "Применяю proxy ${VPN_PROXY_HOST}:${VPN_PROXY_PORT}"
            adb -s "$ADB_TARGET" shell settings put global http_proxy "${VPN_PROXY_HOST}:${VPN_PROXY_PORT}" || true
        fi

        exit 0
    fi

    adb connect "$ADB_TARGET" >/dev/null 2>&1 || true
    count=$((count + 1))
    sleep 2
done

echo "Таймаут загрузки Android"
exit 1
EOF

    chmod +x "$phone_dir/scripts/wait-ready.sh"
}

web_script() {
    local phone_dir="$1"

    cat > "$phone_dir/scripts/start-web.sh" <<'EOF'
#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/.."
source ./phone.env

ADB_TARGET="127.0.0.1:${ADB_PORT}"
RES="1080x1920x24"
RUN_DIR="./run"

mkdir -p "$RUN_DIR" logs

kill_pid_file() {
    local file="$1"
    local pid=""

    [ -f "$file" ] || return 0
    pid="$(cat "$file" 2>/dev/null || true)"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$file"
}

cleanup_own_processes() {
    kill_pid_file "$RUN_DIR/websockify.pid"
    kill_pid_file "$RUN_DIR/scrcpy.pid"
    kill_pid_file "$RUN_DIR/x11vnc.pid"
    kill_pid_file "$RUN_DIR/xvfb.pid"

    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
}

wait_adb_device() {
    local state boot count

    echo "Ожидание ADB ${ADB_TARGET}..."

    count=0
    while [ "$count" -lt 90 ]; do
        adb disconnect "$ADB_TARGET" >/dev/null 2>&1 || true
        adb connect "$ADB_TARGET" >/dev/null 2>&1 || true

        state="$(adb -s "$ADB_TARGET" get-state 2>/dev/null || true)"
        boot="$(adb -s "$ADB_TARGET" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"

        if [ "$state" = "device" ] && [ "$boot" = "1" ]; then
            echo "ADB готов: ${ADB_TARGET}"
            return 0
        fi

        echo "ADB пока не готов: state=${state:-none} boot=${boot:-none}"
        sleep 2
        count=$((count + 1))
    done

    echo "ADB не готов: ${ADB_TARGET}"
    return 1
}

ensure_android_container() {
    if nc -z 127.0.0.1 "$ADB_PORT" >/dev/null 2>&1; then
        return 0
    fi

    echo "ADB порт ${ADB_PORT} не слушает, поднимаю Android container..."

    if [ -x /opt/polmira/scripts/polmira-compose ]; then
        /opt/polmira/scripts/polmira-compose up -d
    elif docker compose version >/dev/null 2>&1; then
        docker compose up -d
    else
        docker-compose up -d
    fi
}

trap cleanup_own_processes EXIT

cleanup_own_processes
ensure_android_container
wait_adb_device

Xvfb ":${DISPLAY_NUM}" -screen 0 "$RES" >logs/xvfb.log 2>&1 &
echo $! > "$RUN_DIR/xvfb.pid"
sleep 2

x11vnc \
    -display ":${DISPLAY_NUM}" \
    -forever \
    -nevershared \
    -nopw \
    -noxdamage \
    -rfbport "$VNC_PORT" \
    -listen 127.0.0.1 \
    >logs/x11vnc.log 2>&1 &
echo $! > "$RUN_DIR/x11vnc.pid"

sleep 2

SCRCPY_AUDIO_ARG=""

if scrcpy --help 2>&1 | grep -q -- "--no-audio"; then
    SCRCPY_AUDIO_ARG="--no-audio"
fi

DISPLAY=":${DISPLAY_NUM}" scrcpy \
    -s "$ADB_TARGET" \
    $SCRCPY_AUDIO_ARG \
    --window-title "Android-${PHONE_NAME}" \
    --window-x 0 \
    --window-y 0 \
    --window-width 1080 \
    --window-height 1920 \
    --render-driver=software \
    >logs/scrcpy.log 2>&1 &
echo $! > "$RUN_DIR/scrcpy.pid"

sleep 3

if ! kill -0 "$(cat "$RUN_DIR/scrcpy.pid")" 2>/dev/null; then
    echo "scrcpy сразу упал"
    cat logs/scrcpy.log || true
    exit 1
fi

websockify \
    --web=/usr/share/novnc \
    "$WEB_PORT" \
    "127.0.0.1:${VNC_PORT}" \
    >logs/websockify.log 2>&1 &
echo $! > "$RUN_DIR/websockify.pid"

while true; do
    if ! kill -0 "$(cat "$RUN_DIR/scrcpy.pid")" 2>/dev/null; then
        echo "scrcpy умер, перезапускаю web-service"
        cat logs/scrcpy.log || true
        exit 1
    fi

    if ! kill -0 "$(cat "$RUN_DIR/x11vnc.pid")" 2>/dev/null; then
        echo "x11vnc умер"
        exit 1
    fi

    if ! kill -0 "$(cat "$RUN_DIR/websockify.pid")" 2>/dev/null; then
        echo "websockify умер"
        exit 1
    fi

    sleep 3
done
EOF

    chmod +x "$phone_dir/scripts/start-web.sh"
}
write_systemd_services() {
    local phone_dir="$1"

    source "$phone_dir/phone.env"

    local cmd
    cmd=$(compose_cmd)

    cat > "/etc/systemd/system/polmira-phone-${PHONE_NAME}-init.service" <<EOF
[Unit]
Description=Polmira Phone ${PHONE_NAME} Init
After=polmira-binderfs.service docker.service network-online.target
Requires=polmira-binderfs.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${phone_dir}
ExecStart=${cmd} up -d
ExecStart=${phone_dir}/scripts/wait-ready.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/polmira-phone-${PHONE_NAME}-web.service" <<EOF
[Unit]
Description=Polmira Phone ${PHONE_NAME} Web
After=polmira-phone-${PHONE_NAME}-init.service
Requires=polmira-phone-${PHONE_NAME}-init.service

[Service]
Type=simple
WorkingDirectory=${phone_dir}
ExecStart=${phone_dir}/scripts/start-web.sh
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "polmira-phone-${PHONE_NAME}-init.service" >/dev/null
    systemctl enable "polmira-phone-${PHONE_NAME}-web.service" >/dev/null
}

restart_phone_services() {
    local phone_name="$1"

    systemctl stop "polmira-phone-${phone_name}-web.service" 2>/dev/null || true
    systemctl restart "polmira-phone-${phone_name}-init.service"
    systemctl restart "polmira-phone-${phone_name}-web.service"
}

stop_phone_services() {
    local phone_name="$1"

    systemctl stop "polmira-phone-${phone_name}-web.service" 2>/dev/null || true
    systemctl stop "polmira-phone-${phone_name}-init.service" 2>/dev/null || true
}

compose_down_phone() {
    local phone_dir="$1"

    [ -d "$phone_dir" ] || return 0
    cd "$phone_dir"

    if docker compose version >/dev/null 2>&1; then
        docker compose down || true
    else
        docker-compose down || true
    fi
}

compose_stop_phone() {
    local phone_dir="$1"

    [ -d "$phone_dir" ] || return 0
    cd "$phone_dir"

    if docker compose version >/dev/null 2>&1; then
        docker compose stop || true
    else
        docker-compose stop || true
    fi
}

create_phone_common() {
    local phone_name="$1"
    local tg_id="${2:-}"
    local default_user="${3:-admin}"
    local default_pass="${4:-}"
    local quiet="${5:-no}"

    local phone_dir adb_port vnc_port web_port display_num web_path phone_url

    if [ ! -f "$CONFIG_FILE" ]; then
        say_red "Polmira не установлена. Сначала пункт 1."
        return 1
    fi

    if [ ! -e /dev/kvm ]; then
        say_red "Нет /dev/kvm"
        return 1
    fi

    if [ ! -e /dev/binderfs/binder ] || [ ! -e /dev/binderfs/hwbinder ] || [ ! -e /dev/binderfs/vndbinder ]; then
        setup_binderfs_now
    fi

    if [[ ! "$phone_name" =~ ^[a-zA-Z0-9]+$ ]]; then
        say_red "Только латиница и цифры"
        return 1
    fi

    if [ -n "$tg_id" ] && ! [[ "$tg_id" =~ ^[0-9]+$ ]]; then
        say_red "Telegram ID должен быть числом или пустым"
        return 1
    fi

    phone_dir="$PHONES_DIR/$phone_name"

    if [ -d "$phone_dir" ]; then
        say_red "Телефон уже существует"
        return 1
    fi

    if [ -n "$tg_id" ] && phone_dir_by_tg_id "$tg_id" >/dev/null; then
        say_red "У Telegram ID уже есть телефон"
        return 1
    fi

    adb_port=$(find_free_port "$ADB_RANGE_START" "$ADB_RANGE_END")
    vnc_port=$(find_free_port "$VNC_RANGE_START" "$VNC_RANGE_END")
    web_port=$(find_free_port "$WEB_RANGE_START" "$WEB_RANGE_END")
    display_num=$(find_free_display)
    web_path=$(generate_web_path)
    default_pass="${default_pass:-$(openssl rand -hex 6)}"

    if [ -z "$adb_port" ] || [ -z "$vnc_port" ] || [ -z "$web_port" ] || [ -z "$display_num" ]; then
        say_red "Не удалось подобрать свободные ресурсы"
        return 1
    fi

    mkdir -p "$phone_dir/data" "$phone_dir/logs" "$phone_dir/scripts"

    cat > "$phone_dir/phone.env" <<EOF
PHONE_NAME=${phone_name}
TG_ID=${tg_id}
ADB_PORT=${adb_port}
VNC_PORT=${vnc_port}
WEB_PORT=${web_port}
DISPLAY_NUM=${display_num}
DISPLAY=:${display_num}
WEB_PATH=${web_path}
USERNAME=${default_user}
VPN_ENABLED=no
EOF

    set_phone_password_files "$phone_dir" "$default_user" "$default_pass"
    register_max_file_sender "$tg_id"
    ensure_docker_network
    write_compose "$phone_dir"
    wait_android_script "$phone_dir"
    web_script "$phone_dir"
    write_phone_nginx_conf "$phone_name" "$phone_dir"
    write_systemd_services "$phone_dir"
    fix_phone_permissions "$phone_dir"

    if [ "$quiet" != "yes" ]; then
        echo
        echo "Запускаю телефон. Первый запуск может занять несколько минут..."
    fi

    restart_phone_services "$phone_name"
    wait_phone_web_by_dir "$phone_dir" || return 1

    ensure_listener_apk || true
    install_all_apps_to_phone_dir "$phone_dir" || true

    phone_url=$(novnc_url "$web_path")

    say_green "Телефон создан"
    echo
    echo "Имя: $phone_name"
    echo "Telegram ID: ${tg_id:-не указан}"
    echo "Логин: $default_user"
    echo "Пароль: $default_pass"
    echo "VPN: OFF"
    echo
    echo "Ссылка:"
    echo "$phone_url"
}

create_phone() {
    need_root
    create_dirs
    load_config

    section "Создание телефона"

    local phone_name tg_id default_user default_pass

    read -rp "Имя телефона латиницей/цифрами: " phone_name
    read -rp "Telegram ID владельца или пусто: " tg_id

    default_user="$phone_name"
    default_pass=$(openssl rand -hex 6)

    create_phone_common "$phone_name" "$tg_id" "$default_user" "$default_pass" "no"
}

list_phones() {
    create_dirs
    load_config

    section "Список телефонов"

    local phone_list phone_dir phone_name init_status web_status phone_url i
    mapfile -t phone_list < <(find "$PHONES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ "${#phone_list[@]}" -eq 0 ]; then
        echo "Телефонов нет"
        return
    fi

    i=1

    for phone_dir in "${phone_list[@]}"; do
        phone_name=$(basename "$phone_dir")

        if [ ! -f "$phone_dir/phone.env" ]; then
            echo "[$i] $phone_name — нет phone.env"
            i=$((i + 1))
            continue
        fi

        source "$phone_dir/phone.env"
        VPN_ENABLED="${VPN_ENABLED:-no}"

        init_status=$(systemctl is-active "polmira-phone-${PHONE_NAME}-init.service" 2>/dev/null || true)
        web_status=$(systemctl is-active "polmira-phone-${PHONE_NAME}-web.service" 2>/dev/null || true)
        phone_url=$(novnc_url "$WEB_PATH")

        echo "[$i] $PHONE_NAME"
        echo "    URL: $phone_url"
        echo "    ADB=$ADB_PORT VNC=$VNC_PORT WEB=$WEB_PORT DISPLAY=:$DISPLAY_NUM VPN=$VPN_ENABLED"
        echo "    init=$init_status web=$web_status"

        i=$((i + 1))
    done
}

select_phone() {
    local phone_list i num idx phone_dir

    mapfile -t phone_list < <(find "$PHONES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ "${#phone_list[@]}" -eq 0 ]; then
        say_red "Телефонов нет"
        return 1
    fi

    i=1

    for phone_dir in "${phone_list[@]}"; do
        echo "[$i] $(basename "$phone_dir")"
        i=$((i + 1))
    done

    echo
    read -rp "Номер: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        say_red "Неверный номер"
        return 1
    fi

    idx=$((num - 1))

    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#phone_list[@]}" ]; then
        say_red "Нет такого номера"
        return 1
    fi

    SELECTED_PHONE_DIR="${phone_list[$idx]}"
    SELECTED_PHONE_NAME=$(basename "$SELECTED_PHONE_DIR")
}

start_restart_phone() {
    need_root
    section "Включить / перезагрузить телефон"

    select_phone || return
    fix_phone_permissions "$SELECTED_PHONE_DIR"
    restart_phone_services "$SELECTED_PHONE_NAME"

    say_green "Телефон включён/перезапущен: $SELECTED_PHONE_NAME"
}

stop_phone() {
    need_root
    section "Выключить телефон"

    select_phone || return
    stop_phone_services "$SELECTED_PHONE_NAME"
    compose_stop_phone "$SELECTED_PHONE_DIR"

    say_green "Телефон выключен: $SELECTED_PHONE_NAME"
}

delete_phone() {
    need_root
    section "Удаление телефона"

    select_phone || return

    local phone_dir phone_name ok
    phone_dir="$SELECTED_PHONE_DIR"
    phone_name="$SELECTED_PHONE_NAME"

    if [ -f "$phone_dir/phone.env" ]; then
        source "$phone_dir/phone.env"
    fi

    read -rp "Удалить $phone_name? [y/N]: " ok

    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        echo "Отмена"
        return
    fi

    stop_phone_services "$phone_name"

    systemctl disable "polmira-phone-${phone_name}-web.service" 2>/dev/null || true
    systemctl disable "polmira-phone-${phone_name}-init.service" 2>/dev/null || true

    rm -f "/etc/systemd/system/polmira-phone-${phone_name}-web.service"
    rm -f "/etc/systemd/system/polmira-phone-${phone_name}-init.service"

    systemctl daemon-reload
    systemctl reset-failed

    if [ -d "$phone_dir" ]; then
        cd "$phone_dir"

        if docker compose version >/dev/null 2>&1; then
            docker compose down -v || true
        else
            docker-compose down -v || true
        fi
    fi

    docker rm -f "polmira-${phone_name}" 2>/dev/null || true
    docker rm -f "polmira-${phone_name}-vpn" 2>/dev/null || true

    remove_phone_nginx_conf "$phone_name"
    rm -rf "$phone_dir"

    say_green "Телефон удален"
}

set_phone_password() {
    need_root
    section "Установить пароль"

    select_phone || return

    local phone_dir phone_name new_user new_pass
    phone_dir="$SELECTED_PHONE_DIR"
    phone_name="$SELECTED_PHONE_NAME"

    read -rp "Username: " new_user
    read -rsp "Password: " new_pass
    echo

    if [ -z "$new_user" ] || [ -z "$new_pass" ]; then
        say_red "Username/password не могут быть пустыми"
        return
    fi

    set_phone_password_files "$phone_dir" "$new_user" "$new_pass"

    if [ -f "$phone_dir/phone.env" ]; then
        sed -i "/^USERNAME=/d" "$phone_dir/phone.env"
        echo "USERNAME=${new_user}" >> "$phone_dir/phone.env"
    fi

    nginx -t
    systemctl reload nginx

    say_green "Пароль обновлён для телефона: $phone_name"
}

recreate_phone_with_current_compose() {
    local phone_dir="$1"
    local phone_name="$2"

    stop_phone_services "$phone_name"
    compose_down_phone "$phone_dir"
    docker rm -f "polmira-${phone_name}" 2>/dev/null || true
    docker rm -f "polmira-${phone_name}-vpn" 2>/dev/null || true
    write_compose "$phone_dir"
    write_systemd_services "$phone_dir"
    fix_phone_permissions "$phone_dir"
    restart_phone_services "$phone_name"
    wait_phone_web_by_dir "$phone_dir" || return 1
}

apply_phone_proxy_by_dir() {
    local phone_dir="$1"

    source "$phone_dir/phone.env"

    local adb_target
    adb_target="127.0.0.1:${ADB_PORT}"

    wait_phone_ready_by_dir "$phone_dir" || return 1

    adb -s "$adb_target" shell settings put global http_proxy "${VPN_PROXY_HOST}:${VPN_PROXY_PORT}"
    adb -s "$adb_target" shell settings put global global_http_proxy_host "$VPN_PROXY_HOST" || true
    adb -s "$adb_target" shell settings put global global_http_proxy_port "$VPN_PROXY_PORT" || true
}

clear_phone_proxy_by_dir() {
    local phone_dir="$1"

    source "$phone_dir/phone.env"

    local adb_target
    adb_target="127.0.0.1:${ADB_PORT}"

    wait_phone_ready_by_dir "$phone_dir" || return 1

    adb -s "$adb_target" shell settings put global http_proxy :0 || true
    adb -s "$adb_target" shell settings delete global http_proxy || true
    adb -s "$adb_target" shell settings delete global global_http_proxy_host || true
    adb -s "$adb_target" shell settings delete global global_http_proxy_port || true
}

enable_vpn_for_phone() {
    need_root
    section "Включить VPN для телефона"

    select_phone || return

    phone_env_set "$SELECTED_PHONE_DIR" "VPN_ENABLED" "yes"

    say_yellow "Перезапускаю телефон..."
    restart_phone_services "$SELECTED_PHONE_NAME"

    wait_phone_ready_by_dir "$SELECTED_PHONE_DIR" || return

    apply_phone_proxy_by_dir "$SELECTED_PHONE_DIR" || return

    say_green "VPN/proxy включён для телефона: $SELECTED_PHONE_NAME"
    echo "Proxy: ${VPN_PROXY_HOST}:${VPN_PROXY_PORT}"

    check_phone_ip_by_dir "$SELECTED_PHONE_DIR" || true
}
disable_vpn_for_phone() {
    need_root
    section "Выключить VPN для телефона"

    select_phone || return

    phone_env_set "$SELECTED_PHONE_DIR" "VPN_ENABLED" "no"

    say_yellow "Перезапускаю телефон..."
    restart_phone_services "$SELECTED_PHONE_NAME"

    wait_phone_ready_by_dir "$SELECTED_PHONE_DIR" || return

    clear_phone_proxy_by_dir "$SELECTED_PHONE_DIR" || return

    say_green "VPN/proxy выключен для телефона: $SELECTED_PHONE_NAME"

    check_phone_ip_by_dir "$SELECTED_PHONE_DIR" || true
}
vpn_status() {
    section "Статус VPN"

    if vpn_is_configured; then
        say_green "Глобальный VPN config: есть"
        echo "$VPN_DIR/config.json"
    else
        say_yellow "Глобальный VPN config: не настроен"
    fi

    echo
    list_phones
}

check_phone_ip_by_dir() {
    local phone_dir="$1"

    if [ ! -f "$phone_dir/phone.env" ]; then
        say_red "Нет phone.env"
        return 1
    fi

    source "$phone_dir/phone.env"

    local adb_target ip
    adb_target="127.0.0.1:${ADB_PORT}"

    adb connect "$adb_target" >/dev/null 2>&1 || true

    ip=$(adb -s "$adb_target" shell 'toybox wget -qO- https://api.ipify.org 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null || echo FAIL' 2>/dev/null | tr -d '\r' || true)

    echo "IP телефона ${PHONE_NAME}: ${ip:-FAIL}"
}

check_phone_ip() {
    need_root
    section "Проверить IP телефона"

    select_phone || return
    check_phone_ip_by_dir "$SELECTED_PHONE_DIR" || true
}

migrate_existing_phones() {
    need_root
    create_dirs

    section "Миграция существующих телефонов"

    local phone_dir phone_name changed

    for phone_dir in "$PHONES_DIR"/*; do
        [ -d "$phone_dir" ] || continue
        [ -f "$phone_dir/phone.env" ] || continue

        phone_name=$(basename "$phone_dir")
        changed="no"

        source "$phone_dir/phone.env"

        if ! grep -q '^VPN_ENABLED=' "$phone_dir/phone.env"; then
            echo "VPN_ENABLED=no" >> "$phone_dir/phone.env"
            changed="yes"
        fi

        mkdir -p "$phone_dir/data" "$phone_dir/logs" "$phone_dir/scripts"
        wait_android_script "$phone_dir"
        web_script "$phone_dir"
        write_compose "$phone_dir"
        write_phone_nginx_conf "$phone_name" "$phone_dir"
        write_systemd_services "$phone_dir"
        fix_phone_permissions "$phone_dir"

        if [ "$changed" = "yes" ]; then
            echo "$phone_name: migrated"
        else
            echo "$phone_name: ok"
        fi
    done

    say_green "Миграция завершена"
}

cleanup_broken_nginx_snippets() {
    need_root
    create_dirs

    section "Очистка битых nginx snippets"

    local snippet phone_name target removed
    removed=0

    for snippet in "$NGINX_SNIPPETS_DIR"/*.conf; do
        [ -e "$snippet" ] || continue

        phone_name=$(basename "$snippet" .conf)
        target="$PHONES_DIR/$phone_name"

        if [ ! -d "$target" ] || [ ! -f "$target/phone.env" ]; then
            echo "Удаляю битый snippet: $snippet"
            rm -f "$snippet"
            removed=$((removed + 1))
        fi
    done

    nginx -t
    systemctl reload nginx

    echo "Удалено: $removed"
}

repair_nginx_config() {
    need_root
    create_dirs
    load_config

    section "Ремонт nginx Polmira"

    echo "PUBLIC_HOST=${PUBLIC_HOST:-}"
    echo "USE_HTTPS=${USE_HTTPS:-no}"
    echo "NGINX_SITE=$NGINX_SITE"
    echo "NGINX_SNIPPETS_DIR=$NGINX_SNIPPETS_DIR"
    echo

    migrate_existing_phones || true
    cleanup_broken_nginx_snippets || true
    write_nginx_main_config
    write_adminpanel_nginx_conf || true

    echo
    echo "Snippets:"
    ls -la "$NGINX_SNIPPETS_DIR" || true

    echo
    echo "Пути телефонов:"
    local env_file
    while IFS= read -r env_file; do
        source "$env_file"
        echo "${PHONE_NAME}: $(novnc_url "$WEB_PATH")"
        if nginx -T 2>/dev/null | grep -Fq "location ${WEB_PATH}"; then
            say_green "    nginx location: OK"
        else
            say_red "    nginx location: НЕ НАЙДЕН"
        fi
    done < <(find "$PHONES_DIR" -mindepth 2 -maxdepth 2 -name phone.env 2>/dev/null | sort)

    nginx -t
    systemctl reload nginx
}

wait_phone_ready_by_dir() {
    local phone_dir="$1"

    if [ ! -f "$phone_dir/phone.env" ]; then
        say_red "Нет phone.env"
        return 1
    fi

    source "$phone_dir/phone.env"

    local adb_target boot count
    adb_target="127.0.0.1:${ADB_PORT}"

    echo "Ожидание телефона ${PHONE_NAME}..."

    until nc -z 127.0.0.1 "$ADB_PORT"; do
        sleep 1
    done

    adb disconnect "$adb_target" >/dev/null 2>&1 || true
    adb connect "$adb_target" >/dev/null 2>&1 || true

    count=0

    while [ "$count" -lt 180 ]; do
        boot=$(adb -s "$adb_target" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)

        if [ "$boot" = "1" ]; then
            echo "Android готов"
            return 0
        fi

        adb connect "$adb_target" >/dev/null 2>&1 || true
        count=$((count + 1))
        sleep 2
    done

    say_red "Таймаут загрузки Android"
    return 1
}

wait_phone_web_by_dir() {
    local phone_dir="$1"

    if [ ! -f "$phone_dir/phone.env" ]; then
        say_red "Нет phone.env"
        return 1
    fi

    source "$phone_dir/phone.env"

    local count
    count=0

    echo "Ожидание web/noVNC ${PHONE_NAME} на порту ${WEB_PORT}..."

    while [ "$count" -lt 90 ]; do
        if nc -z 127.0.0.1 "$WEB_PORT" >/dev/null 2>&1; then
            echo "web/noVNC готов: ${WEB_PORT}"
            return 0
        fi

        if ! systemctl is-active "polmira-phone-${PHONE_NAME}-web.service" >/dev/null 2>&1; then
            echo "web-service не активен, перезапускаю..."
            systemctl restart "polmira-phone-${PHONE_NAME}-web.service" || true
        fi

        count=$((count + 1))
        sleep 2
    done

    say_red "Таймаут запуска web/noVNC ${PHONE_NAME}:${WEB_PORT}"
    systemctl status "polmira-phone-${PHONE_NAME}-web.service" --no-pager -l || true
    return 1
}

select_app_file() {
    local files i num idx

    create_dirs

    mapfile -t files < <(app_store_files)

    if [ "${#files[@]}" -eq 0 ]; then
        say_red "Приложений нет."
        echo "Положи APK в папку: $APPS_DIR"
        return 1
    fi

    section "Выбор приложения"

    i=1
    for file in "${files[@]}"; do
        echo "[$i] $(basename "$file")"
        i=$((i + 1))
    done

    echo
    read -rp "Номер: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        say_red "Неверный номер"
        return 1
    fi

    idx=$((num - 1))

    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#files[@]}" ]; then
        say_red "Нет такого номера"
        return 1
    fi

    SELECTED_FILE="${files[$idx]}"
}

app_store_files() {
    create_dirs
    find "$APPS_DIR" -maxdepth 1 -type f \( \
        -iname "*.apk" -o \
        -iname "*.apkm" -o \
        -iname "*.xapk" -o \
        -iname "*.apks" -o \
        -iname "*.zip" \
    \) | sort
}

install_app_file_to_phone_dir() {
    local phone_dir="$1"
    local app_file="$2"

    if [ ! -f "$phone_dir/phone.env" ]; then
        say_red "Нет phone.env"
        return 1
    fi

    if [ ! -f "$app_file" ]; then
        say_red "Файл приложения не найден: $app_file"
        return 1
    fi

    source "$phone_dir/phone.env"

    local adb_target ext tmp_dir install_ok remote_apk
    adb_target="127.0.0.1:${ADB_PORT}"
    ext="${app_file##*.}"
    ext="${ext,,}"
    install_ok="no"

    wait_phone_ready_by_dir "$phone_dir" || return 1

    echo
    echo "Телефон: $PHONE_NAME"
    echo "Приложение: $(basename "$app_file")"
    echo

    case "$ext" in
        apk)
            remote_apk="/data/local/tmp/polmira-install.apk"

            adb -s "$adb_target" push "$app_file" "$remote_apk"
            adb -s "$adb_target" shell pm install -r -d -g "$remote_apk"
            adb -s "$adb_target" shell rm -f "$remote_apk" || true

            install_ok="yes"
            ;;

        apks|xapk|apkm|zip)
            tmp_dir="/tmp/polmira-app-$(openssl rand -hex 4)"
            mkdir -p "$tmp_dir"

            unzip -q "$app_file" -d "$tmp_dir"

            mapfile -t apk_parts < <(find "$tmp_dir" -type f -iname "*.apk" | sort)

            if [ "${#apk_parts[@]}" -eq 0 ]; then
                rm -rf "$tmp_dir"
                say_red "В архиве нет APK файлов"
                return 1
            fi

            echo "Найдено APK частей: ${#apk_parts[@]}"

            adb -s "$adb_target" install-multiple -r -d -g "${apk_parts[@]}"
            install_ok="yes"

            rm -rf "$tmp_dir"
            ;;

        *)
            say_red "Неподдерживаемый файл: $app_file"
            return 1
            ;;
    esac

    if [ "$install_ok" != "yes" ]; then
        say_red "Установка не удалась"
        return 1
    fi

    echo
    echo "Обновляю launcher и web-экран..."

    adb -s "$adb_target" shell cmd package compile -m speed-profile -f -a >/dev/null 2>&1 || true
    adb -s "$adb_target" shell am force-stop com.android.launcher3 >/dev/null 2>&1 || true
    adb -s "$adb_target" shell monkey -p com.android.launcher3 1 >/dev/null 2>&1 || true

    if adb -s "$adb_target" shell pm path ru.polmira.listener >/dev/null 2>&1; then
        echo
        echo "Настраиваю Polmira Listener..."
        configure_listener_for_phone_dir "$phone_dir" || true
    fi

    systemctl restart "polmira-phone-${PHONE_NAME}-web.service" || true

    say_green "Приложение установлено"
}

install_all_apps_to_phone_dir() {
    local phone_dir="$1"
    local app_file failed installed
    local -a app_files

    [ -f "$phone_dir/phone.env" ] || return 1

    source "$phone_dir/phone.env"

    failed=0
    installed=0

    mapfile -t app_files < <(app_store_files)

    if [ "${#app_files[@]}" -eq 0 ]; then
        say_yellow "В $APPS_DIR нет приложений для автоустановки"
        return 0
    fi

    section "Автоустановка приложений из $APPS_DIR"

    for app_file in "${app_files[@]}"; do
        if install_app_file_to_phone_dir "$phone_dir" "$app_file"; then
            installed=$((installed + 1))
        else
            failed=$((failed + 1))
            say_yellow "Не удалось установить: $(basename "$app_file")"
        fi
    done

    echo "Установлено: $installed"
    if [ "$failed" -gt 0 ]; then
        say_yellow "Ошибок установки: $failed"
    fi

    return 0
}

install_app_to_phone() {
    need_root
    create_dirs

    section "Установить приложение"

    echo "Выбери телефон:"
    select_phone || return

    select_app_file || return

    install_app_file_to_phone_dir "$SELECTED_PHONE_DIR" "$SELECTED_FILE"
}

select_backup_folder() {
    local folders i num idx

    create_dirs

    mapfile -t folders < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ "${#folders[@]}" -eq 0 ]; then
        say_red "Папок backup нет."
        echo "Положи папку с data в: $BACKUP_DIR"
        return 1
    fi

    section "Выбор backup"

    i=1
    for folder in "${folders[@]}"; do
        echo "[$i] $(basename "$folder")"
        i=$((i + 1))
    done

    echo
    read -rp "Номер: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        say_red "Неверный номер"
        return 1
    fi

    idx=$((num - 1))

    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#folders[@]}" ]; then
        say_red "Нет такого номера"
        return 1
    fi

    SELECTED_BACKUP_DIR="${folders[$idx]}"
}

clean_redroid_data_after_restore() {
    local target_data="$1"

    rm -rf "$target_data"/misc/bootstat/* 2>/dev/null || true
    rm -rf "$target_data"/system/dropbox/* 2>/dev/null || true
    rm -rf "$target_data"/system/usagestats/* 2>/dev/null || true
    rm -rf "$target_data"/system/package_cache/* 2>/dev/null || true
    rm -rf "$target_data"/dalvik-cache/* 2>/dev/null || true
    rm -rf "$target_data"/resource-cache/* 2>/dev/null || true
    rm -rf "$target_data"/local/tmp/* 2>/dev/null || true

    find "$target_data" -type s -delete 2>/dev/null || true
    find "$target_data" -name "*.lock" -delete 2>/dev/null || true
}

repair_redroid_data_permissions() {
    local target_data="$1"

    chmod 755 "$target_data" 2>/dev/null || true
}

transfer_data_to_phone() {
    need_root
    create_dirs

    section "Перенести информацию"

    echo "Выбери телефон, в который нужно перенести data:"
    select_phone || return

    select_backup_folder || return

    local phone_dir phone_name source_data target_data safety_backup ok ts
    phone_dir="$SELECTED_PHONE_DIR"
    phone_name="$SELECTED_PHONE_NAME"
    target_data="$phone_dir/data"

    if [ -d "$SELECTED_BACKUP_DIR/data" ]; then
        source_data="$SELECTED_BACKUP_DIR/data"
    else
        source_data="$SELECTED_BACKUP_DIR"
    fi

    if [ ! -d "$source_data" ]; then
        say_red "Источник data не найден: $source_data"
        return
    fi

    if [ "$source_data" = "$target_data" ]; then
        say_red "Нельзя переносить data саму в себя"
        return
    fi

    echo
    say_yellow "ВНИМАНИЕ: текущая data телефона будет заменена."
    echo "Телефон: $phone_name"
    echo "Источник: $source_data"
    echo "Куда: $target_data"
    echo
    echo "Перед заменой текущая data будет сохранена в $BACKUP_DIR."
    echo
    read -rp "Продолжить? [y/N]: " ok

    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        echo "Отмена"
        return
    fi

    ts=$(date +%Y%m%d-%H%M%S)
    safety_backup="$BACKUP_DIR/auto-${phone_name}-${ts}"

    echo
    echo "Останавливаю телефон..."
    stop_phone_services "$phone_name"
    compose_down_phone "$phone_dir"
    docker rm -f "polmira-${phone_name}" 2>/dev/null || true
    docker rm -f "polmira-${phone_name}-vpn" 2>/dev/null || true

    echo "Сохраняю текущую data в: $safety_backup"
    mkdir -p "$safety_backup"

    if [ -d "$target_data" ]; then
        rsync -a "$target_data"/ "$safety_backup"/
    fi

    echo "Удаляю старую data..."
    rm -rf "$target_data"
    mkdir -p "$target_data"

    echo "Копирую новую data..."
    rsync -a --delete "$source_data"/ "$target_data"/

    echo "Чищу временные файлы..."
    clean_redroid_data_after_restore "$target_data"

    echo "Исправляю права..."
    repair_redroid_data_permissions "$target_data"

    sync

    fix_phone_permissions "$phone_dir"
    write_compose "$phone_dir"
    write_systemd_services "$phone_dir"

    echo "Запускаю телефон..."
    restart_phone_services "$phone_name"

    say_green "Перенос завершён"
    echo "Автобэкап старой data: $safety_backup"
}

system_check() {
    preflight

    echo
    echo "Docker:"
    docker --version || true
    docker compose version || docker-compose --version || true

    echo
    echo "scrcpy:"
    scrcpy --version || true

    echo
    echo "nginx:"
    nginx -t || true

    echo
    echo "binderfs:"
    ls -la /dev/binderfs 2>/dev/null || true

    echo
    echo "Apps:"
    echo "$APPS_DIR"
    find "$APPS_DIR" -maxdepth 1 -type f 2>/dev/null | sed 's/^/    /' || true

    echo
    echo "Backup:"
    echo "$BACKUP_DIR"
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/^/    /' || true

    echo
    echo "VPN config:"
    if vpn_is_configured; then
        echo "OK: $VPN_DIR/config.json"
    else
        echo "not configured"
    fi

    echo
    echo "Bot:"
    echo "$BOT_ENV_FILE"
    if [ -f "$BOT_ENV_FILE" ]; then
        if [ -n "$(bot_env_get TELEGRAM_BOT_TOKEN)" ]; then
            echo "token: configured"
        else
            echo "token: empty"
        fi
        echo "proxy: $(bot_env_get TELEGRAM_PROXY)"
    else
        echo "not installed"
    fi
    docker ps --filter name=polmira-bot --format '    {{.Names}} {{.Status}}' 2>/dev/null || true
}

configure_bot_token() {
    need_root
    create_dirs
    install_bot_files

    section "Настройка Telegram бота"

    local current_token current_proxy current_max_proxy token proxy max_proxy start_answer keep_token

    current_token=$(bot_env_get TELEGRAM_BOT_TOKEN)
    current_proxy=$(bot_env_get TELEGRAM_PROXY)
    current_max_proxy=$(bot_env_get MAX_DOWNLOAD_PROXY)

    if [ -n "$current_token" ]; then
        echo "Текущий токен: задан"
        read -rp "Оставить токен? [Y/n]: " keep_token
        if [[ "$keep_token" =~ ^[Nn]$ ]]; then
            read -rsp "Новый TELEGRAM_BOT_TOKEN: " token
            echo
            bot_env_set TELEGRAM_BOT_TOKEN "$token"
        fi
    else
        read -rsp "TELEGRAM_BOT_TOKEN или пусто: " token
        echo
        bot_env_set TELEGRAM_BOT_TOKEN "$token"
    fi

    echo
    echo "Текущий TELEGRAM_PROXY: ${current_proxy:-пусто}"
    echo "Пример: http://127.0.0.1:10809"
    read -rp "Новый TELEGRAM_PROXY или Enter оставить: " proxy

    if [ -n "$proxy" ]; then
        bot_env_set TELEGRAM_PROXY "$proxy"
    fi

    echo
    echo "Текущий MAX_DOWNLOAD_PROXY: ${current_max_proxy:-пусто, будет TELEGRAM_PROXY}"
    echo "Пример для скачивания MAX сервером: http://172.17.0.1:10809"
    read -rp "Новый MAX_DOWNLOAD_PROXY или Enter оставить: " max_proxy

    if [ -n "$max_proxy" ]; then
        bot_env_set MAX_DOWNLOAD_PROXY "$max_proxy"
    fi

    install_bot_files

    if [ -n "$(bot_env_get TELEGRAM_BOT_TOKEN)" ]; then
        read -rp "Перезапустить бота сейчас? [Y/n]: " start_answer
        if ! [[ "$start_answer" =~ ^[Nn]$ ]]; then
            start_bot_container
        fi
    else
        say_yellow "Токен пустой. Файлы бота установлены, контейнер не запускаю."
    fi
}

manage_allowed_tg_ids() {
    need_root
    create_dirs

    while true; do
        section "Разрешённые Telegram ID"
        if [ -s "$TG_ALLOWED_FILE" ]; then
            nl -ba "$TG_ALLOWED_FILE"
        else
            echo "Список пуст"
        fi

        echo
        echo "1. Добавить Telegram ID"
        echo "2. Удалить Telegram ID"
        echo "0. Назад"
        echo

        local choice tg_id
        read -rp "Выбор: " choice

        case "$choice" in
            1)
                read -rp "Telegram ID: " tg_id
                if [[ "$tg_id" =~ ^[0-9]+$ ]]; then
                    if ! grep -Fxq "$tg_id" "$TG_ALLOWED_FILE"; then
                        echo "$tg_id" >> "$TG_ALLOWED_FILE"
                    fi
                    register_max_file_sender "$tg_id"
                    say_green "Добавлен: $tg_id"
                else
                    say_red "ID должен быть числом"
                fi
                pause
                ;;
            2)
                read -rp "Telegram ID удалить: " tg_id
                if [[ "$tg_id" =~ ^[0-9]+$ ]]; then
                    sed -i "/^${tg_id}$/d" "$TG_ALLOWED_FILE"
                    sed -i "/^${tg_id}$/d" "$MAX_FILE_SENDERS_FILE"
                    say_green "Удалён: $tg_id"
                else
                    say_red "ID должен быть числом"
                fi
                pause
                ;;
            0) return ;;
            *) echo "Неверный выбор"; pause ;;
        esac
    done
}

install_polmira() {
    need_root

    preflight
    create_dirs
    install_self
    install_deps
    ensure_docker_network
    install_scrcpy
    install_binderfs_add
    setup_binderfs_now
    install_binderfs_service
    ask_nginx_config
    fix_all_phone_permissions
    write_nginx_main_config
    migrate_existing_phones || true
    cleanup_broken_nginx_snippets || true
    install_bot_files
    install_web_files
    write_adminpanel_nginx_conf || true

    if [ -z "$(bot_env_get TELEGRAM_BOT_TOKEN)" ]; then
        say_yellow "Telegram bot token пока пустой."
        echo "Настроить можно через пункт меню: Изменить токен/прокси бота."
    else
        start_bot_container || true
    fi

    start_web_container || true

    say_green "Polmira установлена"
    echo
    echo "Папка для приложений: $APPS_DIR"
    echo "Папка для backup data: $BACKUP_DIR"
    echo "Файл бота: $BOT_ENV_FILE"
    echo "Файл web панели: $WEB_ENV_FILE"
    echo "Web панель: $(public_base_url)/adminpanel/"
}

bot_phone_dir_or_fail() {
    local tg_id="${1:-}"
    local phone_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED" >&2
        return 1
    fi

    phone_dir=$(phone_dir_by_tg_id "$tg_id" || true)

    if [ -z "$phone_dir" ]; then
        say_red "PHONE_NOT_FOUND" >&2
        return 1
    fi

    echo "$phone_dir"
}

bot_phone_info_by_dir() {
    local phone_dir="$1"
    local init_status web_status web_ready phone_url

    source "$phone_dir/phone.env"

    init_status=$(systemctl is-active "polmira-phone-${PHONE_NAME}-init.service" 2>/dev/null || true)
    web_status=$(systemctl is-active "polmira-phone-${PHONE_NAME}-web.service" 2>/dev/null || true)
    web_ready="no"
    if nc -z 127.0.0.1 "$WEB_PORT" >/dev/null 2>&1; then
        web_ready="yes"
    fi
    phone_url=$(novnc_url "$WEB_PATH")

    echo "PHONE_NAME=$PHONE_NAME"
    echo "TG_ID=${TG_ID:-}"
    echo "USERNAME=${USERNAME:-}"
    echo "URL=$phone_url"
    echo "VPN_ENABLED=${VPN_ENABLED:-no}"
    echo "INIT_STATUS=$init_status"
    echo "WEB_STATUS=$web_status"
    echo "WEB_READY=$web_ready"
    echo "WEB_PORT=$WEB_PORT"
}

bot_status() {
    need_root
    create_dirs
    load_config

    local tg_id="${1:-}"
    local phone_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    register_max_file_sender "$tg_id"
    phone_dir=$(phone_dir_by_tg_id "$tg_id" || true)

    if [ -z "$phone_dir" ]; then
        echo "NO_PHONE=1"
        return 0
    fi

    bot_phone_info_by_dir "$phone_dir"
}

bot_create_phone() {
    need_root
    create_dirs
    load_config

    local tg_id="${1:-}"
    local phone_name default_pass phone_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    if phone_dir_by_tg_id "$tg_id" >/dev/null; then
        say_red "PHONE_ALREADY_EXISTS"
        return 1
    fi

    phone_name=$(safe_phone_name_for_tg "$tg_id")
    default_pass=$(openssl rand -hex 6)

    create_phone_common "$phone_name" "$tg_id" "$phone_name" "$default_pass" "yes" || return 1
    phone_dir=$(phone_dir_by_tg_id "$tg_id" || true)

    echo "PASSWORD=$default_pass"
    if [ -n "$phone_dir" ]; then
        bot_phone_info_by_dir "$phone_dir"
    fi
}

bot_start_phone() {
    need_root
    create_dirs

    local phone_dir phone_name
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1
    phone_name=$(basename "$phone_dir")

    fix_phone_permissions "$phone_dir"
    restart_phone_services "$phone_name"
    wait_phone_web_by_dir "$phone_dir" || return 1
    say_green "Телефон включён/перезапущен: $phone_name"
    bot_phone_info_by_dir "$phone_dir"
}

bot_stop_phone() {
    need_root
    create_dirs

    local phone_dir phone_name
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1
    phone_name=$(basename "$phone_dir")

    stop_phone_services "$phone_name"
    compose_stop_phone "$phone_dir"
    say_green "Телефон выключен: $phone_name"
    bot_phone_info_by_dir "$phone_dir"
}

bot_delete_phone() {
    need_root
    create_dirs

    local phone_dir phone_name
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1
    phone_name=$(basename "$phone_dir")

    stop_phone_services "$phone_name"
    systemctl disable "polmira-phone-${phone_name}-web.service" 2>/dev/null || true
    systemctl disable "polmira-phone-${phone_name}-init.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/polmira-phone-${phone_name}-web.service"
    rm -f "/etc/systemd/system/polmira-phone-${phone_name}-init.service"
    systemctl daemon-reload
    systemctl reset-failed
    compose_down_phone "$phone_dir"
    docker rm -f "polmira-${phone_name}" 2>/dev/null || true
    docker rm -f "polmira-${phone_name}-vpn" 2>/dev/null || true
    remove_phone_nginx_conf "$phone_name"
    rm -rf "$phone_dir"

    say_green "Телефон удален"
}

bot_enable_vpn() {
    need_root
    create_dirs

    local phone_dir
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1

    phone_env_set "$phone_dir" "VPN_ENABLED" "yes"
    restart_phone_services "$(basename "$phone_dir")"
    wait_phone_ready_by_dir "$phone_dir" || return 1
    wait_phone_web_by_dir "$phone_dir" || return 1
    apply_phone_proxy_by_dir "$phone_dir" || return 1
    say_green "VPN/proxy включён"
    bot_phone_info_by_dir "$phone_dir"
}

bot_disable_vpn() {
    need_root
    create_dirs

    local phone_dir
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1

    phone_env_set "$phone_dir" "VPN_ENABLED" "no"
    restart_phone_services "$(basename "$phone_dir")"
    wait_phone_ready_by_dir "$phone_dir" || return 1
    wait_phone_web_by_dir "$phone_dir" || return 1
    clear_phone_proxy_by_dir "$phone_dir" || return 1
    say_green "VPN/proxy выключен"
    bot_phone_info_by_dir "$phone_dir"
}

bot_install_app() {
    need_root
    create_dirs

    local phone_dir app_file app_real apps_real
    phone_dir=$(bot_phone_dir_or_fail "${1:-}") || return 1
    app_file="${2:-}"

    if [ -z "$app_file" ] || [ ! -f "$app_file" ]; then
        say_red "Файл приложения не найден"
        return 1
    fi

    app_real=$(readlink -f "$app_file")
    apps_real=$(readlink -f "$APPS_DIR")

    case "$app_real" in
        "$apps_real"/*) ;;
        *)
            say_red "Установка разрешена только из $APPS_DIR"
            return 1
            ;;
    esac

    install_app_file_to_phone_dir "$phone_dir" "$app_real"
}

cli_dispatch() {
    local command="${1:-}"

    case "$command" in
        bot-status) shift; bot_status "$@" ;;
        bot-create-phone) shift; bot_create_phone "$@" ;;
        bot-start-phone) shift; bot_start_phone "$@" ;;
        bot-stop-phone) shift; bot_stop_phone "$@" ;;
        bot-delete-phone) shift; bot_delete_phone "$@" ;;
        bot-enable-vpn) shift; bot_enable_vpn "$@" ;;
        bot-disable-vpn) shift; bot_disable_vpn "$@" ;;
        bot-install-app) shift; bot_install_app "$@" ;;
        *) return 1 ;;
    esac
}

main_menu() {
    while true; do
        clear
        echo "======================================"
        echo " Polmira Android Farm"
        echo "======================================"
        echo
        echo "1. Установить / обновить Polmira"
        echo "2. Создать телефон"
        echo "3. Список телефонов"
        echo "4. Включить / перезагрузить телефон"
        echo "5. Выключить телефон"
        echo "6. Удалить телефон"
        echo "7. Установить пароль"
        echo "8. Проверка системы"
        echo "9. Настроить VPN"
        echo "10. Включить VPN для телефона"
        echo "11. Выключить VPN для телефона"
        echo "12. Статус VPN"
        echo "13. Проверить IP телефона"
        echo "14. Миграция / восстановление телефонов"
        echo "15. Очистить битые nginx snippets"
        echo "16. Установить приложение"
        echo "17. Перенести информацию"
        echo "18. Изменить токен/прокси бота"
        echo "19. Редактировать разрешённые Telegram ID"
        echo "20. Запустить / обновить бота"
        echo "21. Ремонт nginx / ссылок"
        echo "22. Настроить web панель"
        echo "23. Запустить / обновить web панель"
        echo "0. Выход"
        echo

        read -rp "Выбор: " choice

        case "$choice" in
            1) install_polmira; pause ;;
            2) create_phone; pause ;;
            3) list_phones; pause ;;
            4) start_restart_phone; pause ;;
            5) stop_phone; pause ;;
            6) delete_phone; pause ;;
            7) set_phone_password; pause ;;
            8) system_check; pause ;;
            9) configure_vpn; pause ;;
            10) enable_vpn_for_phone; pause ;;
            11) disable_vpn_for_phone; pause ;;
            12) vpn_status; pause ;;
            13) check_phone_ip; pause ;;
            14) migrate_existing_phones; pause ;;
            15) cleanup_broken_nginx_snippets; pause ;;
            16) install_app_to_phone; pause ;;
            17) transfer_data_to_phone; pause ;;
            18) configure_bot_token; pause ;;
            19) manage_allowed_tg_ids; pause ;;
            20) start_bot_container; pause ;;
            21) repair_nginx_config; pause ;;
            22) configure_web_panel; pause ;;
            23) start_web_container; pause ;;
            0) exit 0 ;;
            *) echo "Неверный выбор"; pause ;;
        esac
    done
}

if [ "$#" -gt 0 ]; then
    cli_dispatch "$@" || {
        say_red "Неизвестная команда: $1"
        exit 1
    }
else
    main_menu
fi
