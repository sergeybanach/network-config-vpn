# network-config — project notes for Claude

Скрипты и конфигурация для аудита и тонкой настройки сети на десктопе под Debian 13 + NetworkManager + AmneziaVPN-подобный туннель (`tun0`, policy routing через таблицу `2022` и правила `9000–9010`).

---

## Структура

```
.
├── network-audit.sh           # сбор полной сетевой конфигурации в отчёт
├── report.txt/                # результаты прогонов network-audit.sh (каталоги + tar.gz)
├── report2.txt/
├── report3.txt/
└── bypass-ru/                 # selective-bypass подсистема (см. bypass-ru/README.md)
    ├── README.md              # подробное описание, схемы, диагностика
    ├── bypass-ru.nft          # nftables: set'ы + mark + masquerade
    ├── bypass-ru.service      # systemd-юнит: nft -f + ip rule fwmark
    ├── nm-dns-dnsmasq.conf    # NM: dns=dnsmasq
    ├── nm-dnsmasq-bypass-ru.conf  # dnsmasq: апстрим=stubby + nftset для .ru/.рф
    ├── extra-domains.conf     # пользовательский список не-ru доменов в обход
    ├── stubby.yml             # stubby: DoT к 1.1.1.1
    ├── sysctl-bypass-ru.conf  # net.ipv4.conf.all.src_valid_mark=1
    ├── install.sh             # развернуть всё, бэкап в /var/backups/
    ├── uninstall.sh           # полный откат
    └── dns-monitor/           # GTK GUI для просмотра DNS-запросов в реальном времени
        ├── dns-monitor.py     # Python+GTK3, парсит journalctl-поток dnsmasq
        ├── log-queries.conf   # включает log-queries в NM-managed dnsmasq
        ├── install.sh         # ставит python3-gi/gir1.2-gtk-3.0 + кладёт log-queries.conf
        ├── uninstall.sh       # снимает log-queries
        └── dns-monitor.desktop # ярлык для меню приложений (опционально)
```

### Что куда идёт после `bypass-ru/install.sh`

| Системный путь | Из репо |
|---|---|
| `/etc/nftables.d/bypass-ru.nft` | `bypass-ru.nft` |
| `/etc/systemd/system/bypass-ru.service` | `bypass-ru.service` |
| `/etc/NetworkManager/conf.d/00-bypass-ru-dns.conf` | `nm-dns-dnsmasq.conf` |
| `/etc/NetworkManager/dnsmasq.d/bypass-ru.conf` | `nm-dnsmasq-bypass-ru.conf` |
| `/etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf` | `extra-domains.conf` (не перетирается при повторе) |
| `/etc/stubby/stubby.yml` | `stubby.yml` |
| `/etc/sysctl.d/90-bypass-ru.conf` | `sysctl-bypass-ru.conf` |

---

## Среда

- **OS:** Debian 13 (trixie), kernel 6.12+
- **DNS-стек:** NetworkManager-managed dnsmasq (`dns=dnsmasq`) + stubby (DoT)
- **Файрвол:** nftables (есть Docker-таблицы под управлением iptables-nft — не трогать)
- **VPN:** активен `tun0`, peer `172.18.0.2`, default route форсируется через `ip rule` 9000–9010 в `table 2022`
- **WiFi:** `wlp0s20f3`, DHCP, шлюз `10.57.64.1`

Утилиты `iptables`/`nft`/`sysctl`/`bridge`/`iw` лежат в `/sbin` и `/usr/sbin` — не в PATH обычного пользователя; запускать через `sudo`.

---

## Правила работы в проекте

1. **Все изменения фиксируй в этом файле** в разделе [«Журнал изменений»](#журнал-изменений) ниже. Одна строка на правку: `YYYY-MM-DD — что изменилось (какие файлы)`. Пиши кратко, по факту, без воды. Если правка большая — несколько подпунктов под общим заголовком даты.

2. **Каждый ответ, в котором ты что-то правил в репозитории, заканчивай блоком с предлагаемым коммит-сообщением** в формате Conventional Commits:

   ````
   ```
   <type>(<scope>): <subject>

   <optional body>
   ```
   ````

   - `type`: `feat`, `fix`, `docs`, `refactor`, `chore`
   - `scope` (опционально): `bypass-ru`, `audit`, `claude` и т.п.
   - `subject`: одна строка ≤72 символов, в повелительном наклонении («add», «fix», а не «added/adds»), на английском
   - `body` (опционально): пояснение «почему», если из заголовка не очевидно

   Пример:
   ```
   feat(bypass-ru): route emias.info around VPN

   Add user-extras dnsmasq file so non-.ru domains can be bypassed
   without touching the policy file.
   ```

3. Если ничего не правил (только читал/диагностировал) — коммит-сообщение не нужно.

4. Не создавай новые `*.md` файлы без явной просьбы пользователя. Этот файл и `bypass-ru/README.md` — исключения, созданы по запросу.

5. Перед редактированием кода в `bypass-ru/` сверяйся с `bypass-ru/README.md` — там зафиксирована архитектура и тонкости (priority mangle, masquerade, src_valid_mark и т.д.). Если меняешь поведение — синхронно обнови README.

---

## Журнал изменений

- **2026-05-10** — добавлен модуль `bypass-ru/dns-monitor/`: GTK3-GUI на Python для real-time просмотра DNS-запросов из journal NM-managed dnsmasq, с подсветкой ошибок (NXDOMAIN/SERVFAIL/REFUSED/TIMEOUT) и отдельной вкладкой только для ошибок. Включает `log-queries.conf` для активации логирования в dnsmasq, `install.sh`/`uninstall.sh`, `.desktop`-ярлык. install.sh ставит `python3-gi`/`gir1.2-gtk-3.0`, добавляет пользователя в `systemd-journal`. Обновлён `CLAUDE.md`.
- **2026-05-10** — добавлен `CLAUDE.md` с описанием структуры и правилами работы (фиксация изменений + коммит-сообщения).
- **2026-05-09** — добавлен `bypass-ru/README.md` с полной документацией подсистемы (архитектура, схема, диагностика).
- **2026-05-08** — добавлена поддержка пользовательских доменов (`bypass-ru/extra-domains.conf`, обновлены `install.sh`/`uninstall.sh`); добавлена цепочка `snat_out` с masquerade в `bypass-ru.nft` (без неё пакеты дропались с tun0-src на LAN); добавлен stubby для DoT к 1.1.1.1 (`bypass-ru/stubby.yml`, обновлены `nm-dnsmasq-bypass-ru.conf`, `install.sh`, `uninstall.sh`); создана подсистема `bypass-ru/` для selective-bypass `.ru`/`.рф` доменов мимо VPN.
- **2026-05-08** — `network-audit.sh`: добавлен флаг `--no-connectivity` (пропуск шага 14, чтобы скрипт не зависал при сломанной связности).
- **2026-05-08** — `network-audit.sh`: добавлен флаг `-s/--single-file` (весь отчёт в один файл вместо 16 разделов).
