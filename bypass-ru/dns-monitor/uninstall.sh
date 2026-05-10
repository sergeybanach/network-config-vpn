#!/usr/bin/env bash
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root: sudo $0" >&2
    exit 1
fi

echo "==> Удаляю log-queries.conf"
rm -f /etc/NetworkManager/dnsmasq.d/log-queries.conf

echo "==> Перезапуск NetworkManager"
systemctl restart NetworkManager

echo "==> Готово. Пакеты python3-gi/gir1.2-gtk-3.0 не удаляю — они могут быть нужны другим приложениям."
