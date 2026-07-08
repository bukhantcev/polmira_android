#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/polmira-linux"
USERS_DIR="$APP_DIR/users"
SCRIPTS_DIR="$APP_DIR/scripts"
LOGS_DIR="$APP_DIR/logs"
CONFIG_FILE="$APP_DIR/config.env"
TG_ALLOWED_FILE="$APP_DIR/tg-allowed.txt"
NGINX_SITE="/etc/nginx/sites-available/polmira-linux"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/polmira-linux"
NGINX_SNIPPETS_DIR="/etc/nginx/polmira-linux"

DISPLAY_RANGE_START=20
DISPLAY_RANGE_END=99
VNC_RANGE_START=5920
VNC_RANGE_END=5999
WEB_RANGE_START=6120
WEB_RANGE_END=6199

PUBLIC_HOST=""
USE_HTTPS="no"
SSL_CERT=""
SSL_KEY=""

NORMAL='\033[0m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'

say_green() { echo -e "${GREEN}$1${NORMAL}"; }
say_yellow() { echo -e "${YELLOW}$1${NORMAL}"; }
say_red() { echo -e "${RED}$1${NORMAL}"; }

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
    mkdir -p "$APP_DIR" "$USERS_DIR" "$SCRIPTS_DIR" "$LOGS_DIR" "$NGINX_SNIPPETS_DIR"
    touch "$TG_ALLOWED_FILE" 2>/dev/null || true
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
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
    echo "$(public_base_url)${web_path}"
}

tg_is_allowed() {
    local tg_id="${1:-}"

    [ -n "$tg_id" ] || return 1
    create_dirs
    grep -Fxq "$tg_id" "$TG_ALLOWED_FILE"
}

safe_linux_user_for_tg() {
    local tg_id="$1"
    echo "pm_${tg_id}" | tr -cd 'A-Za-z0-9_'
}

user_dir_by_tg_id() {
    local tg_id="${1:-}"
    local env_file

    [ -n "$tg_id" ] || return 1

    while IFS= read -r env_file; do
        if grep -Fxq "TG_ID=${tg_id}" "$env_file"; then
            dirname "$env_file"
            return 0
        fi
    done < <(find "$USERS_DIR" -mindepth 2 -maxdepth 2 -name user.env 2>/dev/null | sort)

    return 1
}

user_env_set() {
    local user_dir="$1"
    local key="$2"
    local value="$3"

    touch "$user_dir/user.env"
    sed -i "/^${key}=/d" "$user_dir/user.env"
    echo "${key}=${value}" >> "$user_dir/user.env"
}

find_free_port() {
    local start="$1"
    local end="$2"
    local port used

    for port in $(seq "$start" "$end"); do
        used="no"

        while IFS= read -r env_file; do
            grep -Eq "^(VNC_PORT|WEB_PORT)=${port}$" "$env_file" && used="yes"
        done < <(find "$USERS_DIR" -mindepth 2 -maxdepth 2 -name user.env 2>/dev/null)

        if [ "$used" = "no" ] && ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
            echo "$port"
            return 0
        fi
    done

    return 1
}

find_free_display() {
    local display used

    for display in $(seq "$DISPLAY_RANGE_START" "$DISPLAY_RANGE_END"); do
        used="no"

        while IFS= read -r env_file; do
            grep -Eq "^DISPLAY_NUM=${display}$" "$env_file" && used="yes"
        done < <(find "$USERS_DIR" -mindepth 2 -maxdepth 2 -name user.env 2>/dev/null)

        if [ "$used" = "no" ] && [ ! -e "/tmp/.X${display}-lock" ]; then
            echo "$display"
            return 0
        fi
    done

    return 1
}

generate_web_path() {
    openssl rand -hex 8 | awk '{print "/polmira/"$1"/"}'
}

write_nginx_main_config() {
    load_config
    mkdir -p "$NGINX_SNIPPETS_DIR"

    if [ -z "$PUBLIC_HOST" ]; then
        say_red "PUBLIC_HOST пустой. Сначала настрой домен."
        return 1
    fi

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
    fi

    if [ "$effective_https" = "yes" ]; then
        cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$polmira_linux_connection_upgrade {
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
map \$http_upgrade \$polmira_linux_connection_upgrade {
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
    nginx -t
    systemctl reload nginx
}

write_user_nginx_conf() {
    local user_dir="$1"

    # shellcheck disable=SC1091
    source "$user_dir/user.env"

    cat > "$user_dir/nginx.conf" <<EOF
location = ${WEB_PATH} {
    return 302 ${WEB_PATH}vnc.html?autoconnect=1&resize=scale&shared=0&path=${WEB_PATH#/}websockify;
}

location ${WEB_PATH} {
    auth_basic "Polmira Linux ${LINUX_USER}";
    auth_basic_user_file ${user_dir}/htpasswd;

    proxy_pass http://127.0.0.1:${WEB_PORT}/;

    proxy_http_version 1.1;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_linux_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
}
EOF

    ln -sf "$user_dir/nginx.conf" "${NGINX_SNIPPETS_DIR}/${LINUX_USER}.conf"
    nginx -t
    systemctl reload nginx
}

remove_user_nginx_conf() {
    local linux_user="$1"

    rm -f "${NGINX_SNIPPETS_DIR}/${linux_user}.conf"
    nginx -t && systemctl reload nginx
}

set_access_password_files() {
    local user_dir="$1"
    local username="$2"
    local password="$3"
    local hash

    hash=$(openssl passwd -apr1 "$password")
    printf "%s:%s\n" "$username" "$hash" > "$user_dir/htpasswd"
    chmod 755 "$APP_DIR" "$USERS_DIR" "$user_dir" 2>/dev/null || true
    chmod 644 "$user_dir/htpasswd" || true
}

ensure_user_runtime_dir() {
    local linux_user="$1"
    local uid
    local runtime_dir

    uid="$(id -u "$linux_user" 2>/dev/null || true)"
    [ -n "$uid" ] || return 1

    runtime_dir="/run/user/$uid"
    mkdir -p "$runtime_dir" || return 1
    chown "$linux_user:$linux_user" "$runtime_dir" || true
    chmod 700 "$runtime_dir" || true
    printf "%s\n" "$runtime_dir"
}

write_desktop_shortcut() {
    local linux_user="$1"
    local home_dir
    local desktop_file
    local runtime_dir
    home_dir="$(getent passwd "$linux_user" | cut -d: -f6)"
    desktop_file="$home_dir/Desktop/MAX.desktop"

    [ -n "$home_dir" ] || return 0
    mkdir -p "$home_dir/Desktop" "$home_dir/Downloads"

    if [ -f /usr/share/applications/max.desktop ]; then
        cp /usr/share/applications/max.desktop "$desktop_file"
    else
        cat > "$desktop_file" <<'EOF'
[Desktop Entry]
Type=Application
Name=MAX
Comment=Запустить MAX
Exec=/usr/share/max/bin/max %U
Icon=/usr/share/pixmaps/max.png
Terminal=false
Categories=Network;InstantMessaging;
EOF
    fi

    chmod +x "$desktop_file" || true
    chown -R "$linux_user:$linux_user" "$home_dir/Desktop" "$home_dir/Downloads" || true

    if exists gio; then
        runtime_dir="$(ensure_user_runtime_dir "$linux_user" 2>/dev/null || true)"
        if exists dbus-run-session; then
            runuser -u "$linux_user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
                dbus-run-session gio set "$desktop_file" metadata::trusted true >/dev/null 2>&1 || true
        else
            runuser -u "$linux_user" -- env XDG_RUNTIME_DIR="$runtime_dir" \
                gio set "$desktop_file" metadata::trusted true >/dev/null 2>&1 || true
        fi
    fi
}

install_max_for_user() {
    local linux_user="$1"

    ensure_max_package
    write_desktop_shortcut "$linux_user"
    say_green "MAX установлен/проверен для ${linux_user}"
}

ensure_max_package() {
    need_root

    if exists max || dpkg -s max >/dev/null 2>&1; then
        return 0
    fi

    if ! exists gpg; then
        apt update
        apt install -y gnupg ca-certificates curl
    fi

    mkdir -p /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/max.gpg ]; then
        curl -fsSL https://download.max.ru/linux/deb/public.asc | gpg --dearmor -o /etc/apt/keyrings/max.gpg
    fi

    cat > /etc/apt/sources.list.d/max.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/max.gpg] https://download.max.ru/linux/deb stable main
EOF

    apt update
    apt install -y max
}

write_session_script() {
    cat > "$SCRIPTS_DIR/start-session.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

USER_DIR="$1"
cd "$USER_DIR"

source ./user.env

RUN_DIR="./run"
mkdir -p "$RUN_DIR" logs

USER_UID="$(id -u "$LINUX_USER")"
RUNTIME_DIR="/run/user/$USER_UID"
mkdir -p "$RUNTIME_DIR"
chown "$LINUX_USER:$LINUX_USER" "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true

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
    kill_pid_file "$RUN_DIR/x11vnc.pid"
    kill_pid_file "$RUN_DIR/desktop.pid"
    kill_pid_file "$RUN_DIR/wm.pid"
    kill_pid_file "$RUN_DIR/xvfb.pid"
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
}

run_as_user() {
    runuser -u "$LINUX_USER" -- env XDG_RUNTIME_DIR="$RUNTIME_DIR" "$@"
}

run_as_user_display() {
    runuser -u "$LINUX_USER" -- env XDG_RUNTIME_DIR="$RUNTIME_DIR" DISPLAY=":${DISPLAY_NUM}" "$@"
}

choose_window_manager() {
    if command -v openbox >/dev/null 2>&1; then
        echo "openbox"
    elif command -v fluxbox >/dev/null 2>&1; then
        echo "fluxbox"
    elif command -v startxfce4 >/dev/null 2>&1; then
        echo "startxfce4"
    elif command -v xterm >/dev/null 2>&1; then
        echo "xterm"
    else
        echo ""
    fi
}

trap cleanup_own_processes EXIT
cleanup_own_processes

RES="${RESOLUTION:-1280x720x24}"

run_as_user Xvfb ":${DISPLAY_NUM}" -screen 0 "$RES" -ac >logs/xvfb.log 2>&1 &
echo $! > "$RUN_DIR/xvfb.pid"
sleep 2

WM="$(choose_window_manager)"

if [ -n "$WM" ]; then
    run_as_user_display "$WM" >logs/wm.log 2>&1 &
    echo $! > "$RUN_DIR/wm.pid"
else
    echo "Window manager не найден. Поставь openbox или fluxbox." >logs/wm.log
fi

sleep 1

if command -v pcmanfm >/dev/null 2>&1; then
    run_as_user_display pcmanfm --desktop >logs/desktop.log 2>&1 &
    echo $! > "$RUN_DIR/desktop.pid"
fi

sleep 1

run_as_user x11vnc \
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

websockify \
    --web=/usr/share/novnc \
    "$WEB_PORT" \
    "127.0.0.1:${VNC_PORT}" \
    >logs/websockify.log 2>&1 &
echo $! > "$RUN_DIR/websockify.pid"

while true; do
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

    chmod +x "$SCRIPTS_DIR/start-session.sh"
}

write_user_service() {
    local user_dir="$1"

    # shellcheck disable=SC1091
    source "$user_dir/user.env"

    cat > "/etc/systemd/system/polmira-linux-${LINUX_USER}.service" <<EOF
[Unit]
Description=Polmira Linux desktop for ${LINUX_USER}
After=network.target

[Service]
Type=simple
ExecStart=${SCRIPTS_DIR}/start-session.sh ${user_dir}
Restart=always
RestartSec=3
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "polmira-linux-${LINUX_USER}.service" >/dev/null
}

create_linux_user_record() {
    local tg_id="$1"
    local linux_user="$2"
    local access_user="$3"
    local access_pass="$4"
    local user_dir="$USERS_DIR/$linux_user"
    local display_num vnc_port web_port web_path

    display_num=$(find_free_display)
    vnc_port=$(find_free_port "$VNC_RANGE_START" "$VNC_RANGE_END")
    web_port=$(find_free_port "$WEB_RANGE_START" "$WEB_RANGE_END")
    web_path=$(generate_web_path)

    mkdir -p "$user_dir"
    chmod 755 "$APP_DIR" "$USERS_DIR" "$user_dir" 2>/dev/null || true

    cat > "$user_dir/user.env" <<EOF
TG_ID=${tg_id}
LINUX_USER=${linux_user}
USERNAME=${access_user}
DISPLAY_NUM=${display_num}
VNC_PORT=${vnc_port}
WEB_PORT=${web_port}
WEB_PATH=${web_path}
RESOLUTION=1280x720x24
EOF

    chmod 600 "$user_dir/user.env"
    set_access_password_files "$user_dir" "$access_user" "$access_pass"
}

create_linux_user() {
    need_root
    create_dirs
    load_config

    local tg_id="$1"
    local linux_user access_pass user_dir

    if [ -z "$tg_id" ]; then
        say_red "TG_ID пустой"
        return 1
    fi

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    if user_dir_by_tg_id "$tg_id" >/dev/null; then
        say_red "USER_ALREADY_EXISTS"
        return 1
    fi

    linux_user=$(safe_linux_user_for_tg "$tg_id")
    access_pass=$(openssl rand -hex 6)

    if ! id "$linux_user" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$linux_user"
    fi

    create_linux_user_record "$tg_id" "$linux_user" "$linux_user" "$access_pass"
    user_dir="$USERS_DIR/$linux_user"
    write_desktop_shortcut "$linux_user"
    install_max_for_user "$linux_user" || true
    write_session_script
    write_user_service "$user_dir"
    write_user_nginx_conf "$user_dir"
    systemctl restart "polmira-linux-${linux_user}.service"

    echo "PASSWORD=$access_pass"
    linux_user_info_by_dir "$user_dir"
}

linux_user_info_by_dir() {
    local user_dir="$1"
    local service_status web_ready user_url

    # shellcheck disable=SC1091
    source "$user_dir/user.env"

    service_status=$(systemctl is-active "polmira-linux-${LINUX_USER}.service" 2>/dev/null || true)
    web_ready="no"
    if nc -z 127.0.0.1 "$WEB_PORT" >/dev/null 2>&1; then
        web_ready="yes"
    fi
    user_url=$(novnc_url "$WEB_PATH")

    echo "PHONE_NAME=$LINUX_USER"
    echo "LINUX_USER=$LINUX_USER"
    echo "TG_ID=${TG_ID:-}"
    echo "USERNAME=${USERNAME:-}"
    echo "URL=$user_url"
    echo "VPN_ENABLED=no"
    echo "INIT_STATUS=$service_status"
    echo "WEB_STATUS=$service_status"
    echo "WEB_READY=$web_ready"
    echo "WEB_PORT=$WEB_PORT"
    echo "DISPLAY_NUM=$DISPLAY_NUM"
}

user_dir_or_fail() {
    local tg_id="${1:-}"
    local user_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED" >&2
        return 1
    fi

    user_dir=$(user_dir_by_tg_id "$tg_id" || true)

    if [ -z "$user_dir" ]; then
        say_red "USER_NOT_FOUND" >&2
        return 1
    fi

    echo "$user_dir"
}

bot_status() {
    need_root
    create_dirs
    load_config

    local tg_id="${1:-}"
    local user_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    user_dir=$(user_dir_by_tg_id "$tg_id" || true)

    if [ -z "$user_dir" ]; then
        echo "NO_PHONE=1"
        return 0
    fi

    linux_user_info_by_dir "$user_dir"
}

bot_create_phone() {
    create_linux_user "${1:-}"
}

bot_start_phone() {
    need_root
    create_dirs

    local user_dir
    user_dir=$(user_dir_or_fail "${1:-}") || return 1

    # shellcheck disable=SC1091
    source "$user_dir/user.env"
    write_session_script
    write_user_service "$user_dir"
    systemctl restart "polmira-linux-${LINUX_USER}.service"
    linux_user_info_by_dir "$user_dir"
}

bot_stop_phone() {
    need_root
    create_dirs

    local user_dir
    user_dir=$(user_dir_or_fail "${1:-}") || return 1

    # shellcheck disable=SC1091
    source "$user_dir/user.env"
    systemctl stop "polmira-linux-${LINUX_USER}.service" || true
    linux_user_info_by_dir "$user_dir"
}

bot_delete_phone() {
    need_root
    create_dirs

    local user_dir linux_user
    user_dir=$(user_dir_or_fail "${1:-}") || return 1

    # shellcheck disable=SC1091
    source "$user_dir/user.env"
    linux_user="$LINUX_USER"

    systemctl disable --now "polmira-linux-${linux_user}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/polmira-linux-${linux_user}.service"
    systemctl daemon-reload
    remove_user_nginx_conf "$linux_user" || true
    rm -rf "$user_dir"

    if id "$linux_user" >/dev/null 2>&1; then
        userdel -r "$linux_user" 2>/dev/null || userdel "$linux_user" 2>/dev/null || true
    fi

    say_green "Linux пользователь удалён: $linux_user"
}

bot_set_password() {
    need_root
    create_dirs

    local user_dir new_user new_pass
    user_dir=$(user_dir_or_fail "${1:-}") || return 1
    new_user="${2:-}"
    new_pass="${3:-}"

    if [[ ! "$new_user" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        say_red "BAD_USERNAME"
        return 1
    fi

    if [ "${#new_pass}" -lt 4 ]; then
        say_red "BAD_PASSWORD"
        return 1
    fi

    set_access_password_files "$user_dir" "$new_user" "$new_pass"
    user_env_set "$user_dir" "USERNAME" "$new_user"
    write_user_nginx_conf "$user_dir"
    linux_user_info_by_dir "$user_dir"
}

bot_install_app() {
    local user_dir
    user_dir=$(user_dir_or_fail "${1:-}") || return 1

    # shellcheck disable=SC1091
    source "$user_dir/user.env"
    install_max_for_user "$LINUX_USER"
    linux_user_info_by_dir "$user_dir"
}

bot_enable_vpn() {
    bot_status "${1:-}"
}

bot_disable_vpn() {
    bot_status "${1:-}"
}

install_deps() {
    need_root
    apt update
    apt install -y \
        nginx certbot apache2-utils openssl ca-certificates curl wget \
        gnupg \
        xvfb x11vnc novnc websockify openbox fluxbox xterm pcmanfm \
        netcat-openbsd iproute2 procps
}

configure_domain() {
    need_root
    create_dirs

    read -rp "Домен/IP для noVNC: " PUBLIC_HOST

    if [ -z "$PUBLIC_HOST" ]; then
        say_red "Домен/IP не может быть пустым"
        return 1
    fi

    read -rp "Использовать HTTPS? [y/N]: " answer

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        USE_HTTPS="yes"
        SSL_CERT="/etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem"
        SSL_KEY="/etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem"

        if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
            read -rp "Путь к fullchain.pem: " SSL_CERT
            read -rp "Путь к privkey.pem: " SSL_KEY
        fi
    else
        USE_HTTPS="no"
        SSL_CERT=""
        SSL_KEY=""
    fi

    save_config
    write_nginx_main_config
}

manage_allowed_tg_ids() {
    need_root
    create_dirs

    while true; do
        echo
        echo "Разрешённые Telegram ID:"
        if [ -s "$TG_ALLOWED_FILE" ]; then
            nl -ba "$TG_ALLOWED_FILE"
        else
            echo "(пусто)"
        fi
        echo
        echo "1. Добавить"
        echo "2. Удалить"
        echo "0. Назад"
        read -rp "Выбор: " choice

        case "$choice" in
            1)
                read -rp "Telegram ID: " tg_id
                if [[ "$tg_id" =~ ^[0-9]+$ ]] && ! grep -Fxq "$tg_id" "$TG_ALLOWED_FILE"; then
                    echo "$tg_id" >> "$TG_ALLOWED_FILE"
                fi
                ;;
            2)
                read -rp "Telegram ID: " tg_id
                sed -i "/^${tg_id}$/d" "$TG_ALLOWED_FILE"
                ;;
            0) return 0 ;;
        esac
    done
}

list_users() {
    need_root
    create_dirs
    load_config

    local env_file user_dir

    while IFS= read -r env_file; do
        user_dir=$(dirname "$env_file")
        linux_user_info_by_dir "$user_dir"
        echo
    done < <(find "$USERS_DIR" -mindepth 2 -maxdepth 2 -name user.env 2>/dev/null | sort)
}

install_polmira_linux() {
    need_root
    create_dirs
    install_deps
    write_session_script
    write_nginx_main_config || true
    say_green "Polmira Linux подготовлена"
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
        bot-set-password) shift; bot_set_password "$@" ;;
        *) return 1 ;;
    esac
}

main_menu() {
    while true; do
        clear
        echo "======================================"
        echo " Polmira Linux"
        echo "======================================"
        echo
        echo "1. Установить / обновить базу"
        echo "2. Настроить домен/nginx"
        echo "3. Разрешённые Telegram ID"
        echo "4. Создать Linux пользователя по TG ID"
        echo "5. Список пользователей"
        echo "0. Выход"
        echo
        read -rp "Выбор: " choice

        case "$choice" in
            1) install_polmira_linux; read -rp "Enter..." _ ;;
            2) configure_domain; read -rp "Enter..." _ ;;
            3) manage_allowed_tg_ids ;;
            4)
                read -rp "TG ID: " tg_id
                create_linux_user "$tg_id"
                read -rp "Enter..." _
                ;;
            5) list_users; read -rp "Enter..." _ ;;
            0) exit 0 ;;
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
