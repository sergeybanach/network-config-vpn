#!/usr/bin/env bash
#
# Включает log-queries в NM-managed dnsmasq и ставит python-зависимости
# для GUI-мониторинга dns-monitor.py.
#
# Запуск: sudo ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
echo "==> Источник: $SRC"

# 1. Зависимости для GUI
NEED_PKGS=()
dpkg -l python3-gi      2>/dev/null | grep -q '^ii' || NEED_PKGS+=(python3-gi)
dpkg -l gir1.2-gtk-3.0  2>/dev/null | grep -q '^ii' || NEED_PKGS+=(gir1.2-gtk-3.0)
if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    echo "==> Ставлю пакеты: ${NEED_PKGS[*]}"
    apt-get update -qq
    apt-get install -y "${NEED_PKGS[@]}"
fi

# 2. Включаем log-queries в dnsmasq
echo "==> /etc/NetworkManager/dnsmasq.d/log-queries.conf"
install -m 0644 "$SRC/log-queries.conf" \
    /etc/NetworkManager/dnsmasq.d/log-queries.conf

# 3. Доступ к system journal: нужен пользователю в группе adm или systemd-journal
TARGET_USER="${SUDO_USER:-${USER}}"
if [[ -n "$TARGET_USER" ]] && id "$TARGET_USER" &>/dev/null; then
    if ! id -nG "$TARGET_USER" | grep -qwE 'adm|systemd-journal'; then
        echo "==> Добавляю $TARGET_USER в группу systemd-journal"
        usermod -aG systemd-journal "$TARGET_USER"
        echo "    (после релогина journalctl будет работать без sudo)"
    fi
fi

# 4. Перезапускаем NM, чтобы dnsmasq подхватил log-queries
echo "==> Перезапуск NetworkManager"
systemctl restart NetworkManager
sleep 2

# 5. Проверка: делаем тестовый запрос и ищем его в журнале
echo
echo "==> Проверка"
host -W 2 logging-test-$$.invalid 127.0.0.1 >/dev/null 2>&1 || true
sleep 3
if journalctl -u NetworkManager --since "8 sec ago" --no-pager -o cat 2>/dev/null \
   | grep -q "query\[.*\] logging-test-$$"; then
    echo "[OK] dnsmasq логирует запросы"
else
    echo "[!]  Тестовая строка не найдена в журнале."
    echo "     Если ты не в группе adm/systemd-journal — релогинься и проверь снова."
fi

echo
echo "Запускай GUI: $SRC/dns-monitor.py"
echo "Для ярлыка в меню: cp $SRC/dns-monitor.desktop ~/.local/share/applications/"
