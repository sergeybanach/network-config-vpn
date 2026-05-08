#!/usr/bin/env bash
#
# network-audit.sh — исчерпывающий сбор сетевой конфигурации Linux
#
# Скрипт собирает максимум информации для анализа настроек сети:
# интерфейсы, адресация, маршрутизация, DNS, файрвол, сокеты,
# параметры ядра, NetworkManager/systemd-networkd, обнаружение туннелей и т.д.
#
# Использование:
#   sudo ./network-audit.sh                    # вывод на экран + сохранение отчёта
#   sudo ./network-audit.sh -o /tmp/report     # указать каталог для отчёта
#   sudo ./network-audit.sh -q                 # тихий режим (только в файл)
#   sudo ./network-audit.sh --no-archive       # не паковать отчёт в tar.gz
#   sudo ./network-audit.sh -s                 # один общий файл вместо разбиения по разделам
#   sudo ./network-audit.sh --no-connectivity  # пропустить шаг 14 (ping/tracepath во внешний мир)
#
# Результат: каталог с .txt файлами по разделам + сводный отчёт + tar.gz архив.
#
# Скрипт не модифицирует систему — только читает конфигурацию.

set -u  # обращение к неинициализированным переменным = ошибка
# намеренно НЕ используем set -e: отсутствие отдельных утилит не должно
# обрывать сбор информации; ошибки фиксируем сами.

# ---------------------------------------------------------------------------
# Параметры по умолчанию
# ---------------------------------------------------------------------------
QUIET=0
MAKE_ARCHIVE=1
SINGLE_FILE=0
SKIP_CONNECTIVITY=0
OUTDIR_BASE="/tmp"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# Парсинг аргументов
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTDIR_BASE="$2"; shift 2 ;;
        -q|--quiet)
            QUIET=1; shift ;;
        --no-archive)
            MAKE_ARCHIVE=0; shift ;;
        -s|--single-file)
            SINGLE_FILE=1; shift ;;
        --no-connectivity)
            SKIP_CONNECTIVITY=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *)
            echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

OUTDIR="${OUTDIR_BASE}/netaudit-${HOSTNAME_SHORT}-${TIMESTAMP}"
mkdir -p "$OUTDIR" || { echo "Не могу создать $OUTDIR" >&2; exit 1; }

SUMMARY="${OUTDIR}/00-summary.txt"
ERRLOG="${OUTDIR}/_errors.log"
: > "$ERRLOG"

# В режиме --single-file всё (заголовки секций + вывод команд) пишется
# в один общий файл report.txt
if [[ $SINGLE_FILE -eq 1 ]]; then
    SUMMARY="${OUTDIR}/report.txt"
fi

# Возвращает путь к файлу секции: либо отдельный файл, либо общий report.txt
sect_file() {
    if [[ $SINGLE_FILE -eq 1 ]]; then
        echo "$SUMMARY"
    else
        echo "${OUTDIR}/$1"
    fi
}

# ---------------------------------------------------------------------------
# Утилиты вывода
# ---------------------------------------------------------------------------
say() {
    # Печатаем на экран (если не тихий режим) И в summary
    [[ $QUIET -eq 0 ]] && echo "$@"
    echo "$@" >> "$SUMMARY"
}

section() {
    local title="$1"
    say ""
    say "=============================================================="
    say "  ${title}"
    say "=============================================================="
}

# Проверка наличия команды
have() { command -v "$1" >/dev/null 2>&1; }

# Запуск команды с записью результата в файл раздела.
# $1 = файл назначения, остальное = команда.
# Если команды нет — пишем пометку, а не падаем.
run() {
    local outfile="$1"; shift
    {
        echo "### \$ $*"
        echo "### $(date -Iseconds)"
        echo "------------------------------------------------------------"
        if have "$1"; then
            "$@" 2>&1
            local rc=$?
            echo "------------------------------------------------------------"
            echo "### exit=${rc}"
        else
            echo "[команда '$1' не установлена — пропуск]"
            echo "missing-command: $1" >> "$ERRLOG"
        fi
        echo
    } >> "$outfile"
}

# Вывод файла, если он существует
dump_file() {
    local outfile="$1" src="$2"
    {
        echo "### file: $src"
        if [[ -e "$src" ]]; then
            if [[ -r "$src" ]]; then
                echo "------------------------------------------------------------"
                cat -- "$src" 2>&1
                echo "------------------------------------------------------------"
            else
                echo "[нет прав на чтение — попробуйте sudo]"
            fi
        else
            echo "[не существует]"
        fi
        echo
    } >> "$outfile"
}

# Дамп всех файлов из каталога (с фильтром по маске)
dump_dir() {
    local outfile="$1" dir="$2" pattern="${3:-*}"
    {
        echo "### dir: $dir (pattern: $pattern)"
        if [[ -d "$dir" ]]; then
            shopt -s nullglob
            local found=0
            for f in "$dir"/$pattern; do
                [[ -f "$f" ]] || continue
                found=1
                echo "--- $f ---"
                cat -- "$f" 2>&1 || echo "[ошибка чтения]"
                echo
            done
            shopt -u nullglob
            [[ $found -eq 0 ]] && echo "[файлов по маске не найдено]"
        else
            echo "[каталог отсутствует]"
        fi
        echo
    } >> "$outfile"
}

# ---------------------------------------------------------------------------
# Стартовая проверка
# ---------------------------------------------------------------------------
section "АУДИТ СЕТЕВОЙ КОНФИГУРАЦИИ"
say "Хост:        $(hostname -f 2>/dev/null || hostname)"
say "Дата:        $(date -Iseconds)"
say "Ядро:        $(uname -r)"
say "ОС:          $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)"
say "Архитектура: $(uname -m)"
say "Uptime:      $(uptime -p 2>/dev/null || uptime)"
say "Запустил:    $(id -un) (uid=$(id -u))"
say "Каталог:     $OUTDIR"
if [[ $(id -u) -ne 0 ]]; then
    say ""
    say "ВНИМАНИЕ: запуск без root. Некоторые данные будут недоступны"
    say "(правила iptables/nftables, conntrack, часть /proc, ss -p и т.д.)."
fi

# ---------------------------------------------------------------------------
# 1. Хост и базовая идентификация
# ---------------------------------------------------------------------------
F="$(sect_file 01-host.txt)"
section "1. Хост и идентификация → 01-host.txt"
run "$F" hostname -A
run "$F" hostnamectl
dump_file "$F" /etc/hostname
dump_file "$F" /etc/hosts
dump_file "$F" /etc/host.conf
dump_file "$F" /etc/nsswitch.conf
dump_file "$F" /etc/networks
dump_file "$F" /etc/os-release

# ---------------------------------------------------------------------------
# 2. Сетевые интерфейсы (link-уровень)
# ---------------------------------------------------------------------------
F="$(sect_file 02-interfaces.txt)"
section "2. Сетевые интерфейсы → 02-interfaces.txt"
run "$F" ip -d link show
run "$F" ip -s link show           # счётчики
run "$F" ip -d -s addr show
# legacy ifconfig — тоже информативен (другой формат)
run "$F" ifconfig -a

# ethtool по каждому реальному интерфейсу
if have ethtool && have ip; then
    {
        echo "### ethtool по каждому интерфейсу"
        echo "------------------------------------------------------------"
        # Берём имена интерфейсов из ip link
        for iface in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//'); do
            [[ "$iface" == "lo" ]] && continue
            echo
            echo "===== $iface ====="
            ethtool "$iface"          2>&1 || true
            echo "--- driver ---"
            ethtool -i "$iface"       2>&1 || true
            echo "--- pause ---"
            ethtool -a "$iface"       2>&1 || true
            echo "--- ring ---"
            ethtool -g "$iface"       2>&1 || true
            echo "--- features ---"
            ethtool -k "$iface"       2>&1 || true
            echo "--- coalesce ---"
            ethtool -c "$iface"       2>&1 || true
            echo "--- statistics ---"
            ethtool -S "$iface"       2>&1 || true
        done
        echo "------------------------------------------------------------"
    } >> "$F"
fi

# Сводка по /sys/class/net
{
    echo "### /sys/class/net (сводно)"
    echo "------------------------------------------------------------"
    if [[ -d /sys/class/net ]]; then
        for iface in /sys/class/net/*; do
            name="${iface##*/}"
            echo "----- $name -----"
            for attr in address operstate carrier mtu speed duplex type flags; do
                val="$(cat "$iface/$attr" 2>/dev/null || echo n/a)"
                printf "  %-12s = %s\n" "$attr" "$val"
            done
        done
    fi
    echo
} >> "$F"

# ---------------------------------------------------------------------------
# 3. IP-адресация и маршрутизация
# ---------------------------------------------------------------------------
F="$(sect_file 03-routing.txt)"
section "3. Адресация и маршрутизация → 03-routing.txt"
run "$F" ip -4 addr show
run "$F" ip -6 addr show
run "$F" ip -4 route show
run "$F" ip -6 route show
run "$F" ip route show table all      # все таблицы маршрутизации
run "$F" ip rule show                 # policy routing (IPv4)
run "$F" ip -6 rule show              # policy routing (IPv6)
run "$F" ip neigh show                # ARP / NDP
run "$F" ip -6 neigh show
# Альтернативные представления
run "$F" route -n
run "$F" arp -an
# Таблицы маршрутизации (имена)
dump_file "$F" /etc/iproute2/rt_tables
dump_dir  "$F" /etc/iproute2/rt_tables.d

# ---------------------------------------------------------------------------
# 4. DNS-резолвер
# ---------------------------------------------------------------------------
F="$(sect_file 04-dns.txt)"
section "4. DNS → 04-dns.txt"
dump_file "$F" /etc/resolv.conf
# Часто это симлинк — покажем цель
{
    echo "### realpath /etc/resolv.conf"
    readlink -f /etc/resolv.conf 2>/dev/null || echo "[нет]"
    echo
} >> "$F"
dump_file "$F" /etc/gai.conf
dump_file "$F" /etc/systemd/resolved.conf
dump_dir  "$F" /etc/systemd/resolved.conf.d
run "$F" resolvectl status
run "$F" resolvectl statistics
run "$F" resolvectl dns
run "$F" resolvectl domain
# Тестовый запрос (показывает, какой резолвер фактически отвечает)
run "$F" getent hosts localhost
run "$F" getent ahosts "$(hostname)"

# ---------------------------------------------------------------------------
# 5. Сокеты, прослушиваемые порты, активные соединения
# ---------------------------------------------------------------------------
F="$(sect_file 05-sockets.txt)"
section "5. Сокеты и соединения → 05-sockets.txt"
# -t TCP, -u UDP, -x UNIX, -w RAW, -l listen, -n числа, -p процессы, -e расш.
run "$F" ss -tulnp
run "$F" ss -tunap                   # все TCP/UDP
run "$F" ss -lnxp                    # UNIX listening
run "$F" ss -s                       # сводка
run "$F" ss -tin                     # TCP с расширенной инфой (cwnd, rtt)
# legacy
run "$F" netstat -tulnp
run "$F" netstat -an

# ---------------------------------------------------------------------------
# 6. Файрвол и NAT
# ---------------------------------------------------------------------------
F="$(sect_file 06-firewall.txt)"
section "6. Файрвол / NAT → 06-firewall.txt"
# nftables — современный
run "$F" nft list ruleset
# iptables-legacy и nf_tables через iptables
run "$F" iptables -S
run "$F" iptables -L -n -v --line-numbers
run "$F" iptables -t nat -L -n -v --line-numbers
run "$F" iptables -t mangle -L -n -v --line-numbers
run "$F" iptables -t raw -L -n -v --line-numbers
run "$F" ip6tables -S
run "$F" ip6tables -L -n -v --line-numbers
run "$F" ip6tables -t nat -L -n -v --line-numbers
# ebtables (мост)
run "$F" ebtables -L
# arptables
run "$F" arptables -L
# UFW
run "$F" ufw status verbose
# firewalld
run "$F" firewall-cmd --state
run "$F" firewall-cmd --list-all-zones
run "$F" firewall-cmd --get-active-zones
# Conntrack (требует модуль и обычно root)
run "$F" conntrack -L
run "$F" conntrack -S
dump_file "$F" /proc/net/nf_conntrack

# ---------------------------------------------------------------------------
# 7. Параметры ядра (sysctl)
# ---------------------------------------------------------------------------
F="$(sect_file 07-sysctl.txt)"
section "7. Параметры ядра → 07-sysctl.txt"
{
    echo "### sysctl -a (только сетевые)"
    echo "------------------------------------------------------------"
    if have sysctl; then
        sysctl -a 2>/dev/null | grep -E '^(net\.|kernel\.(hostname|domainname))' | sort
    else
        echo "[sysctl не найден]"
    fi
    echo
} >> "$F"
# Конфиги, из которых грузятся параметры при загрузке
dump_file "$F" /etc/sysctl.conf
dump_dir  "$F" /etc/sysctl.d            "*.conf"
dump_dir  "$F" /run/sysctl.d            "*.conf"
dump_dir  "$F" /usr/lib/sysctl.d        "*.conf"
dump_dir  "$F" /usr/local/lib/sysctl.d  "*.conf"

# Ключевые точечные параметры для быстрого взгляда
{
    echo "### Ключевые параметры"
    echo "------------------------------------------------------------"
    for key in \
        net.ipv4.ip_forward \
        net.ipv6.conf.all.forwarding \
        net.ipv4.conf.all.rp_filter \
        net.ipv4.conf.default.rp_filter \
        net.ipv4.conf.all.accept_redirects \
        net.ipv4.conf.all.send_redirects \
        net.ipv4.conf.all.accept_source_route \
        net.ipv4.conf.all.log_martians \
        net.ipv4.icmp_echo_ignore_broadcasts \
        net.ipv4.icmp_echo_ignore_all \
        net.ipv4.tcp_syncookies \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_available_congestion_control \
        net.core.default_qdisc \
        net.core.somaxconn \
        net.core.rmem_max net.core.wmem_max \
        net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv6.conf.all.disable_ipv6 \
        net.bridge.bridge-nf-call-iptables \
        net.bridge.bridge-nf-call-ip6tables ; do
        val="$(sysctl -n "$key" 2>/dev/null || echo "[нет]")"
        printf "  %-50s = %s\n" "$key" "$val"
    done
    echo
} >> "$F"

# ---------------------------------------------------------------------------
# 8. NetworkManager
# ---------------------------------------------------------------------------
F="$(sect_file 08-networkmanager.txt)"
section "8. NetworkManager → 08-networkmanager.txt"
run "$F" nmcli general status
run "$F" nmcli general permissions
run "$F" nmcli networking connectivity check
run "$F" nmcli device status
run "$F" nmcli -f all device show
run "$F" nmcli -f all connection show
run "$F" nmcli connection show --active
# Профили подключений
dump_dir "$F" /etc/NetworkManager/system-connections "*"
dump_file "$F" /etc/NetworkManager/NetworkManager.conf
dump_dir  "$F" /etc/NetworkManager/conf.d            "*.conf"
dump_dir  "$F" /etc/NetworkManager/dispatcher.d      "*"

# ---------------------------------------------------------------------------
# 9. systemd-networkd / systemd-resolved
# ---------------------------------------------------------------------------
F="$(sect_file 09-systemd-networkd.txt)"
section "9. systemd-networkd → 09-systemd-networkd.txt"
run "$F" networkctl status
run "$F" networkctl list
run "$F" networkctl lldp
dump_dir "$F" /etc/systemd/network          "*"
dump_dir "$F" /run/systemd/network          "*"
dump_dir "$F" /usr/lib/systemd/network      "*"

# ---------------------------------------------------------------------------
# 10. Дистрибутивные конфиги (Debian/Ubuntu/RHEL/SUSE)
# ---------------------------------------------------------------------------
F="$(sect_file 10-distro-configs.txt)"
section "10. Дистрибутивные конфиги → 10-distro-configs.txt"
# Debian/Ubuntu (ifupdown)
dump_file "$F" /etc/network/interfaces
dump_dir  "$F" /etc/network/interfaces.d         "*"
# Netplan (Ubuntu)
dump_dir  "$F" /etc/netplan                      "*.yaml"
run       "$F" netplan get
# RHEL/CentOS
dump_dir  "$F" /etc/sysconfig/network-scripts    "ifcfg-*"
dump_dir  "$F" /etc/sysconfig/network-scripts    "route-*"
dump_dir  "$F" /etc/sysconfig/network-scripts    "rule-*"
dump_file "$F" /etc/sysconfig/network
# SUSE
dump_dir  "$F" /etc/sysconfig/network            "ifcfg-*"
dump_dir  "$F" /etc/sysconfig/network            "ifroute-*"
# DHCP-клиенты
dump_dir  "$F" /var/lib/dhcp                     "*.lease*"
dump_dir  "$F" /var/lib/NetworkManager           "*.lease*"
dump_dir  "$F" /var/lib/dhclient                 "*"
dump_dir  "$F" /etc/dhcp                         "*.conf"

# ---------------------------------------------------------------------------
# 11. Беспроводные сети
# ---------------------------------------------------------------------------
F="$(sect_file 11-wireless.txt)"
section "11. Wi-Fi → 11-wireless.txt"
run "$F" iw dev
run "$F" iw reg get
run "$F" rfkill list
# По каждому беспроводному интерфейсу
if have iw; then
    for w in $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'); do
        {
            echo "===== $w ====="
            iw dev "$w" link    2>&1
            iw dev "$w" info    2>&1
            iw dev "$w" station dump 2>&1
        } >> "$F"
    done
fi
# wpa_supplicant
dump_file "$F" /etc/wpa_supplicant/wpa_supplicant.conf

# ---------------------------------------------------------------------------
# 12. Мосты, бондинг, VLAN, туннели, namespaces
# ---------------------------------------------------------------------------
F="$(sect_file 12-bridges-bonds-tunnels.txt)"
section "12. Мосты/бонды/туннели/netns → 12-bridges-bonds-tunnels.txt"
# Linux bridge
run "$F" bridge link show
run "$F" bridge fdb show
run "$F" bridge vlan show
# Старая утилита
run "$F" brctl show
# Bonding
{
    echo "### /proc/net/bonding/*"
    echo "------------------------------------------------------------"
    if [[ -d /proc/net/bonding ]]; then
        for b in /proc/net/bonding/*; do
            [[ -f "$b" ]] || continue
            echo "----- $b -----"
            cat "$b" 2>&1
        done
    else
        echo "[бондинг не используется]"
    fi
    echo
} >> "$F"
# Teamd
run "$F" teamdctl --help    # просто маркер наличия
# VLAN
dump_file "$F" /proc/net/vlan/config
# Туннели
run "$F" ip tunnel show
run "$F" ip -6 tunnel show
run "$F" ip link show type vxlan
run "$F" ip link show type wireguard
# WireGuard
run "$F" wg show all
run "$F" wg showconf wg0
dump_dir "$F" /etc/wireguard "*.conf"
# OpenVPN
dump_dir "$F" /etc/openvpn "*.conf"
dump_dir "$F" /etc/openvpn/server "*.conf"
dump_dir "$F" /etc/openvpn/client "*.conf"
# Network namespaces
run "$F" ip netns list
if have ip; then
    for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
        {
            echo "===== netns: $ns ====="
            ip netns exec "$ns" ip -d addr   2>&1
            ip netns exec "$ns" ip route     2>&1
            ip netns exec "$ns" ss -tulnp    2>&1
        } >> "$F"
    done
fi

# ---------------------------------------------------------------------------
# 13. Прокси, переменные окружения, разное
# ---------------------------------------------------------------------------
F="$(sect_file 13-proxy-misc.txt)"
section "13. Прокси и прочее → 13-proxy-misc.txt"
{
    echo "### Прокси-переменные окружения текущей сессии"
    echo "------------------------------------------------------------"
    env | grep -iE '^(http_|https_|ftp_|all_|no_)proxy' | sort || echo "[нет]"
    echo
} >> "$F"
dump_file "$F" /etc/environment
dump_file "$F" /etc/profile.d/proxy.sh
dump_file "$F" /etc/wgetrc
dump_file "$F" /etc/apt/apt.conf.d/95proxies
dump_dir  "$F" /etc/apt/apt.conf.d "*proxy*"
dump_file "$F" /etc/yum.conf
dump_file "$F" /etc/dnf/dnf.conf
# /etc/services и /etc/protocols — для справки
dump_file "$F" /etc/protocols
# Важные счётчики /proc/net
{
    echo "### /proc/net/* (сводки)"
    echo "------------------------------------------------------------"
    for f in dev snmp netstat sockstat sockstat6 route ipv6_route ip_tables_names \
             nf_conntrack tcp tcp6 udp udp6 unix; do
        p="/proc/net/$f"
        if [[ -r "$p" ]]; then
            echo "----- $p -----"
            # tcp/udp могут быть очень большими — обрезаем
            case "$f" in
                tcp|tcp6|udp|udp6|unix|nf_conntrack)
                    head -n 50 "$p" 2>&1
                    lines="$(wc -l < "$p" 2>/dev/null || echo 0)"
                    echo "[... показаны первые 50 строк из $lines]"
                    ;;
                *) cat "$p" 2>&1 ;;
            esac
        fi
    done
    echo
} >> "$F"

# ---------------------------------------------------------------------------
# 14. Связность и базовая диагностика
# ---------------------------------------------------------------------------
if [[ $SKIP_CONNECTIVITY -eq 1 ]]; then
    section "14. Связность → пропущено (--no-connectivity)"
else
    F="$(sect_file 14-connectivity.txt)"
    section "14. Связность → 14-connectivity.txt"
    # Шлюз по умолчанию (IPv4)
    GW4="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    GW6="$(ip -6 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    {
        echo "### default gateway (IPv4) = ${GW4:-нет}"
        echo "### default gateway (IPv6) = ${GW6:-нет}"
        echo
    } >> "$F"
    [[ -n "${GW4:-}" ]] && run "$F" ping -c 3 -W 2 "$GW4"
    [[ -n "${GW6:-}" ]] && run "$F" ping6 -c 3 -W 2 "$GW6"
    # Резолв и пинг публичных хостов (по DNS — чтобы проверить и его)
    run "$F" getent ahosts one.one.one.one
    run "$F" ping -c 2 -W 2 1.1.1.1
    run "$F" ping -c 2 -W 2 8.8.8.8
    # Трассировки — необязательны, но информативны
    run "$F" tracepath -n 1.1.1.1
    # MTU path discovery подсказка через ping (не обязательно)
    [[ -n "${GW4:-}" ]] && run "$F" ping -M do -s 1472 -c 2 -W 2 "$GW4"
fi

# ---------------------------------------------------------------------------
# 15. Контейнерные сети (Docker/Podman/k8s) — если установлены
# ---------------------------------------------------------------------------
F="$(sect_file 15-containers.txt)"
section "15. Контейнерные сети → 15-containers.txt"
run "$F" docker network ls
run "$F" docker network inspect bridge
run "$F" podman network ls
run "$F" virsh net-list --all
# CNI
dump_dir "$F" /etc/cni/net.d "*"

# ---------------------------------------------------------------------------
# 16. Сводка для быстрого взгляда
# ---------------------------------------------------------------------------
section "СВОДКА"
say ""
say "Интерфейсы (link state):"
ip -br link 2>/dev/null | sed 's/^/  /' | tee -a "$SUMMARY" >/dev/null
[[ $QUIET -eq 0 ]] && ip -br link 2>/dev/null | sed 's/^/  /'

say ""
say "IPv4 адреса:"
ip -4 -br addr 2>/dev/null | sed 's/^/  /' | tee -a "$SUMMARY" >/dev/null
[[ $QUIET -eq 0 ]] && ip -4 -br addr 2>/dev/null | sed 's/^/  /'

say ""
say "Маршрут по умолчанию:"
ip -4 route show default 2>/dev/null | sed 's/^/  /' | tee -a "$SUMMARY" >/dev/null
[[ $QUIET -eq 0 ]] && ip -4 route show default 2>/dev/null | sed 's/^/  /'

say ""
say "DNS-серверы (из resolv.conf):"
grep -E '^\s*nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /' | tee -a "$SUMMARY" >/dev/null
[[ $QUIET -eq 0 ]] && grep -E '^\s*nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'

say ""
say "Прослушиваемые TCP-порты:"
ss -tlnH 2>/dev/null | awk '{print "  " $4}' | sort -u | tee -a "$SUMMARY" >/dev/null
[[ $QUIET -eq 0 ]] && ss -tlnH 2>/dev/null | awk '{print "  " $4}' | sort -u

if [[ -s "$ERRLOG" ]]; then
    say ""
    say "Замечания (см. _errors.log):"
    sort -u "$ERRLOG" | sed 's/^/  /' | tee -a "$SUMMARY" >/dev/null
fi

# ---------------------------------------------------------------------------
# Архив
# ---------------------------------------------------------------------------
if [[ $MAKE_ARCHIVE -eq 1 ]] && have tar; then
    ARCHIVE="${OUTDIR_BASE}/$(basename "$OUTDIR").tar.gz"
    if tar -czf "$ARCHIVE" -C "$OUTDIR_BASE" "$(basename "$OUTDIR")" 2>/dev/null; then
        say ""
        say "Архив отчёта: $ARCHIVE"
    else
        say ""
        say "Не удалось создать архив (tar)."
    fi
fi

say ""
say "Готово. Каталог отчёта: $OUTDIR"
exit 0