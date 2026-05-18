#!/usr/bin/env bash

set -e

echo
echo "======================================"
echo " Remove Polmira / Android Farm"
echo "======================================"
echo

if [ "$EUID" -ne 0 ]; then
    echo "Запусти через sudo"
    exit 1
fi

echo "Будет удалено:"
echo
echo "- /opt/android-farm"
echo "- /opt/polmira"
echo "- все телефоны"
echo "- все systemd сервисы polmira/android-phone"
echo "- binderfs helper"
echo "- polmira command"
echo
echo "Docker и nginx НЕ удаляются."
echo

read -rp "Продолжить? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено"
    exit 0
fi

echo
echo "Остановка сервисов..."

systemctl list-unit-files | awk '{print $1}' | grep -E '^(android-phone|polmira-phone|polmira-binderfs|android-farm-binderfs)' | while read -r SERVICE; do
    echo "Stopping $SERVICE"

    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true

    rm -f "/etc/systemd/system/$SERVICE"
done

systemctl daemon-reload
systemctl reset-failed

echo
echo "Удаление docker контейнеров..."

docker ps -a --format '{{.Names}}' | grep -E '^(android-farm|polmira)-' | while read -r CONTAINER; do
    echo "Removing container: $CONTAINER"
    docker rm -f "$CONTAINER" 2>/dev/null || true
done

echo
echo "Очистка процессов..."

pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true

find /tmp -name '.X*-lock' -delete 2>/dev/null || true
find /tmp/.X11-unix -type s -delete 2>/dev/null || true

echo
echo "Удаление папок..."

rm -rf /opt/android-farm
rm -rf /opt/polmira

echo
echo "Удаление команд..."

rm -f /usr/local/bin/polmira
rm -f /usr/local/bin/farm-create
rm -f /usr/local/bin/farm-delete
rm -f /usr/local/bin/binderfs-add

echo
echo "Проверка..."

echo
echo "Systemd:"
systemctl list-unit-files | grep -E 'polmira|android-phone|android-farm' || true

echo
echo "Docker:"
docker ps -a | grep -E 'polmira|android-farm' || true

echo
echo "Folders:"
ls -ld /opt/android-farm /opt/polmira 2>/dev/null || true

echo
echo "Commands:"
which polmira 2>/dev/null || true
which farm-create 2>/dev/null || true
which farm-delete 2>/dev/null || true
which binderfs-add 2>/dev/null || true

echo
echo "ГОТОВО"
