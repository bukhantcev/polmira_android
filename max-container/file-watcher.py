#!/usr/bin/env python3
import hashlib
import json
import mimetypes
import os
import socket
import time
import urllib.parse
import urllib.request
from pathlib import Path


TG_ID = os.environ.get("TG_ID", "")
POLMIRA_RELAY_URL = os.environ.get("POLMIRA_RELAY_URL", "").replace("/notify", "/file")
POLMIRA_RELAY_SECRET = os.environ.get("POLMIRA_RELAY_SECRET", "")
STATE_PATH = Path(os.environ.get("POLMIRA_FILE_WATCHER_STATE", "/home/polmira/.cache/polmira-file-watcher.json"))
SCAN_INTERVAL = float(os.environ.get("POLMIRA_FILE_WATCH_INTERVAL", "2"))
STABLE_SECONDS = float(os.environ.get("POLMIRA_FILE_STABLE_SECONDS", "3"))
MAX_FILE_BYTES = int(os.environ.get("POLMIRA_FILE_MAX_BYTES", str(49 * 1024 * 1024)))
FORCE_IPV4 = os.environ.get("TELEGRAM_FORCE_IPV4", "yes").lower() in {"1", "yes", "true", "on"}
WATCH_INTERNAL_FILES = os.environ.get("POLMIRA_WATCH_INTERNAL_FILES", "no").lower() in {"1", "yes", "true", "on"}

ROOTS = [Path("/home/polmira/Downloads")]
if WATCH_INTERNAL_FILES:
    ROOTS.append(Path("/home/polmira/.local/share/ONEME"))

EXCLUDED_PARTS = {
    ".crash_dumps",
    "logs",
    "lottieJson",
    "animojis",
    "roundAvatar",
    "squareAvatar",
    "defaultAvatar",
    "stickers",
    "crashpad.db",
    "crashpad.metric",
}

MAGIC_TYPES = [
    (b"\xff\xd8\xff", "image/jpeg", ".jpg"),
    (b"\x89PNG\r\n\x1a\n", "image/png", ".png"),
    (b"RIFF", "image/webp", ".webp"),
    (b"GIF87a", "image/gif", ".gif"),
    (b"GIF89a", "image/gif", ".gif"),
    (b"%PDF", "application/pdf", ".pdf"),
    (b"PK\x03\x04", "application/zip", ".zip"),
]


if FORCE_IPV4:
    _getaddrinfo = socket.getaddrinfo

    def _ipv4_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        return _getaddrinfo(host, port, socket.AF_INET, type, proto, flags)

    socket.getaddrinfo = _ipv4_getaddrinfo


def load_state():
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {"initialized": False, "seen": {}, "sent_hashes": {}}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    tmp.replace(STATE_PATH)


def is_excluded(path):
    parts = set(path.parts)
    if parts & EXCLUDED_PARTS:
        return True
    name = path.name.lower()
    return name.endswith((".db", ".db-wal", ".db-shm", ".lock", ".tmp", ".part", ".crdownload"))


def is_watch_candidate(path):
    if not path.is_file() or is_excluded(path):
        return False
    try:
        size = path.stat().st_size
    except OSError:
        return False
    if size <= 0 or size > MAX_FILE_BYTES:
        return False
    if str(path).startswith("/home/polmira/Downloads/"):
        return True
    path_text = str(path)
    if "/scaledImages/" in path_text and "/original/" not in path_text:
        return False
    return "/files/" in path_text


def file_type(path):
    try:
        head = path.read_bytes()[:32]
    except OSError:
        return "application/octet-stream", path.suffix

    for magic, mime_type, suffix in MAGIC_TYPES:
        if head.startswith(magic):
            if magic == b"RIFF" and b"WEBP" not in head[:16]:
                continue
            return mime_type, suffix

    suffix = path.suffix
    mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return mime_type, suffix


def upload_name(path, mime_type, suffix):
    name = path.name
    if "." in name and len(name) <= 160:
        return name

    prefix = "max-file"
    if mime_type.startswith("image/"):
        prefix = "max-photo"
    elif mime_type.startswith("video/"):
        prefix = "max-video"

    ext = suffix or mimetypes.guess_extension(mime_type) or ".bin"
    return f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}{ext}"


def caption_for(path, name):
    return f"Maxofon\nФайл: {name}"


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def send_file(path):
    if not TG_ID or not POLMIRA_RELAY_URL or not POLMIRA_RELAY_SECRET:
        return False

    mime_type, suffix = file_type(path)
    name = upload_name(path, mime_type, suffix)
    headers = {
        "Content-Type": mime_type,
        "X-Polmira-Tg-Id": TG_ID,
        "X-Polmira-Secret": POLMIRA_RELAY_SECRET,
        "X-Polmira-Filename": urllib.parse.quote(name),
        "X-Polmira-Caption": urllib.parse.quote(caption_for(path, name)),
    }
    request = urllib.request.Request(POLMIRA_RELAY_URL, data=path.read_bytes(), headers=headers)
    with urllib.request.urlopen(request, timeout=180) as response:
        response.read()
        return 200 <= response.status < 300


def iter_files():
    for root in ROOTS:
        if not root.exists():
            continue
        if root.name == "ONEME":
            yield from root.glob("user*/files/**/*")
        else:
            yield from root.rglob("*")


def mark_existing(state):
    for path in iter_files():
        if not is_watch_candidate(path):
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        state["seen"][str(path)] = {"size": stat.st_size, "mtime": stat.st_mtime, "sent": True}
    state["initialized"] = True
    save_state(state)


def process_path(state, path):
    key = str(path)
    try:
        stat = path.stat()
    except OSError:
        return

    now = time.time()
    previous = state["seen"].get(key)
    current = {"size": stat.st_size, "mtime": stat.st_mtime, "sent": False, "first_seen": now}

    if previous:
        if previous.get("size") == stat.st_size and previous.get("mtime") == stat.st_mtime:
            current["first_seen"] = previous.get("first_seen", now)
            current["sent"] = previous.get("sent", False)
        state["seen"][key] = current
    else:
        state["seen"][key] = current
        return

    if current.get("sent"):
        return
    if now - float(current.get("first_seen", now)) < STABLE_SECONDS:
        return

    try:
        digest = sha256_file(path)
        if digest in state.get("sent_hashes", {}):
            current["sent"] = True
            return
        if send_file(path):
            state.setdefault("sent_hashes", {})[digest] = key
            current["sent"] = True
            print(f"sent file {path}", flush=True)
    except Exception as exc:
        print(f"send file failed {path}: {exc}", flush=True)


def main():
    state = load_state()
    if not state.get("initialized"):
        mark_existing(state)
        print("Polmira file watcher initialized", flush=True)

    while True:
        for path in iter_files():
            if is_watch_candidate(path):
                process_path(state, path)
        save_state(state)
        time.sleep(SCAN_INTERVAL)


if __name__ == "__main__":
    main()
