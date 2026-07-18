#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/polmira-docker"
INSTANCES_DIR="$APP_DIR/instances"
CONFIG_FILE="$APP_DIR/config.env"
TG_ALLOWED_FILE="$APP_DIR/tg-allowed.txt"
BOT_ENV_FILE="$APP_DIR/bot/.env"
NGINX_SITE="/etc/nginx/sites-available/polmira-docker"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/polmira-docker"
NGINX_SNIPPETS_DIR="/etc/nginx/polmira-docker"
IMAGE="${POLMIRA_MAX_IMAGE:-chtotos/polmira_max:latest}"
MAX_CPUS="${POLMIRA_MAX_CPUS:-0.75}"
WEB_RANGE_START=6200
WEB_RANGE_END=6299
PUBLIC_HOST=""
USE_HTTPS="yes"
SSL_CERT=""
SSL_KEY=""

NORMAL='\033[0m'
GREEN='\033[32m'
RED='\033[31m'

say_green() { echo -e "${GREEN}$1${NORMAL}"; }
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

docker_cmd() {
    if [ -f /.dockerenv ] && exists nsenter; then
        command nsenter -t 1 -m -u -i -n -p docker "$@"
    else
        command docker "$@"
    fi
}

nginx_cmd() {
    if [ -f /.dockerenv ] && exists nsenter; then
        command nsenter -t 1 -m -u -i -n -p nginx "$@"
    else
        command nginx "$@"
    fi
}

create_dirs() {
    mkdir -p "$APP_DIR" "$INSTANCES_DIR" "$NGINX_SNIPPETS_DIR" "$APP_DIR/bot"
    touch "$TG_ALLOWED_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    PUBLIC_HOST="${PUBLIC_HOST:-}"
    USE_HTTPS="${USE_HTTPS:-yes}"
    if [ -n "$PUBLIC_HOST" ]; then
        SSL_CERT="${SSL_CERT:-/root/.acme.sh/${PUBLIC_HOST}_ecc/fullchain.cer}"
        SSL_KEY="${SSL_KEY:-/root/.acme.sh/${PUBLIC_HOST}_ecc/${PUBLIC_HOST}.key}"
    else
        SSL_CERT="${SSL_CERT:-}"
        SSL_KEY="${SSL_KEY:-}"
    fi
}

require_public_host() {
    if [ -z "${PUBLIC_HOST:-}" ]; then
        say_red "PUBLIC_HOST не задан. Запусти: polmira-docker install"
        return 1
    fi
}

configure_public_access() {
    load_config

    local value
    if [ -z "${PUBLIC_HOST:-}" ]; then
        read -r -p "Домен для noVNC/API, например max.example.com: " value
        PUBLIC_HOST="$value"
    fi

    require_public_host

    read -r -p "Использовать HTTPS? [yes/no] (${USE_HTTPS:-yes}): " value
    USE_HTTPS="${value:-${USE_HTTPS:-yes}}"

    if [ "$USE_HTTPS" = "yes" ]; then
        local default_cert default_key
        default_cert="/root/.acme.sh/${PUBLIC_HOST}_ecc/fullchain.cer"
        default_key="/root/.acme.sh/${PUBLIC_HOST}_ecc/${PUBLIC_HOST}.key"

        read -r -p "Путь к SSL cert (${SSL_CERT:-$default_cert}): " value
        SSL_CERT="${value:-${SSL_CERT:-$default_cert}}"

        read -r -p "Путь к SSL key (${SSL_KEY:-$default_key}): " value
        SSL_KEY="${value:-${SSL_KEY:-$default_key}}"
    else
        SSL_CERT=""
        SSL_KEY=""
    fi

    save_config
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

load_bot_env_value() {
    local key="$1"
    local file="${BOT_ENV_FILE}"

    if [ -f "$file" ]; then
        awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' "$file"
    fi
}

ensure_relay_secret() {
    create_dirs

    if [ -f "$BOT_ENV_FILE" ] && grep -q '^POLMIRA_RELAY_SECRET=' "$BOT_ENV_FILE"; then
        return 0
    fi

    local secret
    secret="$(openssl rand -hex 24)"
    {
        echo
        echo "POLMIRA_RELAY_SECRET=${secret}"
        echo "POLMIRA_RELAY_BIND=172.17.0.1"
        echo "POLMIRA_RELAY_PORT=8788"
    } >> "$BOT_ENV_FILE"
    chmod 600 "$BOT_ENV_FILE" || true
}

public_base_url() {
    load_config
    if [ "$USE_HTTPS" = "yes" ]; then
        echo "https://${PUBLIC_HOST}"
    else
        echo "http://${PUBLIC_HOST}"
    fi
}

novnc_url() {
    local web_path="$1"
    echo "$(public_base_url)${web_path}vnc.html?autoconnect=1&resize=scale&shared=0&path=${web_path#/}"
}

tg_is_allowed() {
    local tg_id="${1:-}"
    [ -n "$tg_id" ] || return 1
    create_dirs
    grep -Fxq "$tg_id" "$TG_ALLOWED_FILE"
}

validate_tg_id() {
    local tg_id="${1:-}"
    [[ "$tg_id" =~ ^[0-9]{3,20}$ ]]
}

dedupe_allowed_ids() {
    create_dirs
    awk 'NF && !seen[$0]++' "$TG_ALLOWED_FILE" > "${TG_ALLOWED_FILE}.tmp"
    mv "${TG_ALLOWED_FILE}.tmp" "$TG_ALLOWED_FILE"
}

allow_tg_id() {
    need_root
    create_dirs

    local tg_id="${1:-}"
    if ! validate_tg_id "$tg_id"; then
        say_red "BAD_TG_ID"
        return 1
    fi

    if ! tg_is_allowed "$tg_id"; then
        echo "$tg_id" >> "$TG_ALLOWED_FILE"
    fi
    dedupe_allowed_ids
    say_green "Telegram ID разрешён: $tg_id"
}

disallow_tg_id() {
    need_root
    create_dirs

    local tg_id="${1:-}"
    if ! validate_tg_id "$tg_id"; then
        say_red "BAD_TG_ID"
        return 1
    fi

    grep -vx "$tg_id" "$TG_ALLOWED_FILE" > "${TG_ALLOWED_FILE}.tmp" || true
    mv "${TG_ALLOWED_FILE}.tmp" "$TG_ALLOWED_FILE"
    say_green "Telegram ID удалён из доступа: $tg_id"
}

list_allowed_ids() {
    create_dirs
    dedupe_allowed_ids
    if [ ! -s "$TG_ALLOWED_FILE" ]; then
        echo "Разрешённых Telegram ID пока нет"
        return 0
    fi

    echo "Разрешённые Telegram ID:"
    cat "$TG_ALLOWED_FILE"
}

safe_name_for_tg() {
    local tg_id="$1"
    echo "pm_${tg_id}" | tr -cd 'A-Za-z0-9_'
}

instance_dir_by_tg_id() {
    local tg_id="${1:-}"
    local env_file
    [ -n "$tg_id" ] || return 1

    while IFS= read -r env_file; do
        if grep -Fxq "TG_ID=${tg_id}" "$env_file"; then
            dirname "$env_file"
            return 0
        fi
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    return 1
}

delete_audit() {
    local message="$1"
    mkdir -p "$APP_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%F %T')" "$message" >> "$APP_DIR/delete.log" 2>/dev/null || true
}

validate_instance_dir_for_tg_id() {
    local tg_id="$1"
    local instance_dir="$2"
    local base resolved expected_name

    [ -n "$tg_id" ] || { say_red "TG_ID пустой" >&2; return 1; }
    [ -n "$instance_dir" ] || { say_red "INSTANCE_DIR пустой" >&2; return 1; }
    [ -f "$instance_dir/instance.env" ] || { say_red "INSTANCE_ENV_NOT_FOUND" >&2; return 1; }

    base="$(realpath -m "$INSTANCES_DIR")"
    resolved="$(realpath -m "$instance_dir")"
    case "$resolved" in
        "$base"/*) ;;
        *)
            say_red "UNSAFE_INSTANCE_DIR=$resolved" >&2
            return 1
            ;;
    esac

    if ! grep -Fxq "TG_ID=${tg_id}" "$instance_dir/instance.env"; then
        say_red "TG_ID_MISMATCH" >&2
        delete_audit "refuse tg_id=$tg_id dir=$resolved reason=TG_ID_MISMATCH"
        return 1
    fi

    expected_name="$(safe_name_for_tg "$tg_id")"
    if ! grep -Fxq "INSTANCE_NAME=${expected_name}" "$instance_dir/instance.env"; then
        say_red "INSTANCE_NAME_MISMATCH" >&2
        delete_audit "refuse tg_id=$tg_id dir=$resolved reason=INSTANCE_NAME_MISMATCH expected=$expected_name"
        return 1
    fi
}

find_free_web_port() {
    local port used

    for port in $(seq "$WEB_RANGE_START" "$WEB_RANGE_END"); do
        used="no"
        while IFS= read -r env_file; do
            grep -Eq "^WEB_PORT=${port}$" "$env_file" && used="yes"
        done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null)

        if [ "$used" = "no" ] && ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
            echo "$port"
            return 0
        fi
    done

    return 1
}

generate_web_path() {
    openssl rand -hex 8 | awk '{print "/polmira/"$1"/"}'
}

write_htpasswd() {
    local instance_dir="$1"
    local username="$2"
    local password="$3"
    local hash

    hash=$(openssl passwd -apr1 "$password")
    printf "%s:%s\n" "$username" "$hash" > "$instance_dir/htpasswd"
    chmod 755 "$APP_DIR" "$INSTANCES_DIR" "$instance_dir"
    chmod 644 "$instance_dir/htpasswd"
}

write_nginx_main_config() {
    load_config
    require_public_host
    save_config
    mkdir -p "$NGINX_SNIPPETS_DIR"

    if [ "$USE_HTTPS" = "yes" ]; then
        cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$polmira_docker_connection_upgrade {
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

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    client_max_body_size 2G;

    location / {
        return 404;
    }

    include ${NGINX_SNIPPETS_DIR}/*.conf;
}
EOF
    else
        cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$polmira_docker_connection_upgrade {
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

    rm -f /etc/nginx/sites-enabled/default \
        /etc/nginx/sites-enabled/polmira \
        /etc/nginx/sites-enabled/polmira-linux 2>/dev/null || true
    ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    nginx_cmd -t
    systemctl reload nginx
}

write_instance_nginx_conf() {
    local instance_dir="$1"
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    cat > "${NGINX_SNIPPETS_DIR}/${INSTANCE_NAME}.conf" <<EOF
location = ${WEB_PATH}vnc.html {
    auth_basic "Polmira";
    auth_basic_user_file ${instance_dir}/htpasswd;
    add_header Cache-Control "no-store";

    if (\$arg_path = "") {
        return 302 ${WEB_PATH}vnc.html?autoconnect=1&resize=scale&shared=0&path=${WEB_PATH#/};
    }

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_docker_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;

    proxy_pass http://127.0.0.1:${WEB_PORT}/vnc.html;
}

location = ${WEB_PATH}input {
    auth_basic "Polmira";
    auth_basic_user_file ${instance_dir}/htpasswd;
    client_max_body_size 64k;

    proxy_http_version 1.1;
    proxy_set_header X-Polmira-Tg-Id "${TG_ID}";
    proxy_set_header X-Polmira-Secret "${RELAY_SECRET}";
    proxy_set_header Content-Type "text/plain; charset=utf-8";
    proxy_read_timeout 15s;

    proxy_pass http://172.17.0.1:8788/input;
}

location ${WEB_PATH} {
    auth_basic "Polmira";
    auth_basic_user_file ${instance_dir}/htpasswd;
    add_header Cache-Control "no-store";

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_docker_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;

    proxy_pass http://127.0.0.1:${WEB_PORT}/;
}
EOF

    nginx_cmd -t
    systemctl reload nginx
}

remove_instance_nginx_conf() {
    local instance_name="$1"
    rm -f "${NGINX_SNIPPETS_DIR}/${instance_name}.conf"
    nginx_cmd -t && systemctl reload nginx
}

refresh_nginx() {
    need_root
    create_dirs
    load_config
    write_nginx_main_config

    local env_file
    while IFS= read -r env_file; do
        write_instance_nginx_conf "$(dirname "$env_file")"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)
}

ensure_image() {
    docker_cmd image inspect "$IMAGE" >/dev/null 2>&1 || docker_cmd pull "$IMAGE"
}

container_exists() {
    local container="$1"
    docker_cmd ps -a --format '{{.Names}}' | grep -Fxq "$container"
}

start_container() {
    local instance_dir="$1"
    local bot_token relay_secret
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    ensure_image
    if [ -z "${RELAY_SECRET:-}" ]; then
        RELAY_SECRET="$(openssl rand -hex 24)"
        echo "RELAY_SECRET=$RELAY_SECRET" >> "$instance_dir/instance.env"
    fi

    mkdir -p "$instance_dir/downloads" "$instance_dir/max-home" "$instance_dir/oneme-data" "$instance_dir/logs"
    chmod 755 "$instance_dir" "$instance_dir/downloads" "$instance_dir/max-home" "$instance_dir/oneme-data" "$instance_dir/logs"

    bot_token="$(load_bot_env_value TELEGRAM_BOT_TOKEN || true)"
    relay_secret="$RELAY_SECRET"

    if container_exists "$CONTAINER_NAME"; then
        docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    docker_cmd run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --cpus "$MAX_CPUS" \
        --shm-size 1g \
        -p "127.0.0.1:${WEB_PORT}:6080" \
        -e "TG_ID=${TG_ID}" \
        -e "PHONE_NAME=${INSTANCE_NAME}" \
        -e "TELEGRAM_BOT_TOKEN=${bot_token}" \
        -e "POLMIRA_RELAY_URL=http://172.17.0.1:8788/notify" \
        -e "POLMIRA_RELAY_SECRET=${relay_secret}" \
        -e "RESOLUTION=1280x720x24" \
        -v "${instance_dir}/downloads:/home/polmira/Downloads" \
        -v "${instance_dir}/max-home:/home/polmira/.config/max" \
        -v "${instance_dir}/oneme-data:/home/polmira/.local/share/ONEME" \
        -v "${instance_dir}/logs:/var/log/polmira" \
        "$IMAGE" >/dev/null
}

container_status() {
    local container="$1"
    docker_cmd inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing"
}

web_ready() {
    local port="$1"
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "yes"
    else
        echo "no"
    fi
}

instance_info_by_dir() {
    local instance_dir="$1"
    local status ready
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    status="$(container_status "$CONTAINER_NAME")"
    ready="$(web_ready "$WEB_PORT")"

    echo "PHONE_NAME=$INSTANCE_NAME"
    echo "INSTANCE_NAME=$INSTANCE_NAME"
    echo "LINUX_USER=$INSTANCE_NAME"
    echo "CONTAINER_NAME=$CONTAINER_NAME"
    echo "TG_ID=$TG_ID"
    echo "USERNAME=$USERNAME"
    echo "URL=$(novnc_url "$WEB_PATH")"
    echo "VPN_ENABLED=no"
    echo "INIT_STATUS=$status"
    echo "WEB_STATUS=$status"
    echo "WEB_READY=$ready"
    echo "WEB_PORT=$WEB_PORT"
    echo "DOWNLOADS_DIR=$instance_dir/downloads"
}

instance_dir_or_fail() {
    local tg_id="${1:-}"
    local instance_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED" >&2
        return 1
    fi

    instance_dir="$(instance_dir_by_tg_id "$tg_id" || true)"
    if [ -z "$instance_dir" ]; then
        say_red "USER_NOT_FOUND" >&2
        return 1
    fi

    echo "$instance_dir"
}

bot_status() {
    need_root
    create_dirs
    load_config

    local tg_id="${1:-}"
    local instance_dir

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    instance_dir="$(instance_dir_by_tg_id "$tg_id" || true)"
    if [ -z "$instance_dir" ]; then
        echo "NO_PHONE=1"
        return 0
    fi

    instance_info_by_dir "$instance_dir"
}

bot_create_phone() {
    need_root
    create_dirs
    load_config
    write_nginx_main_config

    local tg_id="${1:-}"
    local instance_name instance_dir access_pass web_port web_path container_name username relay_secret

    if [ -z "$tg_id" ]; then
        say_red "TG_ID пустой"
        return 1
    fi

    if ! tg_is_allowed "$tg_id"; then
        say_red "ACCESS_DENIED"
        return 1
    fi

    if instance_dir_by_tg_id "$tg_id" >/dev/null; then
        say_red "USER_ALREADY_EXISTS"
        return 1
    fi

    instance_name="$(safe_name_for_tg "$tg_id")"
    instance_dir="$INSTANCES_DIR/$instance_name"
    access_pass="$(openssl rand -hex 6)"
    web_port="$(find_free_web_port)"
    web_path="$(generate_web_path)"
    container_name="polmira-max-${tg_id}"
    username="$instance_name"
    relay_secret="$(openssl rand -hex 24)"

    mkdir -p "$instance_dir/downloads" "$instance_dir/max-home" "$instance_dir/oneme-data" "$instance_dir/logs"
    cat > "$instance_dir/instance.env" <<EOF
TG_ID=${tg_id}
INSTANCE_NAME=${instance_name}
CONTAINER_NAME=${container_name}
WEB_PORT=${web_port}
WEB_PATH=${web_path}
USERNAME=${username}
RELAY_SECRET=${relay_secret}
EOF

    write_htpasswd "$instance_dir" "$username" "$access_pass"
    write_instance_nginx_conf "$instance_dir"
    start_container "$instance_dir"

    echo "PASSWORD=$access_pass"
    instance_info_by_dir "$instance_dir"
}

bot_start_phone() {
    need_root
    create_dirs
    load_config
    write_nginx_main_config

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    write_instance_nginx_conf "$instance_dir"
    start_container "$instance_dir"
    sleep 1
    instance_info_by_dir "$instance_dir"
}

bot_stop_phone() {
    need_root
    create_dirs

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"
    docker_cmd stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    instance_info_by_dir "$instance_dir"
}

bot_delete_phone() {
    need_root
    create_dirs

    local tg_id instance_dir instance_name resolved_dir
    tg_id="${1:-}"
    instance_dir="$(instance_dir_or_fail "$tg_id")" || return 1
    validate_instance_dir_for_tg_id "$tg_id" "$instance_dir" || return 1
    resolved_dir="$(realpath -m "$instance_dir")"

    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"
    instance_name="$INSTANCE_NAME"

    delete_audit "start tg_id=$tg_id instance=$instance_name container=$CONTAINER_NAME dir=$resolved_dir"
    docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    remove_instance_nginx_conf "$instance_name" || true
    rm -rf "$instance_dir"
    delete_audit "done tg_id=$tg_id instance=$instance_name container=$CONTAINER_NAME dir=$resolved_dir"
    say_green "Контейнер удалён"
}

bot_set_password() {
    need_root
    create_dirs

    local tg_id="${1:-}"
    local username="${2:-}"
    local password="${3:-}"
    local instance_dir

    if [ -z "$username" ] || [ -z "$password" ]; then
        say_red "Нужно: bot-set-password TG_ID LOGIN PASSWORD"
        return 1
    fi

    if ! [[ "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        say_red "BAD_USERNAME"
        return 1
    fi

    instance_dir="$(instance_dir_or_fail "$tg_id")" || return 1
    sed -i "/^USERNAME=/d" "$instance_dir/instance.env"
    echo "USERNAME=$username" >> "$instance_dir/instance.env"
    write_htpasswd "$instance_dir" "$username" "$password"
    instance_info_by_dir "$instance_dir"
}

bot_notify_test() {
    need_root
    create_dirs

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    if [ "$(container_status "$CONTAINER_NAME")" != "running" ]; then
        say_red "CONTAINER_NOT_RUNNING"
        return 1
    fi

    docker_cmd exec -u polmira "$CONTAINER_NAME" bash -lc '
        set -e
        [ -f /tmp/polmira-session.env ] && source /tmp/polmira-session.env
        export DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
        notify-send "MAX" "Тестовое сообщение Polmira"
    '
    say_green "Тестовое уведомление отправлено в DBus"
}

bot_input() {
    need_root
    create_dirs

    local instance_dir input_file input_size
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    if [ "$(container_status "$CONTAINER_NAME")" != "running" ]; then
        say_red "CONTAINER_NOT_RUNNING"
        return 1
    fi

    input_file="$(mktemp)"
    cat > "$input_file"
    input_size="$(wc -c < "$input_file")"

    if [ "$input_size" -le 0 ] || [ "$input_size" -gt 65536 ]; then
        rm -f "$input_file"
        say_red "BAD_INPUT_SIZE"
        return 1
    fi

    if ! docker_cmd exec -i -u polmira \
        -e DISPLAY=:20 \
        -e LANG=C.UTF-8 \
        "$CONTAINER_NAME" sh -lc \
        'xclip -selection clipboard -in && sleep 0.08 && xdotool key --clearmodifiers ctrl+v' \
        < "$input_file"; then
        rm -f "$input_file"
        say_red "INPUT_FAILED"
        return 1
    fi

    rm -f "$input_file"
}

bot_install_app() {
    bot_start_phone "$@"
}

list_instances() {
    create_dirs

    local env_file instance_dir
    printf "%-18s %-14s %-10s %-8s %s\n" "TG_ID" "NAME" "STATUS" "PORT" "URL"
    while IFS= read -r env_file; do
        instance_dir="$(dirname "$env_file")"
        # shellcheck disable=SC1090
        source "$env_file"
        printf "%-18s %-14s %-10s %-8s %s\n" \
            "$TG_ID" "$INSTANCE_NAME" "$(container_status "$CONTAINER_NAME")" "$WEB_PORT" "$(novnc_url "$WEB_PATH")"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)
}

prompt_value() {
    local label="$1"
    local value
    read -r -p "$label: " value
    echo "$value"
}

interactive_menu() {
    need_root
    create_dirs
    load_config

    while true; do
        clear || true
        echo "Polmira MAX Docker"
        echo "=================="
        echo "Домен: ${PUBLIC_HOST:-не задан}"
        echo
        list_instances
        echo
        echo "1) Создать MAX-контейнер"
        echo "2) Включить / перезапустить"
        echo "3) Выключить"
        echo "4) Удалить"
        echo "5) Сменить логин/пароль"
        echo "6) Тест уведомления"
        echo "7) Показать логи контейнера"
        echo "8) Установить / обновить nginx"
        echo "9) Разрешить Telegram ID"
        echo "10) Запретить Telegram ID"
        echo "11) Список разрешённых Telegram ID"
        echo "0) Выход"
        echo

        local choice tg_id login password instance_dir
        read -r -p "Выбор: " choice

        case "$choice" in
            1)
                tg_id="$(prompt_value "Telegram ID")"
                bot_create_phone "$tg_id"
                ;;
            2)
                tg_id="$(prompt_value "Telegram ID")"
                bot_start_phone "$tg_id"
                ;;
            3)
                tg_id="$(prompt_value "Telegram ID")"
                bot_stop_phone "$tg_id"
                ;;
            4)
                tg_id="$(prompt_value "Telegram ID")"
                read -r -p "Точно удалить? Напиши YES: " confirm
                [ "${confirm:-}" = "YES" ] && bot_delete_phone "$tg_id"
                ;;
            5)
                tg_id="$(prompt_value "Telegram ID")"
                login="$(prompt_value "Новый логин")"
                password="$(prompt_value "Новый пароль")"
                bot_set_password "$tg_id" "$login" "$password"
                ;;
            6)
                tg_id="$(prompt_value "Telegram ID")"
                bot_notify_test "$tg_id"
                ;;
            7)
                tg_id="$(prompt_value "Telegram ID")"
                instance_dir="$(instance_dir_or_fail "$tg_id")" || true
                if [ -n "${instance_dir:-}" ]; then
                    # shellcheck disable=SC1090
                    source "$instance_dir/instance.env"
                    docker_cmd logs --tail 120 "$CONTAINER_NAME"
                fi
                ;;
            8)
                install_polmira_docker
                ;;
            9)
                tg_id="$(prompt_value "Telegram ID")"
                allow_tg_id "$tg_id"
                ;;
            10)
                tg_id="$(prompt_value "Telegram ID")"
                disallow_tg_id "$tg_id"
                ;;
            11)
                list_allowed_ids
                ;;
            0)
                exit 0
                ;;
            *)
                say_red "Неизвестный пункт"
                ;;
        esac

        echo
        read -r -p "Enter чтобы продолжить..." _
    done
}

install_polmira_docker() {
    need_root
    create_dirs
    ensure_relay_secret
    configure_public_access
    write_nginx_main_config
    ensure_image
    say_green "Polmira Docker подготовлена"
}

cli_dispatch() {
    local command="${1:-}"

    case "$command" in
        bot-status) shift; bot_status "$@" ;;
        bot-create-phone) shift; bot_create_phone "$@" ;;
        bot-start-phone) shift; bot_start_phone "$@" ;;
        bot-stop-phone) shift; bot_stop_phone "$@" ;;
        bot-delete-phone) shift; bot_delete_phone "$@" ;;
        bot-set-password) shift; bot_set_password "$@" ;;
        bot-notify-test) shift; bot_notify_test "$@" ;;
        bot-input) shift; bot_input "$@" ;;
        bot-install-app) shift; bot_install_app "$@" ;;
        allow) shift; allow_tg_id "$@" ;;
        disallow) shift; disallow_tg_id "$@" ;;
        allowed) shift; list_allowed_ids "$@" ;;
        list) shift; list_instances "$@" ;;
        refresh-nginx) shift; refresh_nginx "$@" ;;
        menu|"") interactive_menu ;;
        install) shift; install_polmira_docker "$@" ;;
        *) return 1 ;;
    esac
}

if ! cli_dispatch "$@"; then
    cat <<EOF
Использование:
  polmira-docker install
  polmira-docker bot-status TG_ID
  polmira-docker bot-create-phone TG_ID
  polmira-docker bot-start-phone TG_ID
  polmira-docker bot-stop-phone TG_ID
  polmira-docker bot-delete-phone TG_ID
  polmira-docker bot-set-password TG_ID LOGIN PASSWORD
  polmira-docker bot-notify-test TG_ID
  polmira-docker bot-input TG_ID < UTF8_TEXT_FILE
  polmira-docker allow TG_ID
  polmira-docker disallow TG_ID
  polmira-docker allowed
  polmira-docker list
  polmira-docker refresh-nginx
  polmira-docker menu
EOF
    exit 1
fi
