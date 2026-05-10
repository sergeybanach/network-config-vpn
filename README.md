# bypass-ru

Выборочный обход VPN по доменам + DNS поверх TLS.

- Домены в зонах `.ru`, `.рф` и заданные пользователем (например `emias.info`) идут **напрямую через WiFi**, минуя VPN-туннель.
- Весь остальной трафик идёт **через VPN** (как и до установки).
- DNS-запросы шифруются (DoT к Cloudflare 1.1.1.1) и инкапсулируются в VPN — провайдер не видит ни plain-DNS, ни даже факта DNS-соединения к Cloudflare.

---

## 1. Зачем это нужно

При активном VPN ВЕСЬ трафик идёт в `tun0`. Это даёт:

- замедление для русских сайтов (трафик делает крюк через VPN-сервер за рубежом);
- блокировки на стороне ru-ресурсов, фильтрующих иностранные IP (госуслуги, банки, медицина, видеосервисы);
- DNS-запросы видит провайдер, если резолвер выбирается из DHCP, и эти запросы могут быть подменены/залогированы.

Решение: на уровне ядра разделять трафик **по IP назначения**, при этом IP-список заполнять автоматически из DNS-ответов для нужных доменов.

---

## 2. Архитектура

```
              ┌──────────────────────┐
              │  приложение/браузер  │
              └──────────┬───────────┘
                         │ getaddrinfo()
                         ▼  /etc/resolv.conf → 127.0.0.1
              ┌──────────────────────┐
              │  dnsmasq (NM-managed)│  слушает 127.0.0.1:53
              │   nftset=/ru/.../    │  при ответе кладёт IP
              │   nftset=/emias.info │  в nft set bypass_ru_v4
              └──────────┬───────────┘
                         │ forward на 127.0.0.1:5353
                         ▼
              ┌──────────────────────┐
              │       stubby         │  DoT-форвардер
              └──────────┬───────────┘
                         │ TCP/853 + TLS
                         ▼
              ┌──────────────────────┐
              │  ip rule (без mark)  │
              │   → table 2022       │
              │   → default tun0     │
              └──────────┬───────────┘
                         │ зашифрованный VPN до 1.1.1.1
                         ▼
                    1.1.1.1:853 (Cloudflare DoT)


─── Обычный HTTP-запрос к ru-сайту ───────────────────────────

 приложение → connect(81.19.72.33:443)
        │
        ▼ нет mark, default → tun0 (table 2022)
 OUTPUT/mangle hook
 ┌──────────────────────────────────┐
 │ chain mark_out (inet bypass)     │
 │  ip daddr @bypass_ru_v4 → mark=1 │
 └──────────────────────────────────┘
        │
        ▼ kernel re-route (type route)
 ip rule: pref 8000, fwmark 0x1 → table main → default 10.57.64.1 dev wlp0s20f3
        │
        ▼ POSTROUTING/srcnat
 ┌──────────────────────────────────┐
 │ chain snat_out (inet bypass)     │
 │  meta mark 0x1 → masquerade      │  src: 172.18.0.1 → 10.57.67.209
 └──────────────────────────────────┘
        │
        ▼
 wlp0s20f3 → LAN → ISP → 81.19.72.33
```

---

## 3. Принцип работы

### 3.1. Домен → IP в bypass-set

`dnsmasq` поддерживает директиву `nftset=/<суффикс>/<inet|6>#<family>#<table>#<set>`. Когда приходит ответ DNS, IP-адреса из ответа кладутся в указанный nftables-set.

Важные свойства:

- Совпадение **по суффиксу**: `nftset=/ru/...` ловит любой `*.ru`, включая поддомены любой глубины.
- Записи в set'ах живут с timeout `1h` (и продлеваются при каждом следующем резолве). Если домен перестал запрашиваться — IP сам выпадет.
- IP попадает в set **только** при резолве через локальный dnsmasq. Поэтому критично, чтобы система пользовалась резолвером 127.0.0.1 (см. раздел 5).

### 3.2. IP в set → mark на пакете

```
chain mark_out {
    type route hook output priority mangle; policy accept;
    ip  daddr @bypass_ru_v4 meta mark set 0x1
    ip6 daddr @bypass_ru_v6 meta mark set 0x1
}
```

Ключ — `type route`. Цепочка стоит на хуке `output`, и установка `meta mark` после её прохождения **запускает повторный route lookup** в ядре. Без `type route` mark был бы установлен, но маршрут уже выбран — пакет ушёл бы по старому пути.

`priority mangle` (-150) — стандартное место для маркировки до основной фильтрации.

### 3.3. mark → таблица маршрутизации main

```
ip rule add fwmark 0x1 lookup main pref 8000
```

Активная VPN держит свои `ip rule` на pref `9000–9010`, форсирующие default через tun0:

```
9000:  from all to 172.18.0.0/30 lookup 2022
9001:  from all lookup 2022 suppress_prefixlength 0
9002:  not from all dport 53 lookup main suppress_prefixlength 0
9002:  from all iif tun0 goto 9010
9003:  not from all iif lo lookup 2022      ← вот это «вытягивает» всё в VPN
```

Наше правило с `pref 8000` срабатывает **раньше** правила 9003, и для помеченных пакетов отдаёт `table main`, где default — это `default via 10.57.64.1 dev wlp0s20f3`.

### 3.4. Подмена src (masquerade)

Сокет приложения был открыт `connect()`-ом, когда default ещё указывал на tun0. Поэтому src-IP сокета прибит к `172.18.0.1` (адрес tun0). После переоценки маршрута пакет уходит через `wlp0s20f3`, но **с чужим src**, и LAN-роутер его дропает (или роутит обратно в VPN-подсеть).

Решение — masquerade:

```
chain snat_out {
    type nat hook postrouting priority srcnat; policy accept;
    meta mark 0x1 masquerade
}
```

`masquerade` подменяет src на актуальный IP исходящего интерфейса (wlp0s20f3 — динамический DHCP). После этого LAN видит пакет как обычный исходящий с локального адреса.

Параллельно нужно `net.ipv4.conf.all.src_valid_mark=1` — иначе ядро может отказать в выборе src на втором route lookup.

### 3.5. DNS поверх TLS (DoT)

`stubby` слушает на `127.0.0.1:5353`, держит постоянные TLS-соединения с `1.1.1.1` и `1.0.0.1` (и их IPv6) на порту 853. dnsmasq настроен на единственный апстрим `127.0.0.1#5353` (`no-resolv` отключает любые другие, включая навязанные DHCP).

Stubby-соединения **не помечаются** и **не имеют dst в bypass-set** — поэтому они идут по правилу 9003 → table 2022 → tun0. Внутри VPN — зашифрованный TLS-канал к Cloudflare. Провайдер не видит ни DNS-серверов, ни доменов; он видит только зашифрованный VPN-трафик.

---

## 4. Файлы и где они лежат

### В репозитории

| Файл | Назначение |
|---|---|
| `bypass-ru/bypass-ru.nft` | nftables-таблица `inet bypass`: set'ы, `mark_out`, `snat_out` |
| `bypass-ru/bypass-ru.service` | systemd-юнит: грузит nft + добавляет `ip rule fwmark 0x1` |
| `bypass-ru/nm-dns-dnsmasq.conf` | заставляет NetworkManager использовать встроенный dnsmasq |
| `bypass-ru/nm-dnsmasq-bypass-ru.conf` | конфиг dnsmasq: апстрим=stubby, nftset для `.ru`/`.xn--p1ai` |
| `bypass-ru/extra-domains.conf` | пользовательский список не-ru доменов в обход (emias.info и т.п.) |
| `bypass-ru/stubby.yml` | stubby: DoT к 1.1.1.1/1.0.0.1, listen 127.0.0.1:5353 |
| `bypass-ru/sysctl-bypass-ru.conf` | `net.ipv4.conf.all.src_valid_mark=1` |
| `bypass-ru/install.sh` | разворачивает всё, делает бэкап в `/var/backups/bypass-ru-<ts>/` |
| `bypass-ru/uninstall.sh` | полный откат |
| `bypass-ru/dns-monitor/` | опциональный GTK-GUI: real-time просмотр DNS-запросов с отдельной вкладкой ошибок (см. `bypass-ru/dns-monitor/install.sh`) |

### После установки в системе

| Системный путь | Источник |
|---|---|
| `/etc/nftables.d/bypass-ru.nft` | `bypass-ru.nft` |
| `/etc/systemd/system/bypass-ru.service` | `bypass-ru.service` |
| `/etc/NetworkManager/conf.d/00-bypass-ru-dns.conf` | `nm-dns-dnsmasq.conf` |
| `/etc/NetworkManager/dnsmasq.d/bypass-ru.conf` | `nm-dnsmasq-bypass-ru.conf` (политика) |
| `/etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf` | `extra-domains.conf` (пользовательский, не перетирается при повторной установке) |
| `/etc/stubby/stubby.yml` | `stubby.yml` (оригинал в бэкапе) |
| `/etc/sysctl.d/90-bypass-ru.conf` | `sysctl-bypass-ru.conf` |

---

## 5. Установка и удаление

### Установка

```
sudo /home/banach/scripts/network-config/bypass-ru/install.sh
```

Скрипт идемпотентный: при повторных запусках обновит файлы, но **не перетрёт** пользовательский `bypass-ru-extra.conf`. Бэкап исходных конфигов кладётся в `/var/backups/bypass-ru-<timestamp>/`.

### Удаление

```
sudo /home/banach/scripts/network-config/bypass-ru/uninstall.sh
```

Откатывает: останавливает `bypass-ru.service` и `stubby`, удаляет `ip rule`, чистит `nft delete table inet bypass`, удаляет конфиги NM и sysctl, рестартует NetworkManager.

---

## 6. Управление списком доменов

Файл: `/etc/NetworkManager/dnsmasq.d/bypass-ru-extra.conf`

```
nftset=/emias.info/4#inet#bypass#bypass_ru_v4
nftset=/emias.info/6#inet#bypass#bypass_ru_v6
```

Чтобы добавить домен — две строки (v4+v6). Совпадение по суффиксу: запись для `example.com` покрывает и `api.example.com`.

Применить изменения:

```
sudo systemctl restart NetworkManager
sudo conntrack -F          # сбросить старые маршруты в кеше
```

Перезапустить браузер/приложение, чтобы старые TCP-соединения через VPN разорвались — иначе они так и продолжат идти через tun0 до закрытия.

Удалять записи из nft-set'а вручную не нужно: TTL 1ч и без обновления через резолв они выпадут сами.

---

## 7. Диагностика

### Резолв работает?

```
host emias.info 127.0.0.1
host -p 5353 lenta.ru 127.0.0.1   # напрямую через stubby
```

### IP в bypass-set?

```
sudo nft list set inet bypass bypass_ru_v4
```

### Куда реально пойдёт пакет?

```
ip route get <IP>            # без mark — через tun0 (по умолчанию)
ip route get <IP> mark 0x1   # с mark — должно быть dev wlp0s20f3
```

### Проследить путь конкретного пакета

```
sudo nft monitor trace &
ping -c 1 <IP>
```

Должна быть видна цепочка: `mark_out` → `mark set 0x1` → `snat_out` → `masquerade` → `accept`, причём после `mark_out` `oif` меняется с `tun0` на `wlp0s20f3`.

### TLS-соединения stubby

```
sudo ss -tnp 'dport = :853'
```

Все четыре соединения должны иметь `Local Address` из подсети tun0 (`172.18.0.1`/`fd00::1`). Если они с адреса `wlp0s20f3` — DNS-трафик утекает к ISP, надо проверить ip rule.

### Сервисы

```
systemctl status bypass-ru.service stubby.service
systemctl is-active NetworkManager
sudo ss -lnp 'sport = :53 or sport = :5353'
```

### Бэкап исходной конфигурации

После первой установки лежит в `/var/backups/bypass-ru-<timestamp>/`: оригиналы `resolv.conf`, `NetworkManager/conf.d/`, `stubby.yml`.

---

## 8. Известные особенности и оговорки

- **Уже открытые TCP-соединения не «переезжают»**. Если до добавления домена в список приложение уже коннектилось через VPN, это соединение продолжит идти через tun0. Перезапустить приложение или дождаться разрыва.
- **CDN-сайты на иностранных IP остаются под VPN**. `nftset` работает по результату резолва: если `.ru`-сайт хостится на Cloudflare (104.x.x.x), Cloudflare-IP попадёт в bypass-set. Это правильно (роутинг по конкретному IP), но имей в виду — ты влияешь только на тот IP, который тебе вернул резолвер.
- **dnsmasq и stubby — обязательная пара**. Если убрать `dns=dnsmasq` в NM или сломать stubby — сломается резолв.
- **DNSSEC валидация выключена**. Stubby принимает ответы без DNSSEC-проверки, полагаясь на TLS-аутентификацию Cloudflare. Если нужна полная DNSSEC-цепочка — добавить `dnssec_return_status: GETDNS_EXTENSION_TRUE` в `stubby.yml`.
- **NM-dnsmasq vs самостоятельный dnsmasq**: используется именно встроенный в NetworkManager dnsmasq (`dns=dnsmasq` в `00-bypass-ru-dns.conf`), а не пакет `dnsmasq` как отдельный сервис. Это специально — NM сам управляет жизненным циклом и пересоздаёт процесс при смене сети.
- **Совместимость с Docker**: Docker'овская `table ip nat` (управляется iptables-nft) не пересекается с нашей `table inet bypass` — это разные nft-семейства, выполняются независимо. Docker masquerade-правила имеют свои `saddr` фильтры (`172.17.0.0/16`, `172.19.0.0/16`) и не цепляют наш помеченный трафик.
- **Стартовый порядок**: `bypass-ru.service` стартует с `Before=network.target NetworkManager.service`. Это гарантирует, что `ip rule` существует к моменту, когда NM начнёт отдавать DNS-ответы и заполнять bypass-set. Если поменять зависимости — возможна гонка, при которой первые DNS-ответы получают IP в set, но без работающего ip rule.

---

## 9. Когда что-то идёт не так

| Симптом | Куда смотреть |
|---|---|
| `.ru`-сайты грузятся медленно как через VPN | `ip route get <IP> mark 0x1` показывает `dev wlp0s20f3`? IP в `bypass_ru_v4`? mark_out срабатывает (`nft list table inet bypass`)? |
| `.ru`-сайты вообще не грузятся, таймауты | `conntrack -L -d <IP>` — есть запись с `src=172.18.0.1` без masquerade? Тогда `chain snat_out` не сработал, проверь `nft list table inet bypass` на наличие `snat_out` |
| Резолв не работает совсем | `systemctl status stubby.service`, `ss -lnp 'sport = :5353'`, `host emias.info 127.0.0.1` |
| ISP видит DNS-запросы | `sudo ss -tnp 'dport = :853'` — соединения должны быть с `Local 172.18.0.1`, не `10.57.x.x` |
| После reboot правил нет | `systemctl status bypass-ru.service` — должен быть `active (exited)` |

Полный сброс к чистой конфигурации — `uninstall.sh`, потом `install.sh`.
