#!/usr/bin/env bash
#
# Откатывает изменения, сделанные install.sh.
# Запускать: sudo ./uninstall.sh

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Нужны права root: sudo $0" >&2
    exit 1
fi

echo "==> Останавливаю и удаляю bypass-ru.service"
systemctl disable --now bypass-ru.service 2>/dev/null || true
rm -f /etc/systemd/system/bypass-ru.service
systemctl daemon-reload

echo "==> Удаляю ip rule (на случай, если сервис не отработал ExecStop)"
ip    rule del fwmark 0x1 lookup main pref 8000 2>/dev/null || true
ip -6 rule del fwmark 0x1 lookup main pref 8000 2>/dev/null || true

echo "==> Удаляю nft-таблицу"
nft delete table inet bypass 2>/dev/null || true

echo "==> Удаляю nftables-конфиг"
rm -f /etc/nftables.d/bypass-ru.nft
rmdir --ignore-fail-on-non-empty /etc/nftables.d 2>/dev/null || true

echo "==> Удаляю sysctl-настройку"
rm -f /etc/sysctl.d/90-bypass-ru.conf

echo "==> Останавливаю stubby"
systemctl disable --now stubby.service 2>/dev/null || true

echo "==> Возвращаю NM в обычный режим (без dnsmasq)"
rm -f /etc/NetworkManager/conf.d/00-bypass-ru-dns.conf
rm -f /etc/NetworkManager/dnsmasq.d/bypass-ru.conf

echo "==> Перезапуск NetworkManager"
systemctl restart NetworkManager
sleep 2

echo
echo "==> Состояние после отката"
echo "--- ip rule ---"
ip rule show | head -15
echo
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null
echo
echo "==> Готово."
