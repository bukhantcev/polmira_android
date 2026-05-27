#!/usr/bin/env python3
import json
import mimetypes
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
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


load_env_file(os.environ.get("POLMIRA_BOT_ENV", "/opt/polmira/bot/.env"))

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
POLMIRA_CMD = os.environ.get("POLMIRA_CMD", "/usr/local/bin/polmira")
APP_DIR = Path(os.environ.get("POLMIRA_APP_DIR", "/opt/polmira"))
APPS_DIR = APP_DIR / "apps"
PHONES_DIR = APP_DIR / "phones"
BOT_DIR = APP_DIR / "bot"
SENT_FILES_STATE = BOT_DIR / "sent-files.json"
POLL_TIMEOUT = int(os.environ.get("TELEGRAM_POLL_TIMEOUT", "30"))
TELEGRAM_PROXY = os.environ.get("TELEGRAM_PROXY", "")
MAX_WATCH_INTERVAL = int(os.environ.get("MAX_WATCH_INTERVAL", "10"))

SCRIPT_DIR = Path(__file__).resolve().parent
LOCAL_POLMIRA = SCRIPT_DIR / "polmira1.sh"

if TELEGRAM_PROXY:
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
            {"text": "Установить приложение", "callback_data": "install"},
            {"text": "Включить VPN", "callback_data": "vpn_on"},
        ],
        [
            {"text": "Выключить VPN", "callback_data": "vpn_off"},
            {"text": "Удалить телефон", "callback_data": "delete_confirm"},
        ],
        [{"text": "Обновить статус", "callback_data": "refresh"}],
    ]
}

CREATE_MENU = {
    "inline_keyboard": [[{"text": "Создать телефон", "callback_data": "create"}]]
}

DELETE_CONFIRM_MENU = {
    "inline_keyboard": [
        [{"text": "Да, удалить", "callback_data": "delete"}],
        [{"text": "Отмена", "callback_data": "refresh"}],
    ]
}


def api(method, payload=None):
    if not BOT_TOKEN:
        raise RuntimeError("Укажи TELEGRAM_BOT_TOKEN")

    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers)

    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 10) as resp:
        body = json.loads(resp.read().decode("utf-8"))

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

    return api("sendMessage", payload)


def answer_callback(callback_id, text=""):
    payload = {"callback_query_id": callback_id}

    if text:
        payload["text"] = text[:180]

    return api("answerCallbackQuery", payload)


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
        f"https://api.telegram.org/bot{BOT_TOKEN}/{method}",
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )

    with urllib.request.urlopen(req, timeout=180) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

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


def run_polmira(*args):
    try:
        proc = subprocess.run(
            polmira_command() + list(args),
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
        "Твой телефон готов.",
        f"Имя: {info.get('PHONE_NAME', '-')}",
        f"Логин: {info.get('USERNAME', '-')}",
    ]

    if info.get("PASSWORD"):
        lines.append(f"Пароль: {info['PASSWORD']}")

    lines.extend([
        f"VPN: {info.get('VPN_ENABLED', 'no')}",
        f"init: {info.get('INIT_STATUS', '-')}",
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
        send_message(chat_id, "Доступ есть. Телефон ещё не создан.", CREATE_MENU)
    else:
        send_message(chat_id, render_phone_status(info), PHONE_MENU)


def handle_create(chat_id, tg_id):
    send_message(chat_id, "Создаю телефон. Первый запуск может занять несколько минут...")

    try:
        output = run_polmira("bot-create-phone", str(tg_id))
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось создать телефон:\n{exc}")
        return

    info = parse_env_output(output)

    if info.get("URL"):
        send_message(chat_id, render_phone_status(info), PHONE_MENU)
    else:
        lines = [line for line in output.splitlines() if line.strip()]
        send_message(chat_id, "\n".join(lines[-10:]), PHONE_MENU)


def handle_action(chat_id, tg_id, action):
    mapping = {
        "start": ("bot-start-phone", "Запускаю телефон..."),
        "stop": ("bot-stop-phone", "Выключаю телефон..."),
        "vpn_on": ("bot-enable-vpn", "Включаю VPN..."),
        "vpn_off": ("bot-disable-vpn", "Выключаю VPN..."),
    }

    command, progress = mapping[action]
    send_message(chat_id, progress)

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


def handle_delete(chat_id, tg_id):
    send_message(chat_id, "Удаляю телефон...")

    try:
        output = run_polmira("bot-delete-phone", str(tg_id))
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось удалить телефон:\n{exc}")
        return

    send_message(chat_id, output or "Телефон удалён.", CREATE_MENU)


def app_files():
    APPS_DIR.mkdir(parents=True, exist_ok=True)
    allowed = {".apk", ".apks", ".xapk", ".apkm", ".zip"}
    return sorted(
        [path for path in APPS_DIR.iterdir() if path.is_file() and path.suffix.lower() in allowed],
        key=lambda path: path.name.lower(),
    )


def show_app_store(chat_id):
    files = app_files()

    if not files:
        send_message(chat_id, "В store пока нет приложений. Положи APK/APKS/XAPK/APKM/ZIP в /opt/polmira/apps.")
        return

    keyboard = []

    for index, path in enumerate(files[:40]):
        keyboard.append([{"text": path.name[:60], "callback_data": f"app:{index}"}])

    keyboard.append([{"text": "Обновить список", "callback_data": "install"}])
    keyboard.append([{"text": "Назад", "callback_data": "refresh"}])

    send_message(chat_id, "Выбери приложение из /opt/polmira/apps:", {"inline_keyboard": keyboard})


def handle_app_install(chat_id, tg_id, data):
    try:
        index = int(data.split(":", 1)[1])
    except (IndexError, ValueError):
        send_message(chat_id, "Не понял выбранное приложение.", PHONE_MENU)
        return

    files = app_files()

    if index < 0 or index >= len(files):
        send_message(chat_id, "Список приложений изменился. Открой store заново.", PHONE_MENU)
        return

    app_path = files[index]
    send_message(chat_id, f"Устанавливаю {app_path.name}...")

    try:
        output = run_polmira("bot-install-app", str(tg_id), str(app_path))
    except RuntimeError as exc:
        send_message(chat_id, f"Не получилось установить приложение:\n{exc}", PHONE_MENU)
        return

    send_message(chat_id, output or "Приложение установлено.", PHONE_MENU)


def handle_document(chat_id, tg_id, message):
    send_message(chat_id, "Установка доступна только из store: файлы должны лежать в /opt/polmira/apps.")


def read_phone_env(path):
    data = {}

    if not path.exists():
        return data

    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" in raw_line:
            key, value = raw_line.split("=", 1)
            data[key] = value

    return data


def load_sent_state():
    if not SENT_FILES_STATE.exists():
        return {}

    try:
        return json.loads(SENT_FILES_STATE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def save_sent_state(state):
    BOT_DIR.mkdir(parents=True, exist_ok=True)
    SENT_FILES_STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def file_is_stable(path):
    try:
        first = path.stat()
        time.sleep(1)
        second = path.stat()
    except FileNotFoundError:
        return False

    return first.st_size == second.st_size and second.st_size > 0


def send_document(chat_id, path, caption):
    return multipart_api(
        "sendDocument",
        {"chat_id": chat_id, "caption": caption[:1024]},
        {"document": path},
    )


def scan_max_downloads_once():
    state = load_sent_state()
    changed = False
    first_scan = not SENT_FILES_STATE.exists()

    for phone_dir in sorted(PHONES_DIR.glob("*")):
        env = read_phone_env(phone_dir / "phone.env")
        tg_id = env.get("TG_ID", "")
        phone_name = env.get("PHONE_NAME", phone_dir.name)

        if not tg_id:
            continue

        max_dir = phone_dir / "data" / "media" / "0" / "Download" / "MAX"

        if not max_dir.exists():
            continue

        for path in sorted(max_dir.rglob("*")):
            if not path.is_file():
                continue

            key = str(path)

            if key in state:
                continue

            if not file_is_stable(path):
                continue

            if first_scan:
                state[key] = {"sent_at": int(time.time()), "size": path.stat().st_size, "initial": True}
                changed = True
                continue

            try:
                send_document(tg_id, path, f"MAX файл с телефона {phone_name}: {path.name}")
                state[key] = {"sent_at": int(time.time()), "size": path.stat().st_size}
                changed = True
                print(f"Sent MAX file to {tg_id}: {path}")
            except Exception as exc:
                print(f"Failed to send MAX file {path}: {exc}")

    if changed:
        save_sent_state(state)


def max_watcher_loop():
    while True:
        try:
            scan_max_downloads_once()
        except Exception as exc:
            print(f"MAX watcher error: {exc}")
        time.sleep(MAX_WATCH_INTERVAL)


def handle_callback(callback):
    data = callback.get("data", "")
    message = callback.get("message") or {}
    chat_id = message.get("chat", {}).get("id")
    tg_id = callback.get("from", {}).get("id")

    answer_callback(callback["id"])

    if not chat_id or not tg_id:
        return

    if data == "create":
        handle_create(chat_id, tg_id)
    elif data == "refresh":
        show_entry_menu(chat_id, tg_id)
    elif data == "install":
        show_app_store(chat_id)
    elif data.startswith("app:"):
        handle_app_install(chat_id, tg_id, data)
    elif data == "delete_confirm":
        send_message(chat_id, "Удалить телефон и его данные?", DELETE_CONFIRM_MENU)
    elif data == "delete":
        handle_delete(chat_id, tg_id)
    elif data in {"start", "stop", "vpn_on", "vpn_off"}:
        handle_action(chat_id, tg_id, data)


def handle_message(message):
    chat_id = message.get("chat", {}).get("id")
    tg_id = message.get("from", {}).get("id")
    text = (message.get("text") or "").strip()

    if not chat_id or not tg_id:
        return

    if message.get("document"):
        handle_document(chat_id, tg_id, message)
        return

    if text in {"/start", "/menu", "menu", "меню"}:
        show_entry_menu(chat_id, tg_id)
    else:
        send_message(chat_id, "Открой меню командой /start.")


def main():
    if not BOT_TOKEN:
        raise SystemExit("Укажи TELEGRAM_BOT_TOKEN")

    offset = 0
    print("Polmira Telegram bot started")
    threading.Thread(target=max_watcher_loop, daemon=True).start()

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
