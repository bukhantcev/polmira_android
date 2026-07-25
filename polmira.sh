#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${POLMIRA_APP_DIR:-/opt/polmira-docker}"
INSTANCES_DIR="$APP_DIR/instances"
CONFIG_FILE="$APP_DIR/config.env"
TG_ALLOWED_FILE="$APP_DIR/tg-allowed.txt"
BOT_ENV_FILE="$APP_DIR/bot/.env"
NGINX_ROOT="${POLMIRA_NGINX_ROOT:-/etc/nginx}"
NGINX_SITE="$NGINX_ROOT/sites-available/polmira"
NGINX_SITE_LINK="$NGINX_ROOT/sites-enabled/polmira"
NGINX_SNIPPETS_DIR="$NGINX_ROOT/polmira"
MAX_IMAGE="${POLMIRA_MAX_IMAGE:-chtotos/polmira_max_selkies:2026.07.24-unified8}"
BOT_IMAGE="${POLMIRA_BOT_IMAGE:-chtotos/polmira_bot:2026.07.24-unified2}"
SOURCE_ARCHIVE="${POLMIRA_SOURCE_ARCHIVE:-https://github.com/bukhantcev/polmira_android/archive/refs/heads/master.tar.gz}"
AUTHELIA_IMAGE="${POLMIRA_AUTHELIA_IMAGE:-authelia/authelia:4.39.20}"
AUTHELIA_DIR="$APP_DIR/authelia"
AUTHELIA_CONTAINER="polmira-authelia"
AUTHELIA_PORT=9091
MAX_CPUS="${POLMIRA_MAX_CPUS:-0.75}"
MAX_MEMORY="${POLMIRA_MAX_MEMORY:-2g}"
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

canonical_path() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

install_self() {
    local source_path

    source_path="$(canonical_path "$0")"
    if [ "$source_path" != "/usr/local/bin/polmira" ]; then
        install -m 0755 "$source_path" /usr/local/bin/polmira
    fi
}

install_host_dependencies() {
    if [ "$(uname -m)" != "x86_64" ]; then
        say_red "MAX для Linux требует сервер amd64/x86_64"
        return 1
    fi

    if ! exists apt-get; then
        say_red "Автоматическая установка поддерживает Debian/Ubuntu с apt"
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        apache2-utils \
        ca-certificates \
        curl \
        nginx \
        openssl \
        python3
    if ! exists docker; then
        apt-get install -y --no-install-recommends docker.io
    fi
    systemctl enable --now docker nginx
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
    mkdir -p \
        "$APP_DIR" \
        "$APP_DIR/bot" \
        "$APP_DIR/state" \
        "$INSTANCES_DIR" \
        "$NGINX_SNIPPETS_DIR" \
        "$AUTHELIA_DIR"
    touch "$TG_ALLOWED_FILE"
    chmod 700 "$APP_DIR/state"
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
        say_red "PUBLIC_HOST не задан. Запусти: polmira install"
        return 1
    fi
}

configure_public_access() {
    load_config

    local value
    if [ -z "${PUBLIC_HOST:-}" ]; then
        read -r -p "Домен Maxofon, например max.example.com: " value
        PUBLIC_HOST="$value"
    fi

    require_public_host
    if ! [[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        say_red "Некорректный домен"
        return 1
    fi

    read -r -p "Использовать HTTPS? [yes/no] (${USE_HTTPS:-yes}): " value
    USE_HTTPS="${value:-${USE_HTTPS:-yes}}"
    if [ "$USE_HTTPS" != "yes" ] && [ "$USE_HTTPS" != "no" ]; then
        say_red "USE_HTTPS должен быть yes или no"
        return 1
    fi

    if [ "$USE_HTTPS" = "yes" ]; then
        local default_cert default_key
        default_cert="/root/.acme.sh/${PUBLIC_HOST}_ecc/fullchain.cer"
        default_key="/root/.acme.sh/${PUBLIC_HOST}_ecc/${PUBLIC_HOST}.key"

        read -r -p "Путь к SSL cert (${SSL_CERT:-$default_cert}): " value
        SSL_CERT="${value:-${SSL_CERT:-$default_cert}}"

        read -r -p "Путь к SSL key (${SSL_KEY:-$default_key}): " value
        SSL_KEY="${value:-${SSL_KEY:-$default_key}}"
        if ! [[ "$SSL_CERT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
            || ! [[ "$SSL_KEY" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            say_red "Некорректный путь к сертификату"
            return 1
        fi
        [ -f "$SSL_CERT" ] || { say_red "Сертификат не найден: $SSL_CERT"; return 1; }
        [ -f "$SSL_KEY" ] || { say_red "Ключ не найден: $SSL_KEY"; return 1; }
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

configure_bot() {
    local current_token current_proxy current_relay token proxy relay_secret

    create_dirs
    current_token="$(load_bot_env_value TELEGRAM_BOT_TOKEN || true)"
    current_proxy="$(load_bot_env_value TELEGRAM_PROXY || true)"
    current_relay="$(load_bot_env_value POLMIRA_RELAY_SECRET || true)"
    token="${POLMIRA_TELEGRAM_BOT_TOKEN:-$current_token}"
    proxy="${POLMIRA_TELEGRAM_PROXY:-$current_proxy}"
    relay_secret="$current_relay"

    if [ -z "$token" ]; then
        read -r -s -p "Telegram bot token: " token
        echo
    fi
    if [ -z "$token" ]; then
        say_red "Telegram bot token пустой"
        return 1
    fi

    if [ -t 0 ] && [ -z "${POLMIRA_TELEGRAM_PROXY+x}" ]; then
        local entered_proxy
        read -r -p "HTTP/SOCKS proxy для Telegram и Web Push (${current_proxy:-без proxy}): " entered_proxy
        proxy="${entered_proxy:-$current_proxy}"
    fi
    relay_secret="${relay_secret:-$(openssl rand -hex 24)}"

    cat > "$BOT_ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${token}
TELEGRAM_PROXY=${proxy}
WEB_PUSH_PROXY=${proxy}
PUBLIC_HOST=${PUBLIC_HOST}
POLMIRA_ALLOWED_FILE=${TG_ALLOWED_FILE}
POLMIRA_RELAY_SECRET=${relay_secret}
POLMIRA_RELAY_BIND=172.17.0.1
POLMIRA_RELAY_PORT=8788
EOF
    chmod 600 "$BOT_ENV_FILE"
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

instance_url() {
    local web_path="$1"
    echo "$(public_base_url)${web_path}"
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

username_used_by_other() {
    local username="$1"
    local owner_tg_id="$2"
    local env_file env_username env_tg_id

    while IFS= read -r env_file; do
        env_username="$(env_file_value "$env_file" USERNAME)"
        env_tg_id="$(env_file_value "$env_file" TG_ID)"
        if [ "$env_username" = "$username" ] && [ "$env_tg_id" != "$owner_tg_id" ]; then
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

remove_owner_state() {
    local tg_id="$1"
    local state_file="$APP_DIR/state/notification-routing.json"

    [ -f "$state_file" ] || return 0
    python3 - "$state_file" "$tg_id" <<'PY'
import json
import os
import sys
import tempfile

path, tg_id = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as source:
        state = json.load(source)
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
profiles = state.get("profiles")
if not isinstance(profiles, dict) or profiles.pop(tg_id, None) is None:
    raise SystemExit(0)
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".notification-routing-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        json.dump(state, target, ensure_ascii=False, indent=2, sort_keys=True)
        target.flush()
        os.fsync(target.fileno())
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

validate_instance_dir_for_tg_id() {
    local tg_id="$1"
    local instance_dir="$2"
    local base resolved expected_name

    [ -n "$tg_id" ] || { say_red "TG_ID пустой" >&2; return 1; }
    [ -n "$instance_dir" ] || { say_red "INSTANCE_DIR пустой" >&2; return 1; }
    [ -f "$instance_dir/instance.env" ] || { say_red "INSTANCE_ENV_NOT_FOUND" >&2; return 1; }

    base="$(canonical_path "$INSTANCES_DIR")"
    resolved="$(canonical_path "$instance_dir")"
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

env_file_value() {
    local file="$1"
    local key="$2"

    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

update_instance_env() {
    local env_file="$1"
    shift
    python3 - "$env_file" "$@" <<'PY'
import os
import sys
import tempfile

path = sys.argv[1]
operations = sys.argv[2:]
updates = {}
remove = set()
for operation in operations:
    if "=" in operation:
        key, value = operation.split("=", 1)
        updates[key] = value
        remove.add(key)
    else:
        remove.add(operation)

with open(path, "r", encoding="utf-8") as source:
    lines = source.read().splitlines()
kept = [
    line
    for line in lines
    if not any(line.startswith(f"{key}=") for key in remove)
]
kept.extend(f"{key}={value}" for key, value in updates.items())

directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".instance-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        target.write("\n".join(kept) + "\n")
        target.flush()
        os.fsync(target.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

load_instance_env() {
    local instance_dir="$1"
    local env_file="$instance_dir/instance.env"
    local expected_name expected_container resolved_dir resolved_downloads

    TG_ID="$(env_file_value "$env_file" TG_ID)"
    INSTANCE_NAME="$(env_file_value "$env_file" INSTANCE_NAME)"
    CONTAINER_NAME="$(env_file_value "$env_file" CONTAINER_NAME)"
    WEB_PORT="$(env_file_value "$env_file" WEB_PORT)"
    WEB_PATH="$(env_file_value "$env_file" WEB_PATH)"
    USERNAME="$(env_file_value "$env_file" USERNAME)"
    RELAY_SECRET="$(env_file_value "$env_file" RELAY_SECRET)"
    DOWNLOADS_DIR="$(env_file_value "$env_file" DOWNLOADS_DIR)"

    validate_tg_id "$TG_ID" || { say_red "BAD_INSTANCE_TG_ID" >&2; return 1; }
    expected_name="$(safe_name_for_tg "$TG_ID")"
    expected_container="polmira-max-${TG_ID}"
    [ "$INSTANCE_NAME" = "$expected_name" ] \
        || { say_red "BAD_INSTANCE_NAME" >&2; return 1; }
    [ "$CONTAINER_NAME" = "$expected_container" ] \
        || { say_red "BAD_CONTAINER_NAME" >&2; return 1; }
    [[ "$WEB_PORT" =~ ^[0-9]+$ ]] \
        && [ "$WEB_PORT" -ge "$WEB_RANGE_START" ] \
        && [ "$WEB_PORT" -le "$WEB_RANGE_END" ] \
        || { say_red "BAD_WEB_PORT" >&2; return 1; }
    [[ "$WEB_PATH" =~ ^/polmira/[a-f0-9]{16}/$ ]] \
        || { say_red "BAD_WEB_PATH" >&2; return 1; }
    [[ "$USERNAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
        || { say_red "BAD_USERNAME" >&2; return 1; }
    [ -z "$RELAY_SECRET" ] || [[ "$RELAY_SECRET" =~ ^[a-f0-9]{48}$ ]] \
        || { say_red "BAD_RELAY_SECRET" >&2; return 1; }

    resolved_dir="$(canonical_path "$instance_dir")"
    if [ -n "$DOWNLOADS_DIR" ]; then
        resolved_downloads="$(canonical_path "$DOWNLOADS_DIR")"
        case "$resolved_downloads" in
            "$resolved_dir"/*) ;;
            *) say_red "BAD_DOWNLOADS_DIR" >&2; return 1 ;;
        esac
    fi
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
    local env_file instance_dir username password_hash

    {
        echo "users:"
        while IFS= read -r env_file; do
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
    local env_file web_path username

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
      expiration: "10m"
      inactivity: "10s"
      remember_me: "0"

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
    start_authelia
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

    rm -f "$NGINX_ROOT/sites-enabled/default" \
        "$NGINX_ROOT/sites-enabled/polmira" \
        "$NGINX_ROOT/sites-enabled/polmira-docker" \
        "$NGINX_ROOT/sites-enabled/polmira-linux" 2>/dev/null || true
    ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    nginx_cmd -t
    systemctl reload nginx
}

write_instance_nginx_conf() {
    local instance_dir="$1"
    local web_path_without_slash
    load_instance_env "$instance_dir" || return 1
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

location = ${WEB_PATH}media-state {
    auth_request /internal/authelia/authz;
    auth_request_set \$redirection_url \$upstream_http_location;
    error_page 401 =302 \$redirection_url;

    proxy_http_version 1.1;
    proxy_set_header X-Polmira-Tg-Id "${TG_ID}";
    proxy_set_header X-Polmira-Secret "${RELAY_SECRET}";
    proxy_read_timeout 5s;

    proxy_pass http://172.17.0.1:8788/media-state;
}

location = ${WEB_PATH}push/public-key {
    auth_request /internal/authelia/authz;
    auth_request_set \$redirection_url \$upstream_http_location;
    error_page 401 =302 \$redirection_url;

    proxy_http_version 1.1;
    proxy_set_header X-Polmira-Tg-Id "${TG_ID}";
    proxy_set_header X-Polmira-Secret "${RELAY_SECRET}";
    proxy_read_timeout 15s;

    proxy_pass http://172.17.0.1:8788/push/public-key;
}

location = ${WEB_PATH}push/subscribe {
    auth_request /internal/authelia/authz;
    auth_request_set \$redirection_url \$upstream_http_location;
    error_page 401 =302 \$redirection_url;
    client_max_body_size 64k;

    proxy_http_version 1.1;
    proxy_set_header X-Polmira-Tg-Id "${TG_ID}";
    proxy_set_header X-Polmira-Secret "${RELAY_SECRET}";
    proxy_set_header Content-Type \$content_type;
    proxy_read_timeout 15s;

    proxy_pass http://172.17.0.1:8788/push/subscribe;
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

build_images_from_source() {
    local force="${1:-no}"
    local build_dir archive_file

    build_dir="$(mktemp -d)"
    archive_file="$build_dir/source.tar.gz"
    say_green "Скачиваю исходники Maxofon для локальной сборки"
    curl -fsSL "$SOURCE_ARCHIVE" -o "$archive_file"
    mkdir -p "$build_dir/source"
    tar -xzf "$archive_file" --strip-components=1 -C "$build_dir/source"

    if [ "$force" = "yes" ] || ! docker_cmd image inspect "$MAX_IMAGE" >/dev/null 2>&1; then
        docker_cmd build \
            -f "$build_dir/source/Dockerfile.selkies" \
            -t "$MAX_IMAGE" \
            "$build_dir/source"
    fi
    if [ "$force" = "yes" ] || ! docker_cmd image inspect "$BOT_IMAGE" >/dev/null 2>&1; then
        docker_cmd build \
            -f "$build_dir/source/Dockerfile.bot" \
            -t "$BOT_IMAGE" \
            "$build_dir/source"
    fi
    rm -rf "$build_dir"
}

ensure_images() {
    if ! docker_cmd image inspect "$MAX_IMAGE" >/dev/null 2>&1; then
        docker_cmd pull "$MAX_IMAGE" || true
    fi
    if ! docker_cmd image inspect "$BOT_IMAGE" >/dev/null 2>&1; then
        docker_cmd pull "$BOT_IMAGE" || true
    fi
    if ! docker_cmd image inspect "$MAX_IMAGE" >/dev/null 2>&1 \
        || ! docker_cmd image inspect "$BOT_IMAGE" >/dev/null 2>&1; then
        build_images_from_source
    fi
    ensure_authelia_image
}

pull_images() {
    local pulled_all="yes"

    docker_cmd pull "$MAX_IMAGE" || pulled_all="no"
    docker_cmd pull "$BOT_IMAGE" || pulled_all="no"
    docker_cmd pull "$AUTHELIA_IMAGE"
    if [ "$pulled_all" != "yes" ]; then
        build_images_from_source yes
    fi
}

container_exists() {
    local container="$1"
    docker_cmd ps -a --format '{{.Names}}' | grep -Fxq "$container"
}

start_bot() {
    ensure_images
    ensure_relay_secret

    docker_cmd rm -f polmira-bot >/dev/null 2>&1 || true
    docker_cmd run -d \
        --name polmira-bot \
        --restart unless-stopped \
        --privileged \
        --network host \
        --pid host \
        --env-file "$BOT_ENV_FILE" \
        -e "POLMIRA_BOT_ENV=${BOT_ENV_FILE}" \
        -e "POLMIRA_CMD=/app/host-polmira" \
        -e "POLMIRA_APP_DIR=${APP_DIR}" \
        -e "POLMIRA_USE_SUDO=no" \
        -v "${APP_DIR}:${APP_DIR}" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /etc/nginx:/etc/nginx \
        "$BOT_IMAGE" >/dev/null
}

prepare_profile_layout() {
    local instance_dir="$1"
    local home="$instance_dir/selkies-home"

    mkdir -p "$home/.config" "$home/.local/share" "$home/Downloads"
    if [ -d "$instance_dir/max-home" ] && [ ! -e "$home/.config/max" ]; then
        cp -a "$instance_dir/max-home" "$home/.config/max"
    fi
    if [ -d "$instance_dir/oneme-data" ] && [ ! -e "$home/.local/share/ONEME" ]; then
        cp -a "$instance_dir/oneme-data" "$home/.local/share/ONEME"
    fi
    if [ -d "$instance_dir/downloads" ]; then
        cp -an "$instance_dir/downloads/." "$home/Downloads/" 2>/dev/null || true
    fi
    chown -R 1000:1000 "$home"
}

start_container() {
    local instance_dir="$1"
    local bot_token relay_secret render_node
    local wayland_enabled="false"
    local -a gpu_args=()
    local -a gpu_env=()
    load_instance_env "$instance_dir" || return 1

    ensure_images
    if [ -z "${RELAY_SECRET:-}" ]; then
        RELAY_SECRET="$(openssl rand -hex 24)"
        echo "RELAY_SECRET=$RELAY_SECRET" >> "$instance_dir/instance.env"
    fi

    bot_token="$(load_bot_env_value TELEGRAM_BOT_TOKEN || true)"
    relay_secret="$RELAY_SECRET"

    if container_exists "$CONTAINER_NAME"; then
        docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    prepare_profile_layout "$instance_dir"
    chmod 755 "$instance_dir" "$instance_dir/selkies-home" "$instance_dir/selkies-home/Downloads"

    if grep -qw avx2 /proc/cpuinfo 2>/dev/null \
        && nvidia_selkies_available; then
        gpu_args=(--runtime nvidia --gpus all)
        gpu_env=(-e "AUTO_GPU=true")
        wayland_enabled="true"
    elif grep -qw avx2 /proc/cpuinfo 2>/dev/null \
        && [ -d /dev/dri ] \
        && render_node="$(find_dri_render_node)"; then
        gpu_args=(--device /dev/dri:/dev/dri)
        gpu_env=(-e "DRINODE=${render_node}" -e "DRI_NODE=${render_node}")
        wayland_enabled="true"
    elif [ -d /dev/dri ]; then
        gpu_args=(--device /dev/dri:/dev/dri)
    fi

    docker_cmd run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --cpus "$MAX_CPUS" \
        --memory "$MAX_MEMORY" \
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
        -e "SELKIES_SCALING_DPI=96" \
        -e "SELKIES_USE_CSS_SCALING=true" \
        -e "SELKIES_ENCODER=x264enc" \
        -e "SELKIES_USE_CPU=false|locked" \
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
        -e "TELEGRAM_BOT_TOKEN=${bot_token}" \
        -e "POLMIRA_RELAY_URL=http://172.17.0.1:8788/notify" \
        -e "POLMIRA_RELAY_SECRET=${relay_secret}" \
        -e "POLMIRA_USER_HOME=/config" \
        -e "POLMIRA_WATCH_INTERNAL_FILES=no" \
        -v "${instance_dir}/selkies-home:/config" \
        "$MAX_IMAGE" >/dev/null
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
    local status ready downloads_dir
    load_instance_env "$instance_dir" || return 1

    status="$(container_status "$CONTAINER_NAME")"
    ready="$(web_ready "$WEB_PORT")"
    downloads_dir="${DOWNLOADS_DIR:-$instance_dir/selkies-home/Downloads}"

    echo "INSTANCE_NAME=$INSTANCE_NAME"
    echo "CONTAINER_NAME=$CONTAINER_NAME"
    echo "TG_ID=$TG_ID"
    echo "USERNAME=$USERNAME"
    echo "URL=$(instance_url "$WEB_PATH")"
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
        echo "NO_INSTANCE=1"
        return 0
    fi

    instance_info_by_dir "$instance_dir"
}

bot_create_instance() {
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

bot_start_instance() {
    need_root
    create_dirs
    load_config
    write_nginx_main_config

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    sync_authelia
    write_instance_nginx_conf "$instance_dir"
    start_container "$instance_dir"
    sleep 1
    instance_info_by_dir "$instance_dir"
}

bot_stop_instance() {
    need_root
    create_dirs

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    load_instance_env "$instance_dir" || return 1
    docker_cmd stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    instance_info_by_dir "$instance_dir"
}

bot_delete_instance() {
    need_root
    create_dirs

    local tg_id instance_dir instance_name resolved_dir
    tg_id="${1:-}"
    instance_dir="$(instance_dir_or_fail "$tg_id")" || return 1
    validate_instance_dir_for_tg_id "$tg_id" "$instance_dir" || return 1
    resolved_dir="$(canonical_path "$instance_dir")"

    load_instance_env "$instance_dir" || return 1
    instance_name="$INSTANCE_NAME"

    delete_audit "start tg_id=$tg_id instance=$instance_name container=$CONTAINER_NAME dir=$resolved_dir"
    docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    remove_instance_nginx_conf "$instance_name" || true
    rm -rf "$instance_dir"
    remove_owner_state "$tg_id"
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
    local instance_dir password_hash

    if [ -z "$username" ] || [ -z "$password" ]; then
        say_red "Нужно: bot-set-password TG_ID LOGIN PASSWORD"
        return 1
    fi

    if ! [[ "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
        say_red "BAD_USERNAME"
        return 1
    fi
    if username_used_by_other "$username" "$tg_id"; then
        say_red "USERNAME_ALREADY_USED"
        return 1
    fi

    instance_dir="$(instance_dir_or_fail "$tg_id")" || return 1
    update_instance_env "$instance_dir/instance.env" "USERNAME=$username"
    password_hash="$(authelia_hash_password "$password")"
    printf '%s\n' "$password_hash" > "$instance_dir/authelia-password.hash"
    chmod 600 "$instance_dir/authelia-password.hash"
    sync_authelia
    echo "PASSKEY_RESET_REQUIRED=yes"
    instance_info_by_dir "$instance_dir"
}

bot_notify_test() {
    need_root
    create_dirs

    local instance_dir
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    load_instance_env "$instance_dir" || return 1

    if [ "$(container_status "$CONTAINER_NAME")" != "running" ]; then
        say_red "CONTAINER_NOT_RUNNING"
        return 1
    fi

    docker_cmd exec -u abc "$CONTAINER_NAME" bash -lc '
        set -e
        pid="$(pgrep -o -f "^/usr/share/max/bin/max( |$)")"
        while IFS= read -r -d "" item; do
            case "$item" in
                DISPLAY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*) export "$item" ;;
            esac
        done < "/proc/${pid}/environ"
        notify-send "MAX" "Тестовое сообщение Polmira"
    '
    say_green "Тестовое уведомление отправлено в DBus"
}

bot_input() {
    need_root
    create_dirs

    local instance_dir input_file input_size
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    load_instance_env "$instance_dir" || return 1

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

    if ! docker_cmd exec -i -u abc \
        -e LANG=C.UTF-8 \
        "$CONTAINER_NAME" bash -lc '
            set -e
            pid="$(pgrep -o -f "^/usr/share/max/bin/max( |$)")"
            while IFS= read -r -d "" item; do
                case "$item" in
                    DISPLAY=*|XAUTHORITY=*) export "$item" ;;
                esac
            done < "/proc/${pid}/environ"
            xclip -selection clipboard -in
            sleep 0.08
            xdotool keyup Shift_L Shift_R Control_L Control_R \
                Alt_L Alt_R Super_L Super_R 2>/dev/null || true
            xdotool key --clearmodifiers ctrl+v
        ' < "$input_file"; then
        rm -f "$input_file"
        say_red "INPUT_FAILED"
        return 1
    fi

    rm -f "$input_file"
}

bot_media_state() {
    need_root
    create_dirs

    local instance_dir now state_file state state_mtime
    instance_dir="$(instance_dir_or_fail "${1:-}")" || return 1
    state_file="$instance_dir/selkies-home/.cache/polmira/media-state"
    state="$(head -n 1 "$state_file" 2>/dev/null || true)"
    state_mtime="$(stat -c %Y "$state_file" 2>/dev/null || echo 0)"
    now="$(date +%s)"

    if [ "$state" = "yes" ] && [ $((now - state_mtime)) -le 4 ]; then
        echo "MEDIA_ACTIVE=yes"
    else
        echo "MEDIA_ACTIVE=no"
    fi
}

list_instances() {
    create_dirs

    local env_file instance_dir
    printf "%-18s %-14s %-10s %-8s %s\n" "TG_ID" "NAME" "STATUS" "PORT" "URL"
    while IFS= read -r env_file; do
        instance_dir="$(dirname "$env_file")"
        load_instance_env "$instance_dir" || continue
        printf "%-18s %-14s %-10s %-8s %s\n" \
            "$TG_ID" "$INSTANCE_NAME" "$(container_status "$CONTAINER_NAME")" \
            "$WEB_PORT" "$(instance_url "$WEB_PATH")"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)
}

normalize_instance() {
    local instance_dir="$1"
    local username password password_hash
    local env_file="$instance_dir/instance.env"

    TG_ID="$(env_file_value "$env_file" TG_ID)"
    validate_tg_id "$TG_ID" || { say_red "BAD_INSTANCE_TG_ID" >&2; return 1; }

    username="$(env_file_value "$env_file" USERNAME)"
    username="${username:-$(safe_name_for_tg "$TG_ID")}"
    update_instance_env \
        "$instance_dir/instance.env" \
        "USERNAME=${username}" \
        "DOWNLOADS_DIR=${instance_dir}/selkies-home/Downloads"
    load_instance_env "$instance_dir" || return 1

    if [ ! -s "$instance_dir/authelia-password.hash" ]; then
        password="$(openssl rand -hex 8)"
        password_hash="$(authelia_hash_password "$password")"
        printf '%s\n' "$password_hash" > "$instance_dir/authelia-password.hash"
        printf '%s\t%s\t%s\n' "$TG_ID" "$username" "$password"
    fi
    chmod 600 "$instance_dir/instance.env" "$instance_dir/authelia-password.hash"
}

deliver_generated_credentials() {
    local credentials_file="$1"

    [ -s "$credentials_file" ] || return 0
    if [ "$(container_status polmira-bot)" != "running" ]; then
        return 1
    fi

    docker_cmd exec -i polmira-bot python3 -c '
import sys
import main

for raw in sys.stdin:
    tg_id, username, password = raw.rstrip("\n").split("\t", 2)
    main.send_message(
        tg_id,
        "Maxofon переведён на единую web-версию.\n"
        f"Новый логин: {username}\n"
        f"Новый пароль: {password}\n\n"
        "Открой /start, чтобы получить свою ссылку.",
    )
' < "$credentials_file"
}

recreate_all_instances() {
    need_root
    create_dirs
    load_config
    ensure_images

    local env_file instance_dir credentials_file generated
    credentials_file="$APP_DIR/migration-credentials.txt"
    : > "$credentials_file"

    while IFS= read -r env_file; do
        instance_dir="$(dirname "$env_file")"
        generated="$(normalize_instance "$instance_dir")"
        [ -z "$generated" ] || printf '%s\n' "$generated" >> "$credentials_file"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    chmod 600 "$credentials_file"
    sync_authelia
    write_nginx_main_config

    while IFS= read -r env_file; do
        instance_dir="$(dirname "$env_file")"
        write_instance_nginx_conf "$instance_dir"
        start_container "$instance_dir"
    done < <(find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | sort)

    if [ -s "$credentials_file" ]; then
        if deliver_generated_credentials "$credentials_file"; then
            rm -f "$credentials_file"
            say_green "Новые пароли отправлены владельцам в Telegram"
        else
            say_green "Не удалось разослать новые пароли; файл сохранён: $credentials_file"
        fi
    else
        rm -f "$credentials_file"
    fi
}

update_polmira() {
    need_root
    install_self
    create_dirs
    pull_images
    ensure_nvidia_container_runtime
    start_bot
    recreate_all_instances
    say_green "Maxofon обновлён; все контейнеры работают на одной Selkies-схеме"
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
        echo "8) Обновить Maxofon и все контейнеры"
        echo "9) Разрешить Telegram ID"
        echo "10) Запретить Telegram ID"
        echo "11) Список разрешённых Telegram ID"
        echo "12) Повторно настроить домен и бота"
        echo "0) Выход"
        echo

        local choice tg_id login password instance_dir
        read -r -p "Выбор: " choice

        case "$choice" in
            1)
                tg_id="$(prompt_value "Telegram ID")"
                bot_create_instance "$tg_id"
                ;;
            2)
                tg_id="$(prompt_value "Telegram ID")"
                bot_start_instance "$tg_id"
                ;;
            3)
                tg_id="$(prompt_value "Telegram ID")"
                bot_stop_instance "$tg_id"
                ;;
            4)
                tg_id="$(prompt_value "Telegram ID")"
                read -r -p "Точно удалить? Напиши YES: " confirm
                [ "${confirm:-}" = "YES" ] && bot_delete_instance "$tg_id"
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
                    if load_instance_env "$instance_dir"; then
                        docker_cmd logs --tail 120 "$CONTAINER_NAME"
                    fi
                fi
                ;;
            8)
                update_polmira
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
            12)
                install_polmira
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

install_polmira() {
    need_root
    install_host_dependencies
    install_self
    create_dirs
    configure_public_access
    configure_bot
    if [ ! -s "$TG_ALLOWED_FILE" ]; then
        local admin_tg_id
        admin_tg_id="$(prompt_value "Telegram ID администратора")"
        [ -z "$admin_tg_id" ] || allow_tg_id "$admin_tg_id"
    fi
    pull_images
    write_nginx_main_config
    ensure_nvidia_container_runtime
    sync_authelia
    start_bot
    recreate_all_instances
    say_green "Maxofon установлен. Команда управления: polmira"
}

cli_dispatch() {
    local command="${1:-}"

    case "$command" in
        bot-status) shift; bot_status "$@" ;;
        bot-create) shift; bot_create_instance "$@" ;;
        bot-start) shift; bot_start_instance "$@" ;;
        bot-stop) shift; bot_stop_instance "$@" ;;
        bot-delete) shift; bot_delete_instance "$@" ;;
        bot-set-password) shift; bot_set_password "$@" ;;
        bot-notify-test) shift; bot_notify_test "$@" ;;
        bot-input) shift; bot_input "$@" ;;
        bot-media-state) shift; bot_media_state "$@" ;;
        restart-bot) shift; need_root; create_dirs; start_bot "$@" ;;
        allow) shift; allow_tg_id "$@" ;;
        disallow) shift; disallow_tg_id "$@" ;;
        allowed) shift; list_allowed_ids "$@" ;;
        list) shift; list_instances "$@" ;;
        refresh-nginx) shift; refresh_nginx "$@" ;;
        recreate-all) shift; recreate_all_instances "$@" ;;
        update) shift; update_polmira "$@" ;;
        menu) shift; interactive_menu ;;
        "")
            if [ -f "$CONFIG_FILE" ]; then
                interactive_menu
            else
                install_polmira
                interactive_menu
            fi
            ;;
        install) shift; install_polmira "$@" ;;
        *) return 1 ;;
    esac
}

main() {
    if cli_dispatch "$@"; then
        return 0
    fi

    cat <<EOF
Использование:
  polmira install
  polmira update
  polmira recreate-all
  polmira bot-status TG_ID
  polmira bot-create TG_ID
  polmira bot-start TG_ID
  polmira bot-stop TG_ID
  polmira bot-delete TG_ID
  polmira bot-set-password TG_ID LOGIN PASSWORD
  polmira bot-notify-test TG_ID
  polmira bot-input TG_ID < UTF8_TEXT_FILE
  polmira bot-media-state TG_ID
  polmira restart-bot
  polmira allow TG_ID
  polmira disallow TG_ID
  polmira allowed
  polmira list
  polmira refresh-nginx
  polmira menu
EOF
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
