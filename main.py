#!/usr/bin/env python3
import json
import mimetypes
import os
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def load_env_file(path):
    env_path = Path(path)

    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()

        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        if key and key not in os.environ:
            os.environ[key] = value


load_env_file(os.environ.get("POLMIRA_BOT_ENV", "/opt/polmira-docker/bot/.env"))

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
POLMIRA_CMD = os.environ.get("POLMIRA_CMD", "/usr/local/bin/polmira-docker")
APP_DIR = Path(os.environ.get("POLMIRA_APP_DIR", "/opt/polmira-docker"))
APPS_DIR = APP_DIR / "apps"
PHONES_DIR = APP_DIR / "instances"
BOT_DIR = APP_DIR / "bot"
POLL_TIMEOUT = int(os.environ.get("TELEGRAM_POLL_TIMEOUT", "30"))
TELEGRAM_PROXY = os.environ.get("TELEGRAM_PROXY", "")
POLMIRA_RELAY_SECRET = os.environ.get("POLMIRA_RELAY_SECRET", "")
POLMIRA_RELAY_BIND = os.environ.get("POLMIRA_RELAY_BIND", "172.17.0.1")
POLMIRA_RELAY_PORT = int(os.environ.get("POLMIRA_RELAY_PORT", "8788"))
TELEGRAM_API_RETRIES = int(os.environ.get("TELEGRAM_API_RETRIES", "3"))
TELEGRAM_SEND_TIMEOUT = int(os.environ.get("TELEGRAM_SEND_TIMEOUT", "12"))
PENDING_ACTIONS = {}
INPUT_LOCKS = {}
INPUT_LOCKS_GUARD = threading.Lock()
MAX_INPUT_BYTES = int(os.environ.get("POLMIRA_INPUT_MAX_BYTES", str(64 * 1024)))

SCRIPT_DIR = Path(__file__).resolve().parent
LOCAL_POLMIRA = SCRIPT_DIR / "polmira-docker.sh"


def install_socks5_proxy(proxy_url):
    parsed = urllib.parse.urlparse(proxy_url)

    if parsed.scheme not in {"socks5", "socks5h"}:
        return False

    proxy_host = parsed.hostname or "127.0.0.1"
    proxy_port = parsed.port or 1080
    original_create_connection = socket.create_connection

    def recv_exact(sock, size):
        data = b""

        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                raise OSError("SOCKS5 proxy closed connection")
            data += chunk

        return data

    def socks_create_connection(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None):
        host, port = address

        if host == proxy_host and port == proxy_port:
            return original_create_connection(address, timeout, source_address)

        sock = original_create_connection((proxy_host, proxy_port), timeout, source_address)

        try:
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)

            sock.sendall(b"\x05\x01\x00")
            version, method = recv_exact(sock, 2)

            if version != 5 or method != 0:
                raise OSError("SOCKS5 proxy rejected no-auth handshake")

            host_bytes = str(host).encode("idna")

            if len(host_bytes) > 255:
                raise OSError("SOCKS5 hostname is too long")

            request = (
                b"\x05\x01\x00\x03"
                + bytes([len(host_bytes)])
                + host_bytes
                + struct.pack("!H", int(port))
            )
            sock.sendall(request)

            header = recv_exact(sock, 4)

            if header[0] != 5 or header[1] != 0:
                raise OSError(f"SOCKS5 connect failed, code={header[1]}")

            atyp = header[3]

            if atyp == 1:
                recv_exact(sock, 4)
            elif atyp == 3:
                length = recv_exact(sock, 1)[0]
                recv_exact(sock, length)
            elif atyp == 4:
                recv_exact(sock, 16)
            else:
                raise OSError(f"SOCKS5 unknown address type={atyp}")

            recv_exact(sock, 2)
            return sock
        except Exception:
            sock.close()
            raise

    socket.create_connection = socks_create_connection
    return True


def allowed_files():
    configured = os.environ.get("POLMIRA_ALLOWED_FILE", "")
    candidates = [
        Path(configured) if configured else None,
        APP_DIR / "tg-allowed.txt",
        Path("/opt/polmira-docker/tg-allowed.txt"),
        Path("/opt/polmira-linux/tg-allowed.txt"),
        Path("/opt/polmira/tg-allowed.txt"),
    ]
    seen = set()

    for path in candidates:
        if not path:
            continue
        resolved = str(path)
        if resolved in seen:
            continue
        seen.add(resolved)
        yield path


def is_allowed_tg(tg_id):
    wanted = str(tg_id or "").strip()
    if not wanted:
        return False

    for path in allowed_files():
        try:
            for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = raw_line.strip()
                if line and not line.startswith("#") and line == wanted:
                    return True
        except FileNotFoundError:
            continue
        except OSError as exc:
            print(f"Could not read allowed file {path}: {exc}")

    return False


def deny_access(chat_id, tg_id):
    send_message(chat_id, f"ACCESS_DENIED\nТвой Telegram ID: {tg_id}")


def read_env_file(path):
    data = {}

    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except FileNotFoundError:
        return data
    except OSError as exc:
        print(f"Could not read env file {path}: {exc}")
        return data

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()

    return data


def instance_env_for_tg(tg_id):
    wanted = str(tg_id or "").strip()
    if not wanted:
        return {}

    for env_file in PHONES_DIR.glob("*/instance.env"):
        data = read_env_file(env_file)
        if data.get("TG_ID") == wanted:
            return data

    return {}


def is_valid_relay_secret(tg_id, secret):
    data = instance_env_for_tg(tg_id)
    expected = data.get("RELAY_SECRET", "")

    if not expected:
        return False

    return str(secret or "") == expected

if TELEGRAM_PROXY and install_socks5_proxy(TELEGRAM_PROXY):
    opener = urllib.request.build_opener()
    urllib.request.install_opener(opener)
elif TELEGRAM_PROXY:
    proxy_handler = urllib.request.ProxyHandler({
        "http": TELEGRAM_PROXY,
        "https": TELEGRAM_PROXY,
    })
    urllib.request.install_opener(urllib.request.build_opener(proxy_handler))


PHONE_MENU = {
    "inline_keyboard": [
        [
            {"text": "Включить / перезагрузить", "callback_data": "start"},
            {"text": "Выключить", "callback_data": "stop"},
        ],
        [
            {"text": "Сменить логин/пароль", "callback_data": "change_credentials"},
        ],
        [
            {"text": "Удалить", "callback_data": "delete_confirm"},
        ],
        [{"text": "Обновить статус", "callback_data": "refresh"}],
    ]
}

CREATE_MENU = {
    "inline_keyboard": [[{"text": "Создать MAX-контейнер", "callback_data": "create"}]]
}

DELETE_CONFIRM_MENU = {
    "inline_keyboard": [
        [{"text": "Да, удалить", "callback_data": "delete"}],
        [{"text": "Отмена", "callback_data": "refresh"}],
    ]
}

def api(method, payload=None, timeout=None, retries=None):
    if not BOT_TOKEN:
        raise RuntimeError("Укажи TELEGRAM_BOT_TOKEN")

    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    last_exc = None

    request_timeout = timeout if timeout is not None else POLL_TIMEOUT + 10
    request_retries = retries if retries is not None else TELEGRAM_API_RETRIES

    for attempt in range(1, request_retries + 1):
        req = urllib.request.Request(url, data=data, headers=headers)

        try:
            with urllib.request.urlopen(req, timeout=request_timeout) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            break
        except (TimeoutError, urllib.error.URLError) as exc:
            last_exc = exc
            if attempt >= request_retries:
                raise
            time.sleep(min(2 * attempt, 5))
    else:
        raise last_exc or RuntimeError("Telegram API failed")

    if not body.get("ok"):
        raise RuntimeError(body)

    return body["result"]


def get_updates(offset):
    params = urllib.parse.urlencode({"timeout": POLL_TIMEOUT, "offset": offset})
    return api(f"getUpdates?{params}")


def send_message(chat_id, text, reply_markup=None):
    payload = {
        "chat_id": chat_id,
        "text": text[:3900],
        "disable_web_page_preview": True,
    }

    if reply_markup:
        payload["reply_markup"] = reply_markup

    return api("sendMessage", payload, timeout=TELEGRAM_SEND_TIMEOUT)


def safe_send_message(chat_id, text, reply_markup=None):
    try:
        return send_message(chat_id, text, reply_markup)
    except Exception as exc:
        print(f"sendMessage failed: {exc}", flush=True)
        return None


def relay_file_headers(handler):
    tg_id = str(handler.headers.get("X-Polmira-Tg-Id") or "").strip()
    secret = str(handler.headers.get("X-Polmira-Secret") or "")
    filename = sanitize_filename(urllib.parse.unquote(handler.headers.get("X-Polmira-Filename") or "max-file"))
    caption = urllib.parse.unquote(handler.headers.get("X-Polmira-Caption") or "")
    mime_type = str(handler.headers.get("Content-Type") or "application/octet-stream").split(";", 1)[0]
    return tg_id, secret, filename, caption, mime_type


def send_telegram_file(chat_id, path, filename, caption, mime_type):
    method = "sendDocument"
    field = "document"

    if mime_type.startswith("image/") and Path(path).stat().st_size <= 10 * 1024 * 1024:
        method = "sendPhoto"
        field = "photo"

    fields = {"chat_id": chat_id}
    if caption:
        fields["caption"] = caption[:1024]

    return multipart_api(method, fields, {field: (path, filename, mime_type)})


def send_message_async(chat_id, text):
    def worker():
        try:
            send_message(chat_id, text)
        except Exception as exc:
            print(f"Relay async message error: {exc}", flush=True)

    threading.Thread(target=worker, daemon=True).start()


def send_file_async(chat_id, path, filename, caption, mime_type):
    def worker():
        try:
            send_telegram_file(chat_id, path, filename, caption, mime_type)
        except Exception as exc:
            print(f"Relay async file error: {exc}", flush=True)
        finally:
            try:
                Path(path).unlink(missing_ok=True)
            except OSError:
                pass

    threading.Thread(target=worker, daemon=True).start()


class RelayHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        if self.path == "/notify":
            self.handle_notify()
            return

        if self.path == "/file":
            self.handle_file()
            return

        if self.path == "/input":
            self.handle_input()
            return

        self.send_response(404)
        self.end_headers()

    def handle_input(self):
        try:
            tg_id = str(self.headers.get("X-Polmira-Tg-Id") or "").strip()
            secret = str(self.headers.get("X-Polmira-Secret") or "")
            length = int(self.headers.get("Content-Length", "0"))

            if not tg_id or length <= 0:
                self.send_response(400)
                self.end_headers()
                return

            if length > MAX_INPUT_BYTES:
                self.send_response(413)
                self.end_headers()
                return

            if not is_allowed_tg(tg_id) or not is_valid_relay_secret(tg_id, secret):
                self.send_response(403)
                self.end_headers()
                return

            text = self.rfile.read(length).decode("utf-8")
            if not text:
                self.send_response(204)
                self.end_headers()
                return

            with input_lock(tg_id):
                run_polmira("bot-input", tg_id, input_text=text)

            self.send_response(204)
            self.end_headers()
        except UnicodeDecodeError:
            self.send_response(400)
            self.end_headers()
        except Exception as exc:
            print(f"Input relay error: {exc}", flush=True)
            self.send_response(500)
            self.end_headers()

    def handle_notify(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))

            tg_id = str(payload.get("tg_id") or "").strip()
            text = str(payload.get("text") or "").strip()
            secret = str(payload.get("secret") or "")

            if not tg_id or not text:
                self.send_response(400)
                self.end_headers()
                return

            if not is_allowed_tg(tg_id) or not is_valid_relay_secret(tg_id, secret):
                self.send_response(403)
                self.end_headers()
                return

            send_message_async(tg_id, text)
            self.send_response(204)
            self.end_headers()
        except Exception as exc:
            print(f"Relay error: {exc}")
            self.send_response(500)
            self.end_headers()

    def handle_file(self):
        tmp_path = None

        try:
            tg_id, secret, filename, caption, mime_type = relay_file_headers(self)
            length = int(self.headers.get("Content-Length", "0"))
            max_size = int(os.environ.get("POLMIRA_RELAY_MAX_FILE_BYTES", str(49 * 1024 * 1024)))

            if not tg_id or not filename or length <= 0:
                self.send_response(400)
                self.end_headers()
                return

            if length > max_size:
                self.send_response(413)
                self.end_headers()
                return

            if not is_allowed_tg(tg_id) or not is_valid_relay_secret(tg_id, secret):
                self.send_response(403)
                self.end_headers()
                return

            suffix = Path(filename).suffix
            with tempfile.NamedTemporaryFile(prefix="polmira-relay-", suffix=suffix, delete=False) as tmp:
                tmp_path = Path(tmp.name)
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    tmp.write(chunk)
                    remaining -= len(chunk)

            if remaining != 0:
                self.send_response(400)
                self.end_headers()
                return

            send_file_async(tg_id, tmp_path, filename, caption, mime_type)
            tmp_path = None
            self.send_response(204)
            self.end_headers()
        except Exception as exc:
            print(f"Relay file error: {exc}")
            self.send_response(500)
            self.end_headers()
        finally:
            if tmp_path:
                try:
                    Path(tmp_path).unlink(missing_ok=True)
                except OSError:
                    pass

def start_relay_server():
    if not POLMIRA_RELAY_SECRET:
        print("Polmira relay disabled: POLMIRA_RELAY_SECRET is empty")
        return

    try:
        server = ThreadingHTTPServer((POLMIRA_RELAY_BIND, POLMIRA_RELAY_PORT), RelayHandler)
    except OSError as exc:
        print(f"Polmira relay not started: {exc}")
        return

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"Polmira relay listening on {POLMIRA_RELAY_BIND}:{POLMIRA_RELAY_PORT}")


def answer_callback(callback_id, text=""):
    payload = {"callback_query_id": callback_id}

    if text:
        payload["text"] = text[:180]

    return api("answerCallbackQuery", payload)


def safe_answer_callback(callback_id, text=""):
    try:
        return answer_callback(callback_id, text)
    except Exception as exc:
        print(f"answerCallbackQuery failed: {exc}", flush=True)
        return None


def multipart_api(method, fields, files):
    if not BOT_TOKEN:
        raise RuntimeError("Укажи TELEGRAM_BOT_TOKEN")

    boundary = f"----PolmiraBoundary{int(time.time() * 1000)}"
    body = bytearray()

    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(str(value).encode("utf-8"))
        body.extend(b"\r\n")

    for name, value in files.items():
        if isinstance(value, tuple):
            path, upload_name, upload_mime_type = value
        else:
            path, upload_name, upload_mime_type = value, None, None

        file_path = Path(path)
        file_name = sanitize_filename(upload_name or file_path.name)
        mime_type = upload_mime_type or mimetypes.guess_type(file_name)[0] or "application/octet-stream"
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(
            f'Content-Disposition: form-data; name="{name}"; filename="{file_name}"\r\n'.encode()
        )
        body.extend(f"Content-Type: {mime_type}\r\n\r\n".encode())
        body.extend(file_path.read_bytes())
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode())

    last_exc = None

    for attempt in range(1, TELEGRAM_API_RETRIES + 1):
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/{method}",
            data=bytes(body),
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )

        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            break
        except (TimeoutError, urllib.error.URLError) as exc:
            last_exc = exc
            if attempt >= TELEGRAM_API_RETRIES:
                raise
            time.sleep(min(2 * attempt, 5))
    else:
        raise last_exc or RuntimeError("Telegram multipart API failed")

    if not payload.get("ok"):
        raise RuntimeError(payload)

    return payload["result"]


def polmira_command():
    cmd = POLMIRA_CMD

    if not Path(cmd).exists() and LOCAL_POLMIRA.exists():
        cmd = str(LOCAL_POLMIRA)

    command = [cmd]

    if os.geteuid() != 0 and os.environ.get("POLMIRA_USE_SUDO", "yes") == "yes":
        command = ["sudo", "-n"] + command

    return command


def run_polmira(*args, input_text=None):
    try:
        proc = subprocess.run(
            polmira_command() + list(args),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=int(os.environ.get("POLMIRA_COMMAND_TIMEOUT", "900")),
        )
    except subprocess.TimeoutExpired as exc:
        output = strip_ansi((exc.stdout or "").strip())
        raise RuntimeError(output or "Команда Polmira выполнялась слишком долго") from exc
    except FileNotFoundError as exc:
        raise RuntimeError(f"Команда Polmira не найдена: {polmira_command()[0]}") from exc

    output = strip_ansi(proc.stdout.strip())

    if proc.returncode != 0:
        raise RuntimeError(output or f"polmira exited with {proc.returncode}")

    return output


def input_lock(tg_id):
    with INPUT_LOCKS_GUARD:
        return INPUT_LOCKS.setdefault(str(tg_id), threading.Lock())


def strip_ansi(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def parse_env_output(output):
    parsed = {}

    for line in output.splitlines():
        if "=" in line and re.match(r"^[A-Z0-9_]+=", line):
            key, value = line.split("=", 1)
            parsed[key] = value

    return parsed


def status_for_user(tg_id):
    output = run_polmira("bot-status", str(tg_id))
    return output, parse_env_output(output)


def render_phone_status(info):
    lines = [
        "Твой MAX-контейнер готов.",
        f"Контейнер: {info.get('CONTAINER_NAME') or info.get('PHONE_NAME', '-')}",
        f"Логин: {info.get('USERNAME', '-')}",
    ]

    if info.get("PASSWORD"):
        lines.append(f"Пароль: {info['PASSWORD']}")

    lines.extend([
        f"Статус: {info.get('INIT_STATUS', '-')}",
        f"web: {info.get('WEB_STATUS', '-')} / ready: {info.get('WEB_READY', '-')}",
        "",
        "Ссылка:",
        info.get("URL", "-"),
    ])

    return "\n".join(lines)


def show_entry_menu(chat_id, tg_id):
    try:
        _, info = status_for_user(tg_id)
    except RuntimeError as exc:
        text = str(exc)

        if "ACCESS_DENIED" in text:
            send_message(chat_id, f"Доступа пока нет.\nТвой Telegram ID: {tg_id}")
            return

        send_message(chat_id, f"Не смог проверить доступ:\n{text}")
        return

    if info.get("NO_PHONE") == "1":
        send_message(chat_id, "Доступ есть. MAX-контейнер ещё не создан.", CREATE_MENU)
    else:
        send_message(chat_id, render_phone_status(info), PHONE_MENU)


def handle_create(chat_id, tg_id):
    safe_send_message(chat_id, "Создаю MAX-контейнер. Первый запуск может занять несколько минут...")

    try:
        output = run_polmira("bot-create-phone", str(tg_id))
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось создать MAX-контейнер:\n{exc}")
        return

    info = parse_env_output(output)

    if info.get("URL"):
        send_message(chat_id, render_phone_status(info), PHONE_MENU)
    else:
        lines = [line for line in output.splitlines() if line.strip()]
        send_message(chat_id, "\n".join(lines[-10:]), PHONE_MENU)


def handle_action(chat_id, tg_id, action):
    mapping = {
        "start": ("bot-start-phone", "Запускаю сессию..."),
        "stop": ("bot-stop-phone", "Выключаю сессию..."),
    }

    if action not in mapping:
        send_message(chat_id, "Эта команда больше не используется. Открой меню заново: /start")
        return

    command, progress = mapping[action]
    safe_send_message(chat_id, progress)

    try:
        output = run_polmira(command, str(tg_id))
    except RuntimeError as exc:
        send_message(chat_id, f"Команда не выполнена:\n{exc}")
        return

    info = parse_env_output(output)

    if info:
        send_message(chat_id, render_phone_status(info), PHONE_MENU)
    else:
        send_message(chat_id, output or "Готово.", PHONE_MENU)


def handle_change_credentials(chat_id, tg_id):
    PENDING_ACTIONS[str(tg_id)] = {"action": "change_credentials"}
    send_message(
        chat_id,
        "Пришли новый логин и пароль одной строкой:\n\nлогин пароль\n\n"
        "Логин: латиница/цифры/точка/дефис/подчёркивание, до 64 символов.",
        {"inline_keyboard": [[{"text": "Отмена", "callback_data": "cancel"}]]},
    )


def complete_change_credentials(chat_id, tg_id, text):
    parts = text.split(maxsplit=1)

    if len(parts) != 2:
        send_message(chat_id, "Нужно одной строкой: логин пароль", PHONE_MENU)
        return

    username, password = parts[0].strip(), parts[1].strip()

    if not re.match(r"^[A-Za-z0-9_.-]{1,64}$", username):
        send_message(chat_id, "Логин должен быть: A-Z, a-z, 0-9, точка, дефис или подчёркивание.", PHONE_MENU)
        return

    if len(password) < 4:
        send_message(chat_id, "Пароль слишком короткий, дай хотя бы 4 символа.", PHONE_MENU)
        return

    try:
        output = run_polmira("bot-set-password", str(tg_id), username, password)
    except RuntimeError as exc:
        PENDING_ACTIONS.pop(str(tg_id), None)
        send_message(chat_id, f"Не получилось сменить логин/пароль:\n{exc}", PHONE_MENU)
        return

    PENDING_ACTIONS.pop(str(tg_id), None)
    info = parse_env_output(output)
    info["PASSWORD"] = password
    send_message(chat_id, render_phone_status(info), PHONE_MENU)


def handle_delete(chat_id, tg_id):
    try:
        output = run_polmira("bot-delete-phone", str(tg_id))
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось удалить MAX-контейнер:\n{exc}")
        return

    safe_send_message(chat_id, output or "MAX-контейнер удалён.", CREATE_MENU)


def cancel_pending(chat_id, tg_id):
    PENDING_ACTIONS.pop(str(tg_id), None)
    send_message(chat_id, "Отменено.", PHONE_MENU)


def phone_dir_for_tg_id(tg_id):
    wanted = str(tg_id)

    for phone_dir in sorted(PHONES_DIR.glob("*")):
        if not phone_dir.is_dir():
            continue

        env = read_phone_env(phone_dir / "instance.env")

        if env.get("TG_ID") == wanted:
            return phone_dir

    return None


def sanitize_filename(name):
    clean = re.sub(r'[\\/:*?"<>|\r\n]+', "_", name or "").strip("._ ")
    return clean[:180] or "telegram-file"


def unique_path(path):
    if not path.exists():
        return path

    stem = path.stem
    suffix = path.suffix

    for index in range(1, 1000):
        candidate = path.with_name(f"{stem}_{index}{suffix}")

        if not candidate.exists():
            return candidate

    return path.with_name(f"{stem}_{int(time.time())}{suffix}")


def media_from_message(message):
    if message.get("document"):
        item = message["document"]
        return item["file_id"], item.get("file_name"), "document", item.get("mime_type", "")

    if message.get("photo"):
        item = sorted(message["photo"], key=lambda part: part.get("file_size", 0))[-1]
        return item["file_id"], None, "photo", "image/jpeg"

    for key, default_ext in (
        ("video", ".mp4"),
        ("animation", ".mp4"),
        ("audio", ".mp3"),
        ("voice", ".ogg"),
        ("video_note", ".mp4"),
        ("sticker", ".webp"),
    ):
        if message.get(key):
            item = message[key]
            name = item.get("file_name") or f"{key}_{time.strftime('%Y-%m-%d_%H-%M-%S')}{default_ext}"
            return item["file_id"], name, key, item.get("mime_type", "")

    return None, None, None, None


def extension_from_telegram(file_path, mime_type, fallback):
    suffix = Path(file_path or "").suffix

    if suffix:
        return suffix

    if mime_type:
        guessed = mimetypes.guess_extension(mime_type.split(";", 1)[0].lower())

        if guessed:
            return guessed

    return fallback


def download_telegram_file(file_id):
    info = api("getFile", {"file_id": file_id})
    file_path = info.get("file_path", "")

    if not file_path:
        raise RuntimeError("Telegram не вернул путь файла")

    url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}"

    with urllib.request.urlopen(url, timeout=180) as resp:
        data = resp.read()

    return data, file_path


def save_message_file_to_phone(tg_id, message):
    phone_dir = phone_dir_for_tg_id(tg_id)

    if phone_dir is None:
        raise RuntimeError("MAX-контейнер для этого Telegram ID не найден")

    env = read_phone_env(phone_dir / "instance.env")
    file_id, original_name, kind, mime_type = media_from_message(message)

    if not file_id:
        raise RuntimeError("Не нашёл файл в сообщении")

    data, telegram_path = download_telegram_file(file_id)
    max_dir = Path(env.get("DOWNLOADS_DIR") or phone_dir / "downloads")

    max_dir.mkdir(parents=True, exist_ok=True)

    if original_name:
        filename = sanitize_filename(original_name)
    else:
        ext = extension_from_telegram(telegram_path, mime_type, ".bin")
        filename = f"telegram_{kind}_{time.strftime('%Y-%m-%d_%H-%M-%S')}{ext}"

    destination = unique_path(max_dir / filename)
    destination.write_bytes(data)
    os.chmod(destination, 0o666)
    return destination


def handle_file_message(chat_id, tg_id, message):
    try:
        path = save_message_file_to_phone(tg_id, message)
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось сохранить файл:\n{exc}", PHONE_MENU)
        return

    send_message(chat_id, f"Сохранил в Downloads:\n{path.name}", PHONE_MENU)


def read_phone_env(path):
    data = {}

    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" in raw_line:
            key, value = raw_line.split("=", 1)
            data[key] = value

    return data


def handle_callback(callback):
    data = callback.get("data", "")
    message = callback.get("message") or {}
    chat_id = message.get("chat", {}).get("id")
    tg_id = callback.get("from", {}).get("id")

    safe_answer_callback(callback["id"])

    if not chat_id or not tg_id:
        return

    if not is_allowed_tg(tg_id):
        deny_access(chat_id, tg_id)
        return

    if data == "create":
        handle_create(chat_id, tg_id)
    elif data == "cancel":
        cancel_pending(chat_id, tg_id)
    elif data == "refresh":
        PENDING_ACTIONS.pop(str(tg_id), None)
        show_entry_menu(chat_id, tg_id)
    elif data == "install":
        send_message(chat_id, "MAX теперь ставится внутри контейнера автоматически. Открой меню заново: /start")
    elif data in {"change_credentials", "change_password"}:
        handle_change_credentials(chat_id, tg_id)
    elif data.startswith("app:"):
        send_message(chat_id, "Эта команда больше не используется. Открой меню заново: /start")
    elif data == "delete_confirm":
        send_message(chat_id, "Удалить MAX-контейнер и его данные?", DELETE_CONFIRM_MENU)
    elif data == "delete":
        handle_delete(chat_id, tg_id)
    elif data in {"start", "stop"}:
        handle_action(chat_id, tg_id, data)


def handle_message(message):
    chat_id = message.get("chat", {}).get("id")
    tg_id = message.get("from", {}).get("id")
    text = (message.get("text") or "").strip()

    if not chat_id or not tg_id:
        return

    if not is_allowed_tg(tg_id):
        deny_access(chat_id, tg_id)
        return

    if any(message.get(key) for key in ("document", "photo", "video", "animation", "audio", "voice", "video_note", "sticker")):
        handle_file_message(chat_id, tg_id, message)
        return

    pending = PENDING_ACTIONS.get(str(tg_id))
    if pending and pending.get("action") == "change_credentials":
        complete_change_credentials(chat_id, tg_id, text)
        return

    if text in {"/start", "/menu", "menu", "меню"}:
        PENDING_ACTIONS.pop(str(tg_id), None)
        show_entry_menu(chat_id, tg_id)
    else:
        send_message(chat_id, "Открой меню командой /start.")


def main():
    if not BOT_TOKEN:
        raise SystemExit("Укажи TELEGRAM_BOT_TOKEN")

    offset = 0
    print("Polmira Telegram bot started")
    start_relay_server()

    while True:
        try:
            updates = get_updates(offset)

            for update in updates:
                offset = update["update_id"] + 1

                if "callback_query" in update:
                    handle_callback(update["callback_query"])
                elif "message" in update:
                    handle_message(update["message"])

        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"Telegram network error: {exc}")
            time.sleep(3)
        except Exception as exc:
            print(f"Bot error: {exc}")
            time.sleep(3)


if __name__ == "__main__":
    main()
