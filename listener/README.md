# Polmira Listener

Tiny Android companion app for Polmira. It listens to visible notifications from
MAX (`ru.oneme.app` by default) and sends them as JSON to a configured webhook.

It does not read MAX databases, does not store message history, and only sees
what Android exposes in notifications.

## Build

```bash
listener/build-apk.sh
```

The APK is written to:

```text
listener/build/polmira-listener.apk
```

## JSON payload

```json
{
  "source": "polmira-listener",
  "event": "notification",
  "phone": "me",
  "package": "ru.oneme.app",
  "key": "...",
  "title": "...",
  "text": "...",
  "conversation": "...",
  "sub_text": "...",
  "ticker": "...",
  "time": "1780040000000"
}
```

If a secret is configured, it is sent as the `X-Polmira-Secret` HTTP header.
