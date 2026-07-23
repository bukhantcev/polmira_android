#!/usr/bin/env python3
import html
import json
import os
import re
import socket
import time
import urllib.parse
import urllib.request

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib


BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TG_ID = os.environ.get("TG_ID", "")
TELEGRAM_PROXY = os.environ.get("TELEGRAM_PROXY", "")
POLMIRA_RELAY_URL = os.environ.get("POLMIRA_RELAY_URL", "")
POLMIRA_RELAY_SECRET = os.environ.get("POLMIRA_RELAY_SECRET", "")
TARGET_HINT = os.environ.get("NOTIFY_TARGET_HINT", "MAX").lower()
FORCE_IPV4 = os.environ.get("TELEGRAM_FORCE_IPV4", "yes").lower() in {"1", "yes", "true", "on"}

if FORCE_IPV4:
    _getaddrinfo = socket.getaddrinfo

    def _ipv4_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        return _getaddrinfo(host, port, socket.AF_INET, type, proto, flags)

    socket.getaddrinfo = _ipv4_getaddrinfo

if TELEGRAM_PROXY:
    proxy_handler = urllib.request.ProxyHandler({
        "http": TELEGRAM_PROXY,
        "https": TELEGRAM_PROXY,
    })
    urllib.request.install_opener(urllib.request.build_opener(proxy_handler))


def clean_text(value):
    value = html.unescape(str(value or ""))
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("\r", "\n")
    value = re.sub(r"\n{3,}", "\n\n", value)
    return value.strip()


def is_max_notification(app_name, summary, body):
    combined = " ".join([app_name or "", summary or "", body or ""]).lower()
    if TARGET_HINT and TARGET_HINT.lower() in combined:
        return True
    return "max" in combined or "макс" in combined


def parse_max_notification(summary, body):
    body_lines = [line.strip() for line in clean_text(body).splitlines() if line.strip()]
    title = clean_text(summary)

    chat = ""
    sender = ""
    message_lines = body_lines[:]

    if body_lines:
        first = body_lines[0]
        if ":" in first and len(first.split(":", 1)[0]) <= 80:
            sender, first_text = [part.strip() for part in first.split(":", 1)]
            message_lines = ([first_text] if first_text else []) + body_lines[1:]
            chat = title if title and title != sender else ""
        elif len(body_lines) >= 2 and title and first != title and len(first) <= 80:
            chat = title
            sender = first
            message_lines = body_lines[1:]
        else:
            sender = title
    else:
        sender = title

    return chat, sender, "\n".join(message_lines).strip()


def render_max_message(summary, body):
    chat, sender, message = parse_max_notification(summary, body)
    lines = ["Maxofon"]

    if chat:
        lines.append(f"Чат: {chat}")
    if sender:
        lines.append(f"От кого: {sender}")
    if message:
        lines.extend(["", message])

    return "\n".join(lines).strip()


def send_telegram(text):
    if not BOT_TOKEN or not TG_ID or not text.strip():
        return

    if POLMIRA_RELAY_URL:
        payload = json.dumps({
            "secret": POLMIRA_RELAY_SECRET,
            "tg_id": TG_ID,
            "text": text[:3900],
        }).encode("utf-8")
        request = urllib.request.Request(
            POLMIRA_RELAY_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
        return

    payload = json.dumps({
        "chat_id": TG_ID,
        "text": text[:3900],
        "disable_web_page_preview": True,
    }).encode("utf-8")

    request = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    with urllib.request.urlopen(request, timeout=20) as response:
        response.read()


class NotificationDaemon(dbus.service.Object):
    def __init__(self):
        bus_name = dbus.service.BusName("org.freedesktop.Notifications", dbus.SessionBus())
        super().__init__(bus_name, "/org/freedesktop/Notifications")
        self.last = {}
        self.next_id = 1

    def allocate_id(self, replaces_id):
        replaces_id = int(replaces_id or 0)
        if replaces_id > 0:
            return replaces_id

        notification_id = self.next_id
        self.next_id += 1
        if self.next_id >= 2147483647:
            self.next_id = 1
        return notification_id

    def close_later(self, notification_id):
        GLib.timeout_add(500, self.close_from_timeout, notification_id)

    def close_from_timeout(self, notification_id):
        try:
            self.NotificationClosed(int(notification_id), 1)
        except Exception as exc:
            print(f"notification close failed: {exc}", flush=True)
        return False

    @dbus.service.method(
        "org.freedesktop.Notifications",
        in_signature="susssasa{sv}i",
        out_signature="u",
    )
    def Notify(self, app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout):
        notification_id = self.allocate_id(replaces_id)
        app_name = clean_text(app_name)
        summary = clean_text(summary)
        body = clean_text(body)

        if is_max_notification(app_name, summary, body):
            text = render_max_message(summary, body)
            try:
                print(
                    f"MAX notify: id={notification_id} replaces={int(replaces_id or 0)} "
                    f"app={app_name!r} summary={summary!r} body={body!r}",
                    flush=True,
                )
                send_telegram(text)
                print("telegram send ok", flush=True)
            except Exception as exc:
                print(f"telegram send failed: {exc}", flush=True)

        self.close_later(notification_id)
        return notification_id

    @dbus.service.method("org.freedesktop.Notifications", in_signature="u", out_signature="")
    def CloseNotification(self, notification_id):
        self.NotificationClosed(int(notification_id), 3)
        return

    @dbus.service.signal("org.freedesktop.Notifications", signature="uu")
    def NotificationClosed(self, notification_id, reason):
        return

    @dbus.service.method("org.freedesktop.Notifications", in_signature="", out_signature="as")
    def GetCapabilities(self):
        return ["body", "body-markup"]

    @dbus.service.method("org.freedesktop.Notifications", in_signature="", out_signature="ssss")
    def GetServerInformation(self):
        return ("Polmira", "Polmira", "1.0", "1.2")


def main():
    DBusGMainLoop(set_as_default=True)
    NotificationDaemon()
    print("Polmira notification daemon started", flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
