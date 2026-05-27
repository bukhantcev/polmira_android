# Polmira Telegram Bot

Бот запускается в Docker как управляющий контейнер рядом с установленной Polmira.
Новый `polmira1.sh` сам создаёт `/opt/polmira/docker-compose.bot.yml` и
`/opt/polmira/bot/.env`.

## Подготовка

Через консольное меню Polmira:

```text
18. Изменить токен/прокси бота
19. Редактировать разрешённые Telegram ID
20. Запустить / обновить бота
```

Минимально нужно указать:

```env
TELEGRAM_BOT_TOKEN=123456789:replace_me
```

Если сервер не достаёт Telegram API напрямую, укажи HTTP-прокси:

```env
TELEGRAM_PROXY=http://user:password@host:port
```

Для локального прокси на хосте, например `3x-ui`/`sing-box`, часто подходит:

```env
TELEGRAM_PROXY=http://127.0.0.1:10809
```

Установка приложений из Telegram работает как store: бот показывает только файлы из:

```text
/opt/polmira/apps
```

Новые файлы из MAX автоматически отправляются владельцу телефона из папки:

```text
/opt/polmira/phones/<name>/data/media/0/Download/MAX
```

Разрешить Telegram ID вручную:

```bash
sudo mkdir -p /opt/polmira
echo 123456789 | sudo tee -a /opt/polmira/tg-allowed.txt
```

## Запуск

```bash
docker compose -f /opt/polmira/docker-compose.bot.yml up -d
```

Compose сам подтянет `chtotos/polmira_bot:latest`, если образа ещё нет на сервере.

Логи:

```bash
docker logs -f polmira-bot
```

## Важное

Контейнер запускается как privileged sidecar и монтирует хостовые пути Docker,
systemd, nginx, `/dev` и `/opt/polmira`, потому что команды Polmira управляют
сервисами и Android-контейнерами на хосте.
