# Polmira Web Prototype

Отдельная веб-морда для Polmira. Основной `polmira1.sh` не меняет.

## Что умеет

- показывает телефоны из `/opt/polmira/phones`;
- показывает статусы systemd и готовность noVNC порта;
- открывает ссылку noVNC;
- включает/перезапускает и выключает телефон;
- создаёт телефон по Telegram ID через существующую команду `bot-create-phone`;
- устанавливает приложения только из `/opt/polmira/apps`;
- удаляет телефоны с `TG_ID` через существующую команду `bot-delete-phone`.

## Запуск на сервере

Скопируй в `/opt/polmira` файлы:

```text
web/server.py
Dockerfile.web
docker-compose.web.yml
```

Поменяй пароль в `docker-compose.web.yml`:

```yaml
POLMIRA_WEB_PASSWORD: "свой-пароль"
```

Запуск:

```bash
cd /opt/polmira
docker compose -f docker-compose.web.yml pull
docker compose -f docker-compose.web.yml up -d
```

Открыть через nginx:

```text
https://DOMAIN/adminpanel/
```

Логин по умолчанию:

```text
admin
```

## Важно

Это прототип для проверки UX. Наружу в интернет его лучше не открывать без
nginx basic auth, VPN или allowlist по IP.
