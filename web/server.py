#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import shutil
import shlex
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


APP_DIR = Path(os.environ.get("POLMIRA_APP_DIR", "/opt/polmira"))
PHONES_DIR = APP_DIR / "phones"
APPS_DIR = APP_DIR / "apps"
CONFIG_FILE = APP_DIR / "config.env"
ALLOWED_FILE = APP_DIR / "tg-allowed.txt"
BOT_ENV_FILE = APP_DIR / "bot" / ".env"
WEB_ENV_FILE = APP_DIR / "web" / ".env"
SENT_FILES_STATE = APP_DIR / "bot" / "sent-files.json"
POLMIRA_CMD = os.environ.get("POLMIRA_CMD", "/usr/local/bin/polmira")
HOST = os.environ.get("POLMIRA_WEB_HOST", "0.0.0.0")
PORT = int(os.environ.get("POLMIRA_WEB_PORT", "8787"))
USERNAME = os.environ.get("POLMIRA_WEB_USER", "admin")
PASSWORD = os.environ.get("POLMIRA_WEB_PASSWORD", "polmira")
COMMAND_TIMEOUT = int(os.environ.get("POLMIRA_WEB_COMMAND_TIMEOUT", "900"))


def read_env_file(path):
    data = {}

    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()

        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")

    return data


def load_web_env_runtime():
    global USERNAME, PASSWORD

    web_env = read_env_file(WEB_ENV_FILE)
    USERNAME = web_env.get("POLMIRA_WEB_USER", USERNAME)
    PASSWORD = web_env.get("POLMIRA_WEB_PASSWORD", PASSWORD)


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def env_set(path, key, value):
    lines = []

    if path.exists():
        lines = [
            line
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines()
            if not line.startswith(f"{key}=")
        ]

    lines.append(f"{key}={value}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    path.chmod(0o600)


def telegram_config():
    bot_env = read_env_file(BOT_ENV_FILE)
    token = bot_env.get("TELEGRAM_BOT_TOKEN", os.environ.get("TELEGRAM_BOT_TOKEN", ""))
    proxy = bot_env.get("TELEGRAM_PROXY", os.environ.get("TELEGRAM_PROXY", ""))
    max_proxy = bot_env.get("MAX_DOWNLOAD_PROXY", os.environ.get("MAX_DOWNLOAD_PROXY", proxy))

    return token, proxy, max_proxy


def build_opener(proxy):
    if not proxy:
        return urllib.request.build_opener()

    return urllib.request.build_opener(urllib.request.ProxyHandler({
        "http": proxy,
        "https": proxy,
    }))


def telegram_multipart(method, fields, files):
    token, proxy, _max_proxy = telegram_config()

    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN не задан в /opt/polmira/bot/.env")

    boundary = f"----PolmiraWebBoundary{int(time.time() * 1000)}"
    body = bytearray()

    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(str(value).encode("utf-8"))
        body.extend(b"\r\n")

    for name, path in files.items():
        file_path = Path(path)
        mime_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(
            f'Content-Disposition: form-data; name="{name}"; filename="{file_path.name}"\r\n'.encode()
        )
        body.extend(f"Content-Type: {mime_type}\r\n\r\n".encode())
        body.extend(file_path.read_bytes())
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode())

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )

    with build_opener(proxy).open(req, timeout=180) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    if not payload.get("ok"):
        raise RuntimeError(payload)

    return payload["result"]


def telegram_json(method, payload):
    token, proxy, _max_proxy = telegram_config()

    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN не задан в /opt/polmira/bot/.env")

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
    )

    with build_opener(proxy).open(req, timeout=60) as resp:
        answer = json.loads(resp.read().decode("utf-8"))

    if not answer.get("ok"):
        raise RuntimeError(answer)

    return answer["result"]


def send_document(chat_id, path, caption):
    return telegram_multipart(
        "sendDocument",
        {"chat_id": chat_id, "caption": caption[:1024]},
        {"document": path},
    )


def run(command, cwd=None, timeout=COMMAND_TIMEOUT):
    proc = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    output = strip_ansi(proc.stdout.strip())

    if proc.returncode != 0:
        raise RuntimeError(output or f"{shlex.join(command)} exited with {proc.returncode}")

    return output


def systemctl(*args):
    command = ["systemctl", *args]

    if Path("/.dockerenv").exists() and Path("/usr/bin/nsenter").exists():
        command = [
            "nsenter",
            "-t",
            "1",
            "-m",
            "-u",
            "-i",
            "-n",
            "-p",
            "systemctl",
            *args,
        ]

    return run(command, timeout=120)


def service_active(name):
    try:
        return systemctl("is-active", name).strip()
    except Exception:
        return "inactive"


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=0.5):
            return True
    except Exception:
        return False


def public_base_url():
    config = read_env_file(CONFIG_FILE)
    host = config.get("PUBLIC_HOST", "")

    if not host:
        return ""

    scheme = "https" if config.get("USE_HTTPS", "no") == "yes" else "http"
    return f"{scheme}://{host}"


def phone_url(env):
    web_path = env.get("WEB_PATH", "")
    base = public_base_url()

    if not base or not web_path:
        return ""

    return f"{base}{web_path}"


def app_files():
    APPS_DIR.mkdir(parents=True, exist_ok=True)
    allowed = {".apk", ".apks", ".xapk", ".apkm", ".zip"}
    return [
        {
            "name": path.name,
            "path": str(path),
            "size": path.stat().st_size,
        }
        for path in sorted(APPS_DIR.iterdir(), key=lambda item: item.name.lower())
        if path.is_file() and path.suffix.lower() in allowed
    ]


def encode_item_id(value):
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def decode_item_id(value):
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode((value + padding).encode("ascii")).decode("utf-8")


def max_folder_for_phone(phone_dir):
    return phone_dir / "data" / "media" / "0" / "Download" / "MAX"


def file_time(path):
    try:
        return int(path.stat().st_mtime)
    except Exception:
        return 0


def state_time(item):
    try:
        return int(item.get("sent_at") or item.get("created_at") or 0)
    except Exception:
        return 0


def item_name_from_key(key, item):
    if item.get("name"):
        return item["name"]

    if key.startswith("/"):
        return Path(key).name

    if key.startswith("max-url:"):
        bits = key.split(":")
        file_id = bits[-1] if bits else "file"
        return f"MAX file {file_id}"

    return "MAX file"


def max_files_for_phone(phone_name, phone_dir):
    sent_state = load_json(SENT_FILES_STATE, {})
    max_dir = max_folder_for_phone(phone_dir)
    items = {}

    for key, item in sent_state.items():
        if not isinstance(item, dict):
            continue
        if item.get("hidden"):
            continue

        is_local = key.startswith(str(max_dir) + "/")
        is_url = key.startswith(f"max-url:{phone_name}:")

        if not is_local and not is_url:
            continue

        name = item_name_from_key(key, item)

        if is_url and not item.get("url"):
            continue

        if is_local and not Path(key).exists():
            continue

        items[key] = {
            "id": encode_item_id(key),
            "name": name,
            "size": item.get("size", 0),
            "source": item.get("source", "max-folder" if is_local else "max-log"),
            "sent_at": state_time(item),
            "available": bool(is_url or Path(key).exists()),
        }

    return sorted(items.values(), key=lambda row: (row.get("sent_at", 0), row.get("name", "")), reverse=True)


def download_max_url_for_web(url, filename):
    _token, _proxy, max_proxy = telegram_config()
    opener = build_opener(max_proxy)
    req = urllib.request.Request(url, headers={"User-Agent": "PolmiraWeb/1.0"})

    with opener.open(req, timeout=120) as resp:
        data = resp.read()

    temp_dir = Path(tempfile.mkdtemp(prefix="polmira-web-max-"))
    safe_name = re.sub(r'[\\/:*?"<>|\r\n]+', "_", filename).strip("._ ") or "max_file.bin"
    path = temp_dir / safe_name
    path.write_bytes(data)
    return path


def action_send_max_file(phone_name, item_id):
    phone_dir, env = find_phone(phone_name)
    tg_id = env.get("TG_ID", "")

    if not tg_id:
        raise RuntimeError("У телефона нет TG_ID")

    key = decode_item_id(item_id)
    sent_state = load_json(SENT_FILES_STATE, {})
    item = sent_state.get(key, {})
    max_dir = max_folder_for_phone(phone_dir)
    path = None
    cleanup_dir = None

    try:
        if key.startswith(str(max_dir) + "/"):
            path = Path(key)
            if not path.exists():
                raise RuntimeError("Файл уже не лежит в MAX папке")
        elif key.startswith(f"max-url:{phone_name}:") and item.get("url"):
            name = item_name_from_key(key, item)
            path = download_max_url_for_web(item["url"], name)
            cleanup_dir = path.parent
        else:
            raise RuntimeError("Файл не относится к выбранному телефону")

        send_document(tg_id, path, f"MAX файл: {path.name}")
        return f"Отправлено в Telegram: {path.name}"
    finally:
        if cleanup_dir is not None:
            shutil.rmtree(cleanup_dir, ignore_errors=True)


def action_delete_max_record(phone_name, item_id):
    phone_dir, _env = find_phone(phone_name)
    key = decode_item_id(item_id)
    sent_state = load_json(SENT_FILES_STATE, {})
    max_dir = max_folder_for_phone(phone_dir)

    if not (key.startswith(str(max_dir) + "/") or key.startswith(f"max-url:{phone_name}:")):
        raise RuntimeError("Запись не относится к выбранному телефону")

    current = sent_state.get(key, {})
    name = item_name_from_key(key, current)
    sent_state[key] = {
        **current,
        "name": name,
        "phone": phone_name,
        "hidden": True,
        "hidden_at": int(time.time()),
    }
    SENT_FILES_STATE.parent.mkdir(parents=True, exist_ok=True)
    SENT_FILES_STATE.write_text(json.dumps(sent_state, ensure_ascii=False, indent=2), encoding="utf-8")

    return f"Скрыто из списка: {name}"


def read_first_float(path):
    try:
        return float(Path(path).read_text(encoding="utf-8").split()[0])
    except Exception:
        return 0.0


def system_metrics():
    memory = {}

    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, value = line.split(":", 1)
            memory[key] = int(value.strip().split()[0]) * 1024
    except Exception:
        pass

    total = memory.get("MemTotal", 0)
    available = memory.get("MemAvailable", 0)
    used = max(total - available, 0) if total else 0
    load1 = read_first_float("/proc/loadavg")
    cpus = os.cpu_count() or 1

    usage = os.statvfs(APP_DIR if APP_DIR.exists() else "/")
    disk_total = usage.f_blocks * usage.f_frsize
    disk_free = usage.f_bavail * usage.f_frsize
    disk_used = max(disk_total - disk_free, 0)

    containers = 0
    try:
        output = run(["docker", "ps", "-q"], timeout=10)
        containers = len([line for line in output.splitlines() if line.strip()])
    except Exception:
        containers = 0

    try:
        uptime = int(float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0]))
    except Exception:
        uptime = 0

    return {
        "cpu_count": cpus,
        "load1": load1,
        "cpu_load_percent": min(round(load1 / cpus * 100, 1), 999.0),
        "mem_total": total,
        "mem_used": used,
        "mem_percent": round(used / total * 100, 1) if total else 0,
        "disk_total": disk_total,
        "disk_used": disk_used,
        "disk_percent": round(disk_used / disk_total * 100, 1) if disk_total else 0,
        "containers": containers,
        "uptime": uptime,
    }


def phone_dirs():
    PHONES_DIR.mkdir(parents=True, exist_ok=True)
    return sorted([path for path in PHONES_DIR.iterdir() if (path / "phone.env").exists()])


def phone_info(path):
    env = read_env_file(path / "phone.env")
    name = env.get("PHONE_NAME", path.name)
    init_service = f"polmira-phone-{name}-init.service"
    web_service = f"polmira-phone-{name}-web.service"
    web_port = env.get("WEB_PORT", "")

    return {
        "name": name,
        "tg_id": env.get("TG_ID", ""),
        "username": env.get("USERNAME", ""),
        "url": phone_url(env),
        "vpn_enabled": env.get("VPN_ENABLED", "no"),
        "adb_port": env.get("ADB_PORT", ""),
        "web_port": web_port,
        "init_status": service_active(init_service),
        "web_status": service_active(web_service),
        "web_ready": port_open(web_port) if web_port else False,
        "max_files": max_files_for_phone(name, path),
    }


def all_phones():
    return [phone_info(path) for path in phone_dirs()]


def find_phone(name):
    safe_name = Path(name).name
    path = PHONES_DIR / safe_name

    if not (path / "phone.env").exists():
        raise RuntimeError("Телефон не найден")

    return path, read_env_file(path / "phone.env")


def run_polmira(*args):
    command = [POLMIRA_CMD, *args]
    return run(command, timeout=COMMAND_TIMEOUT)


def ensure_allowed_tg(tg_id):
    if not re.fullmatch(r"\d{3,20}", str(tg_id or "")):
        raise RuntimeError("Telegram ID должен быть числом")

    APP_DIR.mkdir(parents=True, exist_ok=True)
    existing = set()

    if ALLOWED_FILE.exists():
        existing = {line.strip() for line in ALLOWED_FILE.read_text(encoding="utf-8").splitlines()}

    if str(tg_id) not in existing:
        with ALLOWED_FILE.open("a", encoding="utf-8") as fh:
            fh.write(f"{tg_id}\n")


def action_start(name):
    path, env = find_phone(name)
    tg_id = env.get("TG_ID", "")

    if tg_id:
        return run_polmira("bot-start-phone", tg_id)

    phone_name = env.get("PHONE_NAME", path.name)
    systemctl("restart", f"polmira-phone-{phone_name}-init.service")
    systemctl("restart", f"polmira-phone-{phone_name}-web.service")
    return f"Запуск отправлен: {phone_name}"


def action_stop(name):
    path, env = find_phone(name)
    tg_id = env.get("TG_ID", "")

    if tg_id:
        return run_polmira("bot-stop-phone", tg_id)

    phone_name = env.get("PHONE_NAME", path.name)
    systemctl("stop", f"polmira-phone-{phone_name}-web.service")
    systemctl("stop", f"polmira-phone-{phone_name}-init.service")
    return f"Остановка отправлена: {phone_name}"


def action_delete(name):
    _path, env = find_phone(name)
    tg_id = env.get("TG_ID", "")

    if not tg_id:
        raise RuntimeError("Удаление через веб сейчас доступно только для телефонов с TG_ID")

    return run_polmira("bot-delete-phone", tg_id)


def action_install(name, app_name):
    _path, env = find_phone(name)
    tg_id = env.get("TG_ID", "")

    if not tg_id:
        raise RuntimeError("Установка через веб сейчас доступна только для телефонов с TG_ID")

    apps = {item["name"]: item for item in app_files()}

    if app_name not in apps:
        raise RuntimeError("Приложение не найдено в /opt/polmira/apps")

    return run_polmira("bot-install-app", tg_id, apps[app_name]["path"])


def action_vpn(name, enabled):
    _path, env = find_phone(name)
    tg_id = env.get("TG_ID", "")

    if not tg_id:
        raise RuntimeError("VPN через веб сейчас доступен только для телефонов с TG_ID")

    command = "bot-enable-vpn" if enabled else "bot-disable-vpn"
    return run_polmira(command, tg_id)


def action_password(name, username, password):
    path, env = find_phone(name)
    current_username = env.get("USERNAME", env.get("PHONE_NAME", path.name))
    username = (username or current_username).strip()

    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", username):
        raise RuntimeError("Логин телефона: только латиница, цифры, точка, подчёркивание и дефис")
    if len(password) < 4:
        raise RuntimeError("Пароль должен быть минимум 4 символа")

    hashed = run(["openssl", "passwd", "-apr1", password], timeout=30).strip()
    htpasswd = path / "htpasswd"
    htpasswd.write_text(f"{username}:{hashed}\n", encoding="utf-8")
    htpasswd.chmod(0o644)
    env_set(path / "phone.env", "USERNAME", username)

    return f"Логин/пароль noVNC изменены: {username}"


def action_panel_credentials(username, password):
    global USERNAME, PASSWORD

    username = (username or USERNAME).strip()

    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", username):
        raise RuntimeError("Логин панели: только латиница, цифры, точка, подчёркивание и дефис")
    if len(password) < 6:
        raise RuntimeError("Пароль панели должен быть минимум 6 символов")

    env_set(WEB_ENV_FILE, "POLMIRA_WEB_USER", username)
    env_set(WEB_ENV_FILE, "POLMIRA_WEB_PASSWORD", password)
    USERNAME = username
    PASSWORD = password

    return "Логин/пароль панели изменены"


def phone_by_listener_payload(payload):
    phone = str(payload.get("phone", "")).strip()

    if not re.fullmatch(r"[A-Za-z0-9]+", phone):
        raise RuntimeError("Неверный phone в listener payload")

    _path, env = find_phone(phone)
    tg_id = env.get("TG_ID", "")
    secret = env.get("LISTENER_SECRET", "")

    if not tg_id:
        raise RuntimeError("У телефона нет TG_ID")
    if not secret:
        raise RuntimeError("У телефона нет LISTENER_SECRET")

    return phone, tg_id, secret


def action_listener_event(payload, provided_secret):
    phone, tg_id, expected_secret = phone_by_listener_payload(payload)
    provided_hash = hashlib.sha256(provided_secret.encode()).digest() if provided_secret else b""
    expected_hash = hashlib.sha256(expected_secret.encode()).digest()

    if not hmac.compare_digest(provided_hash, expected_hash):
        raise RuntimeError("ACCESS_DENIED")

    title = str(payload.get("title", "")).strip()
    text = str(payload.get("text", "")).strip()
    conversation = str(payload.get("conversation", "")).strip()
    sub_text = str(payload.get("sub_text", "")).strip()
    ticker = str(payload.get("ticker", "")).strip()

    lines = ["MAX"]
    if conversation:
        lines.append(f"Чат: {conversation}")
    if title:
        lines.append(f"От кого: {title}")
    if text:
        lines.append("")
        lines.append(text)
    elif ticker:
        lines.append("")
        lines.append(ticker)

    telegram_json("sendMessage", {
        "chat_id": tg_id,
        "text": "\n".join(lines)[:4096],
        "disable_web_page_preview": True,
    })

    return "Отправлено в Telegram"


INDEX_HTML = r"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Polmira Console</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5f7f8;
      --panel: #ffffff;
      --ink: #172026;
      --muted: #667481;
      --line: #d9e0e5;
      --green: #2f8f5b;
      --red: #b54747;
      --blue: #3268a8;
      --amber: #9a6a18;
      --shadow: 0 10px 30px rgba(17, 29, 39, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
      background: var(--bg);
    }
    header {
      height: 64px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 0 24px;
      border-bottom: 1px solid var(--line);
      background: rgba(255,255,255,.9);
      position: sticky;
      top: 0;
      z-index: 3;
      backdrop-filter: blur(12px);
    }
    h1 { font-size: 18px; margin: 0; font-weight: 700; }
    main {
      display: grid;
      grid-template-columns: 280px 1fr;
      min-height: calc(100vh - 64px);
    }
    aside {
      border-right: 1px solid var(--line);
      background: #edf2f5;
      padding: 18px;
    }
    section { padding: 22px; }
    .toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    button, select, input {
      height: 38px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #fff;
      color: var(--ink);
      padding: 0 12px;
      font-size: 14px;
    }
    button { cursor: pointer; font-weight: 650; }
    button.primary { background: var(--blue); color: #fff; border-color: var(--blue); }
    button.good { background: var(--green); color: #fff; border-color: var(--green); }
    button.bad { background: var(--red); color: #fff; border-color: var(--red); }
    button:disabled { opacity: .55; cursor: wait; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }
    .create { padding: 14px; display: grid; gap: 10px; }
    .create label { font-size: 13px; color: var(--muted); }
    .phone-list { display: grid; gap: 8px; margin-top: 16px; }
    .phone-tab {
      width: 100%;
      text-align: left;
      display: grid;
      gap: 4px;
      height: auto;
      min-height: 58px;
      padding: 10px;
      border-radius: 6px;
      border: 1px solid transparent;
      background: transparent;
    }
    .phone-tab.active { background: #fff; border-color: var(--line); }
    .phone-tab strong { font-size: 14px; }
    .phone-tab span { color: var(--muted); font-size: 12px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(8, minmax(110px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }
    .metric { padding: 14px; }
    .metric .label { color: var(--muted); font-size: 12px; }
    .metric .value { font-size: 20px; font-weight: 750; margin-top: 4px; }
    .details { padding: 18px; display: grid; gap: 16px; }
    .details h2 { font-size: 22px; margin: 0; }
    .status-row { display: flex; gap: 8px; flex-wrap: wrap; }
    .pill {
      border-radius: 999px;
      padding: 5px 10px;
      font-size: 12px;
      border: 1px solid var(--line);
      background: #f8fafb;
    }
    .pill.good { color: var(--green); border-color: rgba(47,143,91,.35); }
    .pill.bad { color: var(--red); border-color: rgba(181,71,71,.35); }
    .actions { display: flex; gap: 10px; flex-wrap: wrap; }
    .linkline { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .linkline a { color: var(--blue); overflow-wrap: anywhere; }
    .store { display: flex; gap: 10px; flex-wrap: wrap; }
    .max-files { display: grid; gap: 8px; }
    .max-file {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto auto auto;
      gap: 10px;
      align-items: center;
      padding: 10px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #f8fafb;
    }
    .max-file strong {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .max-file span { color: var(--muted); font-size: 12px; }
    details {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 12px;
      background: #fff;
    }
    summary {
      cursor: pointer;
      font-weight: 750;
      margin-bottom: 10px;
    }
    pre {
      margin: 0;
      white-space: pre-wrap;
      background: #111820;
      color: #dce7ef;
      border-radius: 8px;
      padding: 14px;
      max-height: 280px;
      overflow: auto;
    }
    .empty {
      padding: 48px;
      text-align: center;
      color: var(--muted);
    }
    @media (max-width: 880px) {
      main { grid-template-columns: 1fr; }
      aside { border-right: 0; border-bottom: 1px solid var(--line); }
      .grid { grid-template-columns: repeat(2, minmax(120px, 1fr)); }
    }
  </style>
</head>
<body>
  <header>
    <h1>Polmira Console</h1>
    <div class="toolbar">
      <button id="panelCreds">Логин / пароль панели</button>
      <button id="refresh">Обновить</button>
    </div>
  </header>
  <main>
    <aside>
      <div class="panel create">
        <label for="tg">Telegram ID</label>
        <input id="tg" inputmode="numeric" placeholder="123456789">
        <button id="create" class="primary">Создать телефон</button>
      </div>
      <div id="phoneList" class="phone-list"></div>
    </aside>
    <section>
      <div class="grid">
        <div class="panel metric"><div class="label">Телефоны</div><div id="mTotal" class="value">0</div></div>
        <div class="panel metric"><div class="label">Запущены</div><div id="mActive" class="value">0</div></div>
        <div class="panel metric"><div class="label">Web ready</div><div id="mReady" class="value">0</div></div>
        <div class="panel metric"><div class="label">Store</div><div id="mApps" class="value">0</div></div>
        <div class="panel metric"><div class="label">CPU</div><div id="mCpu" class="value">0%</div></div>
        <div class="panel metric"><div class="label">RAM</div><div id="mRam" class="value">0%</div></div>
        <div class="panel metric"><div class="label">Disk</div><div id="mDisk" class="value">0%</div></div>
        <div class="panel metric"><div class="label">Docker</div><div id="mDocker" class="value">0</div></div>
      </div>
      <div id="content" class="panel empty">Выбери телефон слева</div>
    </section>
  </main>
  <script>
    let state = { phones: [], apps: [], metrics: {}, selected: null, busy: false };

    const $ = (id) => document.getElementById(id);

    async function api(path, options = {}) {
      const res = await fetch(path, {
        headers: { "Content-Type": "application/json" },
        ...options
      });
      const body = await res.json();
      if (!res.ok || !body.ok) throw new Error(body.error || "Ошибка запроса");
      return body;
    }

    function setBusy(value) {
      state.busy = value;
      document.querySelectorAll("button").forEach((button) => button.disabled = value);
    }

    function showLog(message) {
      const log = $("log");
      if (log) log.textContent = message;
      else console.warn(message);
    }

    function pill(text, ok) {
      return `<span class="pill ${ok ? "good" : "bad"}">${text}</span>`;
    }

    function esc(value) {
      return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
      })[ch]);
    }

    function fmtBytes(bytes) {
      const units = ["B", "KB", "MB", "GB", "TB"];
      let value = Number(bytes || 0);
      let index = 0;
      while (value >= 1024 && index < units.length - 1) {
        value /= 1024;
        index += 1;
      }
      return `${value.toFixed(index ? 1 : 0)} ${units[index]}`;
    }

    function fmtTime(seconds) {
      if (!seconds) return "-";
      return new Date(seconds * 1000).toLocaleString();
    }

    function renderList() {
      $("mTotal").textContent = state.phones.length;
      $("mActive").textContent = state.phones.filter((p) => p.init_status === "active").length;
      $("mReady").textContent = state.phones.filter((p) => p.web_ready).length;
      $("mApps").textContent = state.apps.length;
      $("mCpu").textContent = `${state.metrics.cpu_load_percent || 0}%`;
      $("mRam").textContent = `${state.metrics.mem_percent || 0}%`;
      $("mDisk").textContent = `${state.metrics.disk_percent || 0}%`;
      $("mDocker").textContent = state.metrics.containers || 0;

      $("phoneList").innerHTML = state.phones.map((phone) => `
        <button class="phone-tab ${phone.name === state.selected ? "active" : ""}" data-phone="${esc(phone.name)}">
          <strong>${esc(phone.name)}</strong>
          <span>${esc(phone.tg_id || "без TG")} · ${esc(phone.init_status)}/${esc(phone.web_status)}</span>
        </button>
      `).join("");

      document.querySelectorAll(".phone-tab").forEach((button) => {
        button.onclick = () => {
          state.selected = button.dataset.phone;
          render();
        };
      });
    }

    function selectedPhone() {
      return state.phones.find((phone) => phone.name === state.selected) || state.phones[0];
    }

    function render() {
      renderList();
      const phone = selectedPhone();

      if (!phone) {
        $("content").className = "panel empty";
        $("content").textContent = "Телефонов пока нет";
        return;
      }

      state.selected = phone.name;
      const metrics = state.metrics;
      $("content").className = "panel details";
      $("content").innerHTML = `
        <div>
          <h2>${esc(phone.name)}</h2>
          <div class="status-row">
            ${pill(`init: ${phone.init_status}`, phone.init_status === "active")}
            ${pill(`web: ${phone.web_status}`, phone.web_status === "active")}
            ${pill(`ready: ${phone.web_ready ? "yes" : "no"}`, phone.web_ready)}
            <span class="pill">VPN: ${esc(phone.vpn_enabled)}</span>
            <span class="pill">TG: ${esc(phone.tg_id || "-")}</span>
            <span class="pill">CPU load: ${metrics.load1 || 0}/${metrics.cpu_count || 1}</span>
            <span class="pill">RAM: ${fmtBytes(metrics.mem_used)} / ${fmtBytes(metrics.mem_total)}</span>
            <span class="pill">Disk: ${fmtBytes(metrics.disk_used)} / ${fmtBytes(metrics.disk_total)}</span>
          </div>
        </div>
        <div class="actions">
          <button class="good" data-action="start">Включить / перезагрузить</button>
          <button data-action="stop">Выключить</button>
          <button data-action="vpn_on">Включить VPN</button>
          <button data-action="vpn_off">Выключить VPN</button>
          <button data-action="password">Сменить пароль</button>
          <button class="bad" data-action="delete">Удалить</button>
        </div>
        <div class="linkline">
          <strong>noVNC:</strong>
          ${phone.url ? `<a href="${esc(phone.url)}" target="_blank" rel="noreferrer">${esc(phone.url)}</a>` : "<span>-</span>"}
        </div>
        <div class="store">
          <select id="appSelect">
            ${state.apps.map((app) => `<option value="${esc(app.name)}">${esc(app.name)}</option>`).join("")}
          </select>
          <button data-action="install">Установить из store</button>
        </div>
        <details open>
          <summary>MAX файлы (${(phone.max_files || []).length})</summary>
          <div class="max-files">
            ${(phone.max_files || []).length ? phone.max_files.map((file) => `
              <div class="max-file">
                <div>
                  <strong title="${esc(file.name)}">${esc(file.name)}</strong>
                  <span>${fmtBytes(file.size)} · ${esc(file.source)} · ${fmtTime(file.sent_at)}</span>
                </div>
                <span>${file.available ? "ready" : "gone"}</span>
                <button data-max-file="${file.id}" ${file.available ? "" : "disabled"}>В TG</button>
                <button data-max-delete="${file.id}">Удалить</button>
              </div>
            `).join("") : "<span>Файлов пока нет</span>"}
          </div>
        </details>
        <pre id="log">Готово</pre>
      `;

      document.querySelectorAll("[data-action]").forEach((button) => {
        button.onclick = () => runAction(button.dataset.action);
      });
      document.querySelectorAll("[data-max-file]").forEach((button) => {
        button.onclick = () => sendMaxFile(button.dataset.maxFile);
      });
      document.querySelectorAll("[data-max-delete]").forEach((button) => {
        button.onclick = () => deleteMaxRecord(button.dataset.maxDelete);
      });
    }

    async function refresh() {
      const body = await api("api/state");
      state.phones = body.phones;
      state.apps = body.apps;
      state.metrics = body.metrics || {};
      if (!state.selected && state.phones[0]) state.selected = state.phones[0].name;
      render();
    }

    async function runAction(action) {
      const phone = selectedPhone();
      if (!phone) return;

      let payload = {};
      let url = `api/phones/${encodeURIComponent(phone.name)}/${action}`;

      if (action === "delete" && !confirm(`Удалить ${phone.name}?`)) return;
      if (action === "install") payload.app = $("appSelect").value;
      if (action === "password") {
        const username = prompt(`Новый логин для ${phone.name}`, phone.username || phone.name);
        if (!username) return;
        const password = prompt(`Новый пароль для ${phone.name}`);
        if (!password) return;
        payload.username = username;
        payload.password = password;
      }

      try {
        setBusy(true);
        const body = await api(url, { method: "POST", body: JSON.stringify(payload) });
        showLog(body.output || "Готово");
        await refresh();
      } catch (err) {
        showLog(err.message);
      } finally {
        setBusy(false);
      }
    }

    async function sendMaxFile(fileId) {
      const phone = selectedPhone();
      if (!phone) return;

      try {
        setBusy(true);
        const body = await api(`api/phones/${encodeURIComponent(phone.name)}/max-file`, {
          method: "POST",
          body: JSON.stringify({ id: fileId })
        });
        showLog(body.output || "Отправлено");
        await refresh();
      } catch (err) {
        showLog(err.message);
      } finally {
        setBusy(false);
      }
    }

    async function deleteMaxRecord(fileId) {
      const phone = selectedPhone();
      if (!phone) return;
      if (!confirm("Удалить запись из списка? Сам файл не удаляется.")) return;

      try {
        setBusy(true);
        const body = await api(`api/phones/${encodeURIComponent(phone.name)}/max-file-delete`, {
          method: "POST",
          body: JSON.stringify({ id: fileId })
        });
        showLog(body.output || "Удалено");
        await refresh();
      } catch (err) {
        showLog(err.message);
      } finally {
        setBusy(false);
      }
    }

    $("refresh").onclick = refresh;
    $("panelCreds").onclick = async () => {
      const currentUser = prompt("Новый логин панели", "admin");
      if (!currentUser) return;
      const password = prompt("Новый пароль панели");
      if (!password) return;

      try {
        setBusy(true);
        const body = await api("api/panel/credentials", {
          method: "POST",
          body: JSON.stringify({ username: currentUser, password })
        });
        showLog(body.output || "Готово. При следующем запросе браузер спросит новый логин/пароль.");
      } catch (err) {
        showLog(err.message);
      } finally {
        setBusy(false);
      }
    };
    $("create").onclick = async () => {
      const tgId = $("tg").value.trim();
      if (!tgId) return alert("Укажи Telegram ID");

      try {
        setBusy(true);
        await api("api/phones/create", { method: "POST", body: JSON.stringify({ tg_id: tgId }) });
        $("tg").value = "";
        await refresh();
      } catch (err) {
        showLog(err.message);
      } finally {
        setBusy(false);
      }
    };

    refresh().catch((err) => {
      $("content").className = "panel empty";
      $("content").textContent = err.message;
    });
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")

    def authorized(self):
        auth = self.headers.get("Authorization", "")

        if not auth.startswith("Basic "):
            return False

        try:
            raw = base64.b64decode(auth.split(" ", 1)[1]).decode("utf-8")
        except Exception:
            return False

        user, _, password = raw.partition(":")
        return user == USERNAME and password == PASSWORD

    def require_auth(self):
        if self.authorized():
            return True

        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Polmira"')
        self.end_headers()
        return False

    def send_json(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_html(self, html):
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def json_body(self):
        length = int(self.headers.get("Content-Length", "0"))

        if length <= 0:
            return {}

        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        if not self.require_auth():
            return

        parsed = urllib.parse.urlparse(self.path)

        try:
            if parsed.path == "/":
                self.send_html(INDEX_HTML)
            elif parsed.path == "/api/state":
                self.send_json({
                    "ok": True,
                    "phones": all_phones(),
                    "apps": app_files(),
                    "metrics": system_metrics(),
                })
            else:
                self.send_json({"ok": False, "error": "Not found"}, 404)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, 500)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]

        try:
            payload = self.json_body()

            if parts == ["api", "listener", "event"]:
                output = action_listener_event(payload, self.headers.get("X-Polmira-Secret", ""))
                self.send_json({"ok": True, "output": output})
                return

            if not self.require_auth():
                return

            if parts == ["api", "phones", "create"]:
                tg_id = str(payload.get("tg_id", "")).strip()
                ensure_allowed_tg(tg_id)
                output = run_polmira("bot-create-phone", tg_id)
                self.send_json({"ok": True, "output": output})
                return

            if parts == ["api", "panel", "credentials"]:
                output = action_panel_credentials(
                    str(payload.get("username", "")),
                    str(payload.get("password", "")),
                )
                self.send_json({"ok": True, "output": output})
                return

            if len(parts) == 4 and parts[:2] == ["api", "phones"]:
                name = urllib.parse.unquote(parts[2])
                action = parts[3]

                if action == "start":
                    output = action_start(name)
                elif action == "stop":
                    output = action_stop(name)
                elif action == "delete":
                    output = action_delete(name)
                elif action == "install":
                    output = action_install(name, str(payload.get("app", "")))
                elif action == "vpn_on":
                    output = action_vpn(name, True)
                elif action == "vpn_off":
                    output = action_vpn(name, False)
                elif action == "password":
                    output = action_password(
                        name,
                        str(payload.get("username", "")),
                        str(payload.get("password", "")),
                    )
                elif action == "max-file":
                    output = action_send_max_file(name, str(payload.get("id", "")))
                elif action == "max-file-delete":
                    output = action_delete_max_record(name, str(payload.get("id", "")))
                else:
                    raise RuntimeError("Неизвестное действие")

                self.send_json({"ok": True, "output": output})
                return

            self.send_json({"ok": False, "error": "Not found"}, 404)
        except subprocess.TimeoutExpired:
            self.send_json({"ok": False, "error": "Команда выполнялась слишком долго"}, 500)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, 500)


def main():
    load_web_env_runtime()
    print(f"Polmira web listening on {HOST}:{PORT}")
    print(f"Login: {USERNAME}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
