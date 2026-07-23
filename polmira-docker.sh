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
SELKIES_IMAGE="${POLMIRA_SELKIES_IMAGE:-chtotos/polmira_max_selkies:2026.07.23-mobile3}"
SELKIES_SOURCE_ARCHIVE="${POLMIRA_SELKIES_SOURCE_ARCHIVE:-https://github.com/bukhantcev/polmira_android/archive/refs/heads/master.tar.gz}"
AUTHELIA_IMAGE="${POLMIRA_AUTHELIA_IMAGE:-authelia/authelia:4.39.20}"
AUTHELIA_DIR="$APP_DIR/authelia"
AUTHELIA_CONTAINER="polmira-authelia"
AUTHELIA_PORT=9091
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

nvidia_runtime_available() {
    docker_cmd info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

nvidia_selkies_available() {
    local driver_major

    [ -e /dev/nvidia0 ] || return 1
    exists nvidia-smi || return 1
    nvidia_runtime_available || return 1

    driver_major="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
        | head -n1 | cut -d. -f1)"
    [[ "$driver_major" =~ ^[0-9]+$ ]] && [ "$driver_major" -ge 580 ]
}

find_dri_render_node() {
    local node vendor

    for node in /sys/class/drm/renderD*; do
        [ -e "$node" ] || continue
        vendor="$(cat "$node/device/vendor" 2>/dev/null || true)"
        case "$vendor" in
            0x8086|0x1002)
                echo "/dev/dri/$(basename "$node")"
                return 0
                ;;
        esac
    done

    return 1
}

ensure_nvidia_container_runtime() {
    [ -e /dev/nvidia0 ] || return 0
    exists nvidia-smi || return 0
    nvidia_runtime_available && return 0

    if ! exists apt-get; then
        say_red "NVIDIA найдена, но NVIDIA Container Toolkit нужно установить вручную"
        return 0
    fi

    say_green "Настраиваю NVIDIA Container Toolkit для Selkies"
    if ! (
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl gnupg
        mkdir -p /usr/share/keyrings
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
        for _ in $(seq 1 30); do
            docker_cmd info >/dev/null 2>&1 && exit 0
            sleep 1
        done
        exit 1
    ); then
        say_red "NVIDIA runtime не настроен, Selkies попробует Intel/AMD GPU"
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
    mkdir -p "$APP_DIR" "$INSTANCES_DIR" "$NGINX_SNIPPETS_DIR" "$APP_DIR/bot" "$AUTHELIA_DIR"
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

selkies_url() {
    local web_path="$1"
    echo "$(public_base_url)${web_path}"
}

instance_url() {
    local backend="$1"
    local web_path="$2"

    if [ "$backend" = "selkies" ]; then
        selkies_url "$web_path"
    else
        novnc_url "$web_path"
    fi
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

env_file_value() {
    local file="$1"
    local key="$2"

    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

has_selkies_instances() {
    local env_file backend

    while IFS= read -r env_file; do
        backend="$(env_file_value "$env_file" BACKEND)"
        if [ "$backend" = "selkies" ]; then
            return 0
        fi
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    return 1
}

ensure_authelia_image() {
    docker_cmd image inspect "$AUTHELIA_IMAGE" >/dev/null 2>&1 || docker_cmd pull "$AUTHELIA_IMAGE"
}

ensure_authelia_secrets() {
    local secrets_file="$AUTHELIA_DIR/secrets.env"

    create_dirs
    if [ ! -f "$secrets_file" ]; then
        cat > "$secrets_file" <<EOF
AUTHELIA_SESSION_SECRET=$(openssl rand -hex 32)
AUTHELIA_STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$(openssl rand -hex 32)
EOF
        chmod 600 "$secrets_file"
    fi
}

authelia_hash_password() {
    local password="$1"
    local digest

    ensure_authelia_image
    digest="$(
        docker_cmd run --rm "$AUTHELIA_IMAGE" \
            authelia crypto hash generate argon2 --password "$password" \
            | sed -n 's/^Digest: //p'
    )"
    [ -n "$digest" ] || {
        say_red "AUTHELIA_PASSWORD_HASH_FAILED" >&2
        return 1
    }
    printf '%s\n' "$digest"
}

write_authelia_users() {
    local users_file="$AUTHELIA_DIR/users_database.yml"
    local tmp_file="${users_file}.tmp"
    local env_file instance_dir backend username password_hash

    {
        echo "users:"
        while IFS= read -r env_file; do
            backend="$(env_file_value "$env_file" BACKEND)"
            [ "$backend" = "selkies" ] || continue

            instance_dir="$(dirname "$env_file")"
            username="$(env_file_value "$env_file" USERNAME)"
            [ -n "$username" ] || continue
            [ -f "$instance_dir/authelia-password.hash" ] || continue
            password_hash="$(cat "$instance_dir/authelia-password.hash")"

            cat <<EOF
  "${username}":
    disabled: false
    displayname: "${username}"
    password: "${password_hash}"
    email: "${username}@polmira.invalid"
    groups:
      - "maxofon"
EOF
        done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)
    } > "$tmp_file"

    mv "$tmp_file" "$users_file"
    chmod 600 "$users_file"
}

write_authelia_config() {
    local config_file="$AUTHELIA_DIR/configuration.yml"
    local tmp_file="${config_file}.tmp"
    local env_file backend web_path username

    load_config
    require_public_host
    ensure_authelia_secrets
    # shellcheck disable=SC1090
    source "$AUTHELIA_DIR/secrets.env"

    cat > "$tmp_file" <<EOF
theme: auto

server:
  address: "tcp://0.0.0.0:${AUTHELIA_PORT}/auth"
  endpoints:
    authz:
      auth-request:
        implementation: "AuthRequest"

log:
  level: info

authentication_backend:
  password_reset:
    disable: true
  file:
    path: "/config/users_database.yml"
    watch: true
    password:
      algorithm: "argon2"

identity_validation:
  reset_password:
    jwt_secret: "${AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET}"

session:
  name: "polmira_session"
  secret: "${AUTHELIA_SESSION_SECRET}"
  cookies:
    - domain: "${PUBLIC_HOST}"
      authelia_url: "$(public_base_url)/auth"
      default_redirection_url: "$(public_base_url)/"
      same_site: "lax"
      expiration: "12h"
      inactivity: "30m"
      remember_me: "1M"

storage:
  encryption_key: "${AUTHELIA_STORAGE_ENCRYPTION_KEY}"
  local:
    path: "/config/db.sqlite3"

notifier:
  filesystem:
    filename: "/config/notification.txt"

webauthn:
  enable_passkey_login: true
  experimental_enable_passkey_uv_two_factors: true
  display_name: "Maxofon"
  attestation_conveyance_preference: "indirect"
  selection_criteria:
    discoverability: "preferred"
    user_verification: "preferred"

regulation:
  max_retries: 5
  find_time: "2m"
  ban_time: "5m"

access_control:
  default_policy: "deny"
  rules:
EOF

    while IFS= read -r env_file; do
        backend="$(env_file_value "$env_file" BACKEND)"
        [ "$backend" = "selkies" ] || continue

        web_path="$(env_file_value "$env_file" WEB_PATH)"
        username="$(env_file_value "$env_file" USERNAME)"
        [ -n "$web_path" ] && [ -n "$username" ] || continue

        cat >> "$tmp_file" <<EOF
    - domain: "${PUBLIC_HOST}"
      resources:
        - "^${web_path}.*$"
      subject:
        - "user:${username}"
      policy: "two_factor"
EOF
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    mv "$tmp_file" "$config_file"
    chmod 600 "$config_file"
}

start_authelia() {
    ensure_authelia_image
    write_authelia_users
    write_authelia_config

    docker_cmd rm -f "$AUTHELIA_CONTAINER" >/dev/null 2>&1 || true
    docker_cmd run -d \
        --name "$AUTHELIA_CONTAINER" \
        --restart unless-stopped \
        -p "127.0.0.1:${AUTHELIA_PORT}:9091" \
        -e "TZ=Europe/Moscow" \
        -v "${AUTHELIA_DIR}:/config" \
        "$AUTHELIA_IMAGE" >/dev/null
}

sync_authelia() {
    if has_selkies_instances; then
        start_authelia
    elif container_exists "$AUTHELIA_CONTAINER"; then
        docker_cmd rm -f "$AUTHELIA_CONTAINER" >/dev/null 2>&1 || true
    fi
}

prune_orphaned_nginx_configs() {
    local config instance_name

    mkdir -p "$NGINX_SNIPPETS_DIR"
    while IFS= read -r config; do
        instance_name="$(basename "$config" .conf)"
        if [ ! -f "$INSTANCES_DIR/$instance_name/instance.env" ]; then
            rm -f "$config"
        fi
    done < <(find "$NGINX_SNIPPETS_DIR" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
}

write_nginx_main_config() {
    load_config
    require_public_host
    save_config
    mkdir -p "$NGINX_SNIPPETS_DIR"
    prune_orphaned_nginx_configs

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

    location = /auth {
        return 302 /auth/;
    }

    location ^~ /auth/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Uri \$request_uri;
        proxy_set_header X-Forwarded-Method \$request_method;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${AUTHELIA_PORT};
    }

    location = /internal/authelia/authz {
        internal;
        proxy_http_version 1.1;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-Method \$request_method;
        proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Uri \$request_uri;
        proxy_set_header X-Forwarded-Method \$request_method;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${AUTHELIA_PORT}/auth/api/authz/auth-request;
    }

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

    location = /auth {
        return 302 /auth/;
    }

    location ^~ /auth/ {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Uri \$request_uri;
        proxy_set_header X-Forwarded-Method \$request_method;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${AUTHELIA_PORT};
    }

    location = /internal/authelia/authz {
        internal;
        proxy_http_version 1.1;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-Method \$request_method;
        proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Uri \$request_uri;
        proxy_set_header X-Forwarded-Method \$request_method;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://127.0.0.1:${AUTHELIA_PORT}/auth/api/authz/auth-request;
    }

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

write_legacy_instance_nginx_conf() {
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

write_selkies_instance_nginx_conf() {
    local instance_dir="$1"
    local web_path_without_slash
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"
    web_path_without_slash="${WEB_PATH%/}"

    cat > "${NGINX_SNIPPETS_DIR}/${INSTANCE_NAME}.conf" <<EOF
location = ${web_path_without_slash} {
    return 302 ${WEB_PATH};
}

location = ${WEB_PATH}input {
    auth_request /internal/authelia/authz;
    auth_request_set \$redirection_url \$upstream_http_location;
    error_page 401 =302 \$redirection_url;
    client_max_body_size 64k;

    proxy_http_version 1.1;
    proxy_set_header X-Polmira-Tg-Id "${TG_ID}";
    proxy_set_header X-Polmira-Secret "${RELAY_SECRET}";
    proxy_set_header Content-Type "text/plain; charset=utf-8";
    proxy_read_timeout 15s;

    proxy_pass http://172.17.0.1:8788/input;
}

location ${WEB_PATH} {
    auth_request /internal/authelia/authz;
    auth_request_set \$redirection_url \$upstream_http_location;
    auth_request_set \$user \$upstream_http_remote_user;
    auth_request_set \$groups \$upstream_http_remote_groups;
    auth_request_set \$name \$upstream_http_remote_name;
    auth_request_set \$email \$upstream_http_remote_email;
    error_page 401 =302 \$redirection_url;

    add_header Cache-Control "no-store";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "same-origin";

    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$polmira_docker_connection_upgrade;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Remote-User \$user;
    proxy_set_header Remote-Groups \$groups;
    proxy_set_header Remote-Name \$name;
    proxy_set_header Remote-Email \$email;
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
    proxy_buffering off;

    proxy_pass http://127.0.0.1:${WEB_PORT};
}
EOF

    nginx_cmd -t
    systemctl reload nginx
}

write_instance_nginx_conf() {
    local instance_dir="$1"
    local backend

    backend="$(env_file_value "$instance_dir/instance.env" BACKEND)"
    if [ "$backend" = "selkies" ]; then
        write_selkies_instance_nginx_conf "$instance_dir"
    else
        write_legacy_instance_nginx_conf "$instance_dir"
    fi
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
    sync_authelia

    local env_file
    while IFS= read -r env_file; do
        write_instance_nginx_conf "$(dirname "$env_file")"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)
}

ensure_image() {
    docker_cmd image inspect "$IMAGE" >/dev/null 2>&1 || docker_cmd pull "$IMAGE"
}

ensure_selkies_image() {
    local build_dir archive_file

    if docker_cmd image inspect "$SELKIES_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    if docker_cmd pull "$SELKIES_IMAGE"; then
        return 0
    fi

    if [ "$(uname -m)" != "x86_64" ]; then
        say_red "MAX для Linux доступен только для amd64/x86_64"
        return 1
    fi

    build_dir="$(mktemp -d)"
    archive_file="$build_dir/source.tar.gz"
    say_green "Готового Selkies-образа нет, собираю его локально"

    if ! curl -fsSL "$SELKIES_SOURCE_ARCHIVE" -o "$archive_file"; then
        rm -rf "$build_dir"
        say_red "Не удалось скачать исходники Selkies-образа"
        return 1
    fi

    mkdir -p "$build_dir/source"
    if ! tar -xzf "$archive_file" --strip-components=1 -C "$build_dir/source"; then
        rm -rf "$build_dir"
        say_red "Не удалось распаковать исходники Selkies-образа"
        return 1
    fi

    if ! docker_cmd build \
        -f "$build_dir/source/Dockerfile.selkies" \
        -t "$SELKIES_IMAGE" \
        "$build_dir/source"; then
        rm -rf "$build_dir"
        say_red "Не удалось собрать Selkies-образ"
        return 1
    fi

    rm -rf "$build_dir"
}

container_exists() {
    local container="$1"
    docker_cmd ps -a --format '{{.Names}}' | grep -Fxq "$container"
}

start_legacy_container() {
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

start_selkies_container() {
    local instance_dir="$1"
    local bot_token relay_secret render_node gpu_mode
    local wayland_enabled="false"
    local -a gpu_args=()
    local -a gpu_env=()
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"
    gpu_mode="${SELKIES_GPU_MODE:-auto}"

    ensure_selkies_image
    if [ -z "${RELAY_SECRET:-}" ]; then
        RELAY_SECRET="$(openssl rand -hex 24)"
        echo "RELAY_SECRET=$RELAY_SECRET" >> "$instance_dir/instance.env"
    fi

    mkdir -p "$instance_dir/selkies-home" "$instance_dir/selkies-home/Downloads"
    chown 1000:1000 "$instance_dir/selkies-home" "$instance_dir/selkies-home/Downloads"
    chmod 755 "$instance_dir" "$instance_dir/selkies-home" "$instance_dir/selkies-home/Downloads"

    bot_token="$(load_bot_env_value TELEGRAM_BOT_TOKEN || true)"
    relay_secret="$RELAY_SECRET"

    if [ "$gpu_mode" != "off" ] \
        && grep -qw avx2 /proc/cpuinfo 2>/dev/null \
        && nvidia_selkies_available; then
        gpu_args=(--runtime nvidia --gpus all)
        gpu_env=(-e "AUTO_GPU=true")
        wayland_enabled="true"
    elif [ "$gpu_mode" != "off" ] \
        && grep -qw avx2 /proc/cpuinfo 2>/dev/null \
        && [ -d /dev/dri ] \
        && render_node="$(find_dri_render_node)"; then
        gpu_args=(--device /dev/dri:/dev/dri)
        gpu_env=(-e "DRINODE=${render_node}" -e "DRI_NODE=${render_node}")
        wayland_enabled="true"
    elif [ -d /dev/dri ]; then
        gpu_args=(--device /dev/dri:/dev/dri)
    fi

    if container_exists "$CONTAINER_NAME"; then
        docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    docker_cmd run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --cpus "$MAX_CPUS" \
        --memory 2g \
        --shm-size 1g \
        --security-opt no-new-privileges=true \
        "${gpu_args[@]}" \
        "${gpu_env[@]}" \
        -p "127.0.0.1:${WEB_PORT}:3000" \
        -e "PUID=1000" \
        -e "PGID=1000" \
        -e "TZ=Europe/Moscow" \
        -e "LANG=C.UTF-8" \
        -e "LC_ALL=C.UTF-8" \
        -e "PULSE_SERVER=unix:/defaults/native" \
        -e "TITLE=Maxofon" \
        -e "SUBFOLDER=${WEB_PATH}" \
        -e "PIXELFLUX_WAYLAND=${wayland_enabled}" \
        -e "NO_GAMEPAD=true" \
        -e "SELKIES_UI_TITLE=Maxofon" \
        -e "SELKIES_AUDIO_ENABLED=true" \
        -e "SELKIES_MICROPHONE_ENABLED=false" \
        -e "SELKIES_GAMEPAD_ENABLED=false" \
        -e "SELKIES_SECOND_SCREEN=false" \
        -e "SELKIES_MANUAL_WIDTH=1280" \
        -e "SELKIES_MANUAL_HEIGHT=720" \
        -e "SELKIES_USE_CSS_SCALING=true" \
        -e "SELKIES_ENABLE_SHARING=false" \
        -e "SELKIES_ENABLE_COLLAB=false" \
        -e "SELKIES_ENABLE_SHARED=false" \
        -e "SELKIES_ENABLE_PLAYER2=false" \
        -e "SELKIES_ENABLE_PLAYER3=false" \
        -e "SELKIES_ENABLE_PLAYER4=false" \
        -e "SELKIES_FILE_TRANSFERS=none" \
        -e "SELKIES_COMMAND_ENABLED=false" \
        -e "SELKIES_UI_SHOW_LOGO=false" \
        -e "SELKIES_UI_SHOW_CORE_BUTTONS=true" \
        -e "SELKIES_UI_SIDEBAR_SHOW_FILES=false" \
        -e "SELKIES_UI_SIDEBAR_SHOW_APPS=false" \
        -e "SELKIES_UI_SIDEBAR_SHOW_SHARING=false" \
        -e "SELKIES_UI_SIDEBAR_SHOW_GAMEPADS=false" \
        -e "SELKIES_UI_SIDEBAR_SHOW_KEYBOARD_BUTTON=true" \
        -e "SELKIES_UI_SIDEBAR_SHOW_TRACKPAD=true" \
        -e "HARDEN_DESKTOP=true" \
        -e "HARDEN_OPENBOX=true" \
        -e "NO_DECOR=true" \
        -e "RESTART_APP=true" \
        -e "TG_ID=${TG_ID}" \
        -e "PHONE_NAME=${INSTANCE_NAME}" \
        -e "TELEGRAM_BOT_TOKEN=${bot_token}" \
        -e "POLMIRA_RELAY_URL=http://172.17.0.1:8788/notify" \
        -e "POLMIRA_RELAY_SECRET=${relay_secret}" \
        -e "POLMIRA_USER_HOME=/config" \
        -e "POLMIRA_WATCH_INTERNAL_FILES=no" \
        -v "${instance_dir}/selkies-home:/config" \
        "$SELKIES_IMAGE" >/dev/null
}

start_container() {
    local instance_dir="$1"
    local backend

    backend="$(env_file_value "$instance_dir/instance.env" BACKEND)"
    if [ "$backend" = "selkies" ]; then
        start_selkies_container "$instance_dir"
    else
        start_legacy_container "$instance_dir"
    fi
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
    local status ready backend downloads_dir
    backend="$(env_file_value "$instance_dir/instance.env" BACKEND)"
    backend="${backend:-novnc}"
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"

    status="$(container_status "$CONTAINER_NAME")"
    ready="$(web_ready "$WEB_PORT")"
    if [ "$backend" = "selkies" ]; then
        downloads_dir="${DOWNLOADS_DIR:-$instance_dir/selkies-home/Downloads}"
    else
        downloads_dir="${DOWNLOADS_DIR:-$instance_dir/downloads}"
    fi

    echo "PHONE_NAME=$INSTANCE_NAME"
    echo "INSTANCE_NAME=$INSTANCE_NAME"
    echo "LINUX_USER=$INSTANCE_NAME"
    echo "CONTAINER_NAME=$CONTAINER_NAME"
    echo "TG_ID=$TG_ID"
    echo "USERNAME=$USERNAME"
    echo "BACKEND=$backend"
    echo "URL=$(instance_url "$backend" "$WEB_PATH")"
    echo "VPN_ENABLED=no"
    echo "INIT_STATUS=$status"
    echo "WEB_STATUS=$status"
    echo "WEB_READY=$ready"
    echo "WEB_PORT=$WEB_PORT"
    echo "DOWNLOADS_DIR=$downloads_dir"
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
    local instance_name instance_dir access_pass password_hash web_port web_path container_name username relay_secret

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
    password_hash="$(authelia_hash_password "$access_pass")"

    mkdir -p "$instance_dir/selkies-home/Downloads"
    cat > "$instance_dir/instance.env" <<EOF
TG_ID=${tg_id}
INSTANCE_NAME=${instance_name}
CONTAINER_NAME=${container_name}
WEB_PORT=${web_port}
WEB_PATH=${web_path}
USERNAME=${username}
RELAY_SECRET=${relay_secret}
BACKEND=selkies
DOWNLOADS_DIR=${instance_dir}/selkies-home/Downloads
EOF
    printf '%s\n' "$password_hash" > "$instance_dir/authelia-password.hash"
    chmod 600 "$instance_dir/instance.env" "$instance_dir/authelia-password.hash"

    sync_authelia
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
    if [ "$(env_file_value "$instance_dir/instance.env" BACKEND)" = "selkies" ]; then
        sync_authelia
    fi
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
    sync_authelia
    delete_audit "done tg_id=$tg_id instance=$instance_name container=$CONTAINER_NAME dir=$resolved_dir"
    say_green "Контейнер удалён"
}

bot_set_password() {
    need_root
    create_dirs

    local tg_id="${1:-}"
    local username="${2:-}"
    local password="${3:-}"
    local instance_dir backend password_hash

    if [ -z "$username" ] || [ -z "$password" ]; then
        say_red "Нужно: bot-set-password TG_ID LOGIN PASSWORD"
        return 1
    fi

    if ! [[ "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        say_red "BAD_USERNAME"
        return 1
    fi

    instance_dir="$(instance_dir_or_fail "$tg_id")" || return 1
    backend="$(env_file_value "$instance_dir/instance.env" BACKEND)"
    sed -i "/^USERNAME=/d" "$instance_dir/instance.env"
    echo "USERNAME=$username" >> "$instance_dir/instance.env"
    if [ "$backend" = "selkies" ]; then
        password_hash="$(authelia_hash_password "$password")"
        printf '%s\n' "$password_hash" > "$instance_dir/authelia-password.hash"
        chmod 600 "$instance_dir/authelia-password.hash"
        sync_authelia
        echo "PASSKEY_RESET_REQUIRED=yes"
    else
        write_htpasswd "$instance_dir" "$username" "$password"
    fi
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

    if [ "$(env_file_value "$instance_dir/instance.env" BACKEND)" = "selkies" ]; then
        docker_cmd exec -u abc "$CONTAINER_NAME" bash -lc '
            set -e
            pid="$(pgrep -o -f "/usr/share/max/bin/max")"
            while IFS= read -r -d "" item; do
                case "$item" in
                    DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*) export "$item" ;;
                esac
            done < "/proc/${pid}/environ"
            notify-send "MAX" "Тестовое сообщение Polmira"
        '
    else
        docker_cmd exec -u polmira "$CONTAINER_NAME" bash -lc '
            set -e
            [ -f /tmp/polmira-session.env ] && source /tmp/polmira-session.env
            export DISPLAY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
            notify-send "MAX" "Тестовое сообщение Polmira"
        '
    fi
    say_green "Тестовое уведомление отправлено в DBus"
}

bot_input() {
    need_root
    create_dirs

    local instance_dir input_file input_size backend
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    # shellcheck disable=SC1091
    source "$instance_dir/instance.env"
    backend="$(env_file_value "$instance_dir/instance.env" BACKEND)"

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

    if [ "$backend" = "selkies" ]; then
        if ! docker_cmd exec -i -u abc \
            -e LANG=C.UTF-8 \
            "$CONTAINER_NAME" bash -lc '
                set -e
                pid="$(pgrep -n -f "/usr/share/max/bin/max")"
                while IFS= read -r -d "" item; do
                    case "$item" in
                        DISPLAY=*|XAUTHORITY=*) export "$item" ;;
                    esac
                done < "/proc/${pid}/environ"
                xclip -selection clipboard -in
                sleep 0.08
                xdotool key --clearmodifiers ctrl+v
            ' < "$input_file"; then
            rm -f "$input_file"
            say_red "INPUT_FAILED"
            return 1
        fi
    elif ! docker_cmd exec -i -u polmira \
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

    local env_file instance_dir backend
    printf "%-18s %-14s %-9s %-10s %-8s %s\n" "TG_ID" "NAME" "BACKEND" "STATUS" "PORT" "URL"
    while IFS= read -r env_file; do
        instance_dir="$(dirname "$env_file")"
        backend="$(env_file_value "$env_file" BACKEND)"
        backend="${backend:-novnc}"
        # shellcheck disable=SC1090
        source "$env_file"
        printf "%-18s %-14s %-9s %-10s %-8s %s\n" \
            "$TG_ID" "$INSTANCE_NAME" "$backend" "$(container_status "$CONTAINER_NAME")" \
            "$WEB_PORT" "$(instance_url "$backend" "$WEB_PATH")"
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
    ensure_nvidia_container_runtime
    ensure_selkies_image
    ensure_authelia_image
    sync_authelia
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
