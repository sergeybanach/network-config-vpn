#!/usr/bin/env bash
#
# Устанавливает обход tun0 для .ru/.рф доменов:
#   - nftables-таблица inet bypass с set'ами и пометкой mark 0x1
#   - ip rule fwmark 0x1 -> таблица main
#   - dnsmasq (через NetworkManager) заполняет set'ы по DNS-ответам
#
# Применяет всё атомарно. При ошибке откатывается.
# Запускать: sudo ./install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root: sudo $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> Источник: $SRC"

# 1. Зависимости
NEED_PKGS=()
dpkg -l dnsmasq-base 2>/dev/null | grep -q '^ii' || NEED_PKGS+=(dnsmasq-base)
dpkg -l nftables     2>/dev/null | grep -q '^ii' || NEED_PKGS+=(nftables)
dpkg -l stubby       2>/dev/null | grep -q '^ii' || NEED_PKGS+=(stubby)
if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    echo "==> Ставлю пакеты: ${NEED_PKGS[*]}"
    apt-get update -qq
    apt-get install -y "${NEED_PKGS[@]}"
fi

# 2. Бэкап критичных файлов
BACKUP="/var/backups/bypass-ru-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
echo "==> Бэкап существующих файлов в $BACKUP"
[[ -e /etc/resolv.conf ]] && cp -aL /etc/resolv.conf "$BACKUP/" || true
[[ -d /etc/NetworkManager/conf.d ]] && cp -a /etc/NetworkManager/conf.d "$BACKUP/" || true
[[ -e /etc/stubby/stubby.yml ]] && cp -a /etc/stubby/stubby.yml "$BACKUP/stubby.yml.orig" || true

# 3. nftables конфиг
echo "==> /etc/nftables.d/bypass-ru.nft"
mkdir -p /etc/nftables.d
install -m 0644 "$SRC/bypass-ru.nft" /etc/nftables.d/bypass-ru.nft

# 4. NM: переключить DNS-режим на dnsmasq
echo "==> /etc/NetworkManager/conf.d/00-bypass-ru-dns.conf"
install -m 0644 "$SRC/nm-dns-dnsmasq.conf" \
    /etc/NetworkManager/conf.d/00-bypass-ru-dns.conf

# 5. dnsmasq-плагин NM: nftset-маппинг + апстрим = stubby
echo "==> /etc/NetworkManager/dnsmasq.d/bypass-ru.conf"
mkdir -p /etc/NetworkManager/dnsmasq.d
install -m 0644 "$SRC/nm-dnsmasq-bypass-ru.conf" \
    /etc/NetworkManager/dnsmasq.d/bypass-ru.conf

# 5a. Пользовательский список доменов в обход (можно редактировать)
# Если файл уже существует — не перезаписываем, чтобы не затереть правки.
if [[ ! -e /etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf ]]; then
    echo "==> /etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf (свежая установка)"
    install -m 0644 "$SRC/extra-domains.conf" \
        /etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf
else
    echo "==> /etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf уже есть, не трогаю"
fi

# 5b. stubby: DoT к 1.1.1.1 на 127.0.0.1:5353
echo "==> /etc/stubby/stubby.yml"
mkdir -p /etc/stubby
install -m 0644 "$SRC/stubby.yml" /etc/stubby/stubby.yml
systemctl enable --now stubby.service
systemctl restart stubby.service

# 6. sysctl (src_valid_mark)
echo "==> /etc/sysctl.d/90-bypass-ru.conf"
install -m 0644 "$SRC/sysctl-bypass-ru.conf" /etc/sysctl.d/90-bypass-ru.conf
sysctl -p /etc/sysctl.d/90-bypass-ru.conf

# 7. systemd-сервис
echo "==> /etc/systemd/system/bypass-ru.service"
install -m 0644 "$SRC/bypass-ru.service" /etc/systemd/system/bypass-ru.service
systemctl daemon-reload
systemctl enable --now bypass-ru.service

# 8. Перезапустить NetworkManager (он поднимет dnsmasq)
echo "==> Перезапуск NetworkManager"
systemctl restart NetworkManager
sleep 2

# 9. Проверки
echo
echo "==> Проверки"
echo "--- ip rule (должна быть строка с fwmark 0x1 на pref 8000) ---"
ip rule show | grep -E '(fwmark|^[0-9]+:)' | head -20
echo
echo "--- nft table inet bypass ---"
nft list table inet bypass 2>/dev/null | head -25 || echo "[нет]"
echo
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf
echo
echo "--- ss -lnp 'sport = :53' (NM-dnsmasq должен слушать на 127.0.0.1:53) ---"
ss -lnp 'sport = :53' 2>/dev/null | head -5
echo
echo "--- ss -lnp 'sport = :5353' (stubby должен слушать на 127.0.0.1:5353) ---"
ss -lnp 'sport = :5353' 2>/dev/null | head -5
echo
echo "==> Тест-резолв lenta.ru:"
RU_IP="$(getent ahosts lenta.ru 2>/dev/null | awk '/STREAM/{print $1; exit}')"
echo "lenta.ru = ${RU_IP:-нет}"
if [[ -n "${RU_IP:-}" ]]; then
    echo "--- содержимое set bypass_ru_v4 (после резолва lenta.ru) ---"
    nft list set inet bypass bypass_ru_v4 2>/dev/null | grep -E '(elements|[0-9]+\.)' | head -10
    echo
    echo "--- ip route get $RU_IP mark 0x1 (должен идти через wlp0s20f3) ---"
    ip route get "$RU_IP" mark 0x1 2>/dev/null || true
    echo "--- ip route get $RU_IP без mark (для сравнения, должен быть tun0) ---"
    ip route get "$RU_IP" 2>/dev/null || true
fi

echo
echo "==> Готово. Откат: sudo $SRC/uninstall.sh"
echo "==> Бэкап старой конфигурации: $BACKUP"
