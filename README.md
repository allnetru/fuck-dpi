# VPN Gateway: обход DPI через цепочку серверов

Скрипты автоматизируют полную настройку.

```
Клиент ──VLESS/Reality──▶ RU VPS ──WireGuard──▶ Foreign VPS ──▶ Интернет
           (порт 443)       XRay                  WG + NAT
```

DPI видит обычный TLS к google.com. Итоговый IP — зарубежного VPS.

## Как это работает

```
┌──────────┐  VLESS/Reality   ┌──────────────┐  WireGuard     ┌───────────────┐
│          │  (порт 443)      │              │  (системный)   │               │
│  Клиент  │ ──────────────── │  RU VPS      │ ────────────── │ Foreign VPS   │ → Интернет
│ sing-box │  DPI видит       │  XRay +      │  Policy        │ WireGuard     │
│  (TUN)   │  обычный HTTPS   │  sys wg0     │  routing       │ + NAT         │
└──────────┘                  └──────────────┘                └───────────────┘
```

**Что видит DPI:** обычное TLS-подключение к google.com на порту 443
**Что видит зарубежный VPS:** подключение с IP российского VPS
**Итоговый IP в интернете:** IP зарубежного VPS

1. Клиент подключается к RU VPS по **VLESS/Reality** на порт 443 — для DPI это выглядит как обычный HTTPS к google.com
2. RU VPS принимает трафик через **XRay**, расшифровывает и отправляет через **системный WireGuard** (wg0) на зарубежный VPS
3. Foreign VPS делает **NAT** и выпускает трафик в интернет со своим IP

### Ключевые решения

- **Системный WireGuard вместо встроенного в XRay** — у XRay built-in WG outbound баг с DNS/UDP (`write udp: use of WriteTo with pre-connected connection`). Решение: системный `wg0` + XRay `freedom` outbound с `"interface": "wg0"`
- **Policy routing** — нельзя `AllowedIPs = 0.0.0.0/0` на системном WG, иначе он перехватит входящие VLESS-подключения. Решение: `Table = off` + отдельная таблица маршрутизации `wgexit`
- **WG-ключи через `wg genkey`** — ключи от `xray x25519` несовместимы с WireGuard (другой формат base64, 43 вместо 44 символов). Reality-ключи — через `xray x25519`, WG-ключи — через `wg genkey`
- **QUIC блокируется на клиенте** — VLESS+xtls-rprx-vision работает только по TCP. Клиент блокирует QUIC, браузер откатывается на TCP
- **Docker на зарубежном VPS** — Docker ставит `FORWARD DROP` и перехватывает трафик. Решение: `iptables -I FORWARD 1` (вставка ПЕРЕД Docker-правилами)
- **XRay 26.x** — изменён формат вывода `xray x25519`: `Password (PublicKey)` вместо `Public key`. Парсер использует `awk '{print $NF}'` для совместимости
- **Клиент sing-box 1.13+** — старые клиенты (v2RayTun и т.д.) могут быть несовместимы с XRay 26.x Reality. sing-box 1.13+ работает стабильно (актуальный формат конфига, без legacy полей)
- **Роутеры (Keenetic/OpenWrt)** — вместо TUN используется tproxy + iptables/nftables для прозрачного проксирования всех устройств в LAN

## Структура

```
servers/
  setup-foreign-vps.sh    зарубежный VPS — WireGuard exit node
  setup-ru-vps.sh         российский VPS — XRay VLESS/Reality + WireGuard
  setup-obfuscation.sh    обфускация межсерверного WG в TLS/WSS (wstunnel + Caddy)
  find-reality-domain.sh  поиск домена для маскировки в том же AS
clients/
  setup-desktop.sh        Mac / Ubuntu / Debian — sing-box с TUN
  setup-keenetic.sh       Keenetic — sing-box через Entware (tproxy)
  setup-openwrt.sh        OpenWrt — sing-box с nftables/iptables (tproxy)
```

## Требования

- **Российский VPS**: Ubuntu 20.04+ / Debian 11+, root, публичный IPv4
- **Зарубежный VPS**: Ubuntu 20.04+ / Debian 11+, root, публичный IPv4
- **Клиент**: sing-box (Mac/Linux/Windows), FoXray (iOS/macOS), v2rayNG (Android), Keenetic (Entware), OpenWrt

## Установка

### 1. Зарубежный VPS

```bash
chmod +x servers/setup-foreign-vps.sh
sudo ./servers/setup-foreign-vps.sh
```

Запишите **IP**, **порт**, **WG Public Key**.

### 2. Российский VPS

Сначала найдите домен для маскировки Reality в том же AS что и ваш VPS:

```bash
chmod +x servers/find-reality-domain.sh
./servers/find-reality-domain.sh
```

Скрипт просканирует IP-диапазоны вашего хостера и найдёт сайты с TLS — идеальные для Reality (DPI не заметит несовпадения IP↔SNI). Если не нашёл — используйте `www.google.com` как fallback.

Затем запустите установку:

```bash
chmod +x servers/setup-ru-vps.sh
sudo ./servers/setup-ru-vps.sh
```

Введите данные зарубежного VPS и найденный домен. Скрипт выдаст **VLESS-ссылку** и **WG Public Key**.

### 3. Связать VPS

На зарубежном VPS добавьте peer:

```bash
sudo wg set wg0 peer <WG_PUBLIC_KEY_RU_VPS> allowed-ips 10.0.0.2/32
sudo wg-quick save wg0
```

### 4. Клиент

Скопируйте файл параметров с RU VPS:

```bash
scp root@<ru-vps-ip>:/root/.vpn-params /tmp/
```

**Mac / Ubuntu / Debian:**
```bash
chmod +x clients/setup-desktop.sh
sudo ./clients/setup-desktop.sh --from /tmp/.vpn-params
```

**Keenetic** (с установленным Entware/OPKG):
```bash
scp /tmp/.vpn-params root@<router-ip>:/opt/
scp clients/setup-keenetic.sh root@<router-ip>:/opt/
ssh root@<router-ip> '/opt/setup-keenetic.sh --from /opt/.vpn-params'
```
Управление: `/opt/etc/init.d/S99singbox start|stop|restart`

**OpenWrt** (19.07+ iptables, 22.03+ nftables):
```bash
scp /tmp/.vpn-params root@<router-ip>:/tmp/
scp clients/setup-openwrt.sh root@<router-ip>:/tmp/
ssh root@<router-ip> '/tmp/setup-openwrt.sh --from /tmp/.vpn-params'
```
Управление: `/etc/init.d/sing-box start|stop|restart`

**iOS:** FoXray / Streisand — импорт VLESS-ссылки.

**Android:** v2rayNG — импорт VLESS-ссылки.

Все клиентские скрипты также работают интерактивно (без `--from`) — спросят данные из VLESS-ссылки.

## Проверка

```bash
curl -4 ifconfig.me    # должен показать IP зарубежного VPS
```

## Маршрутизация

- `.ru` / `.рф` / `.su` и локальные сети — напрямую
- Всё остальное — через VPN
- QUIC блокируется, браузер откатывается на TCP

## Добавление клиентов

На российском VPS:

```bash
# Новый UUID
xray uuid

# Добавить в /usr/local/etc/xray/config.json → clients:
# { "id": "<новый_UUID>", "flow": "xtls-rprx-vision" }

sudo systemctl restart xray
```

VLESS-ссылка такая же, но с новым UUID.

## Диагностика

### Проверка что всё работает

```bash
# На клиенте — должен показать IP зарубежного VPS
curl -4 ifconfig.me

# RU VPS — XRay работает
systemctl status xray
journalctl -u xray -f

# RU VPS — WireGuard туннель поднят
wg show wg0
ping -c 2 -I wg0 1.1.1.1

# Foreign VPS — видит подключение (latest handshake + растущий transfer)
sudo wg show wg0
```

### Управление сервисами

```bash
# RU VPS
sudo systemctl restart xray
sudo systemctl restart wg-quick@wg0
journalctl -u xray -n 50

# Foreign VPS
sudo systemctl restart wg-quick@wg0
sudo wg show wg0

# Desktop (Mac)
sudo launchctl stop com.sing-box
sudo launchctl start com.sing-box

# Desktop (Linux)
sudo systemctl restart sing-box

# Keenetic
/opt/etc/init.d/S99singbox restart

# OpenWrt
/etc/init.d/sing-box restart
```

### Troubleshooting

| Проблема | Что делать |
|----------|------------|
| XRay не стартует | `journalctl -u xray -n 50` — обычно ошибка в JSON |
| `handshake did not complete` | Проверьте Reality-ключи (pbk в ссылке vs privateKey в конфиге) |
| `failed to lookup DNS` | Используете XRay built-in WG? Переключитесь на системный wg0 |
| `UDP is not supported` | Нормально — QUIC блокируется в клиенте, браузер откатится на TCP |
| Нет handshake на WG | Порт 51820/udp закрыт или Peer не добавлен |
| curl работает, браузер нет | QUIC не заблокирован в конфиге клиента |
| Docker мешает на зарубежном VPS | `iptables -I FORWARD 1 -i wg0 -j ACCEPT` |
| `Key is not the correct length` | WG-ключ сгенерирован через `xray x25519` — нужен `wg genkey` |
| Медленная скорость | Попробуйте другой dest для Reality (microsoft.com, apple.com) |

## Обфускация межсерверного хопа (WG-over-WSS)

По умолчанию RU↔Foreign идёт по **голому WireGuard** (UDP/51820). DPI/ТСПУ умеет распознавать WireGuard по сигнатуре рукопожатия (фиксированные размеры пакетов 148/92 байта) и **точечно блокировать exit-IP** зарубежного VPS. Симптом: туннель работал месяцами и внезапно замолчал в обратную сторону — на RU перестают приходить пакеты от Foreign (`latest handshake` не обновляется, `wg show` показывает рост только `sent`).

Решение — завернуть WG-трафик между серверами в **TLS/WebSocket** через [`wstunnel`](https://github.com/erebe/wstunnel), спрятав его за уже стоящий на Foreign VPS **Caddy** с реальным доменом. На проводе RU→Foreign выглядит как обычный визит на сайт по HTTPS — WG-сигнатуры нет, IP не палится.

```
RU: WG (127.0.0.1:51821) ──▶ wstunnel client ──WSS/TLS :443──▶ Caddy (домен) ──▶ wstunnel server ──▶ WG (127.0.0.1:51820) :Foreign
                                            обычный HTTPS для DPI
```

### Требования
- На Foreign VPS: Caddy с валидным доменом и Let's Encrypt-сертом (`<DOMAIN> { reverse_proxy ... }`).
- WG на Foreign слушает `0.0.0.0:51820` (как в `setup-foreign-vps.sh`).
- `wstunnel` v10+ на обоих серверах (один Go-бинарь):
  ```bash
  V=10.6.2
  curl -sL https://github.com/erebe/wstunnel/releases/download/v${V}/wstunnel_${V}_linux_amd64.tar.gz | tar xz
  install -m755 wstunnel /usr/local/bin/wstunnel
  ```

### Установка (скрипт)

Проще всего — скриптом `setup-obfuscation.sh` (сам ставит wstunnel и Caddy, генерит секрет, правит конфиги):

```bash
# 1) На зарубежном VPS (нужен домен с A-записью на этот VPS):
sudo ./servers/setup-obfuscation.sh foreign     # выдаст домен + секретный путь

# 2) На российском VPS (введите домен и секрет с шага 1):
sudo ./servers/setup-obfuscation.sh ru
#    если основной IP Foreign заблокирован — укажите резервный IP,
#    домен зарезолвится в него через /etc/hosts

# Откат на прямой WireGuard (на любом из серверов):
sudo ./servers/setup-obfuscation.sh disable
```

Ниже — что именно делает скрипт (для ручной установки / понимания).

### Вручную: Foreign VPS (сервер)

```bash
SECRET=$(openssl rand -hex 12)        # секретный путь = пароль для клиентов
echo "$SECRET" > /root/.wstunnel-secret

# 1) wstunnel server (локально, TLS терминирует Caddy)
cat > /etc/systemd/system/wstunnel-server.service <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:8080 --restrict-to 127.0.0.1:51820 --restrict-http-upgrade-path-prefix ${SECRET}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now wstunnel-server

# 2) Caddy: секретный путь -> wstunnel, остальное -> ваш app
#   <DOMAIN> {
#       @wstun path /<SECRET> /<SECRET>/*
#       reverse_proxy @wstun 127.0.0.1:8080
#       reverse_proxy 127.0.0.1:8000        # ваше приложение
#   }
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### Вручную: RU VPS (клиент)

```bash
SECRET=<тот_же_SECRET_с_Foreign>

# домен -> IP Foreign VPS (если публичный DNS указывает на заблокированный/другой IP)
echo "<FOREIGN_IP> <DOMAIN>" >> /etc/hosts

cat > /etc/systemd/system/wstunnel-client.service <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/wstunnel client -L udp://127.0.0.1:51821:127.0.0.1:51820?timeout_sec=0 --http-upgrade-path-prefix ${SECRET} wss://<DOMAIN>:443
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now wstunnel-client

# WG endpoint -> локальный вход wstunnel
sed -i 's#^Endpoint = .*#Endpoint = 127.0.0.1:51821#' /etc/wireguard/wg0.conf
systemctl restart wg-quick@wg0

# WG должен стартовать после wstunnel
mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
printf '[Unit]\nAfter=wstunnel-client.service\nWants=wstunnel-client.service\n' \
  > /etc/systemd/system/wg-quick@wg0.service.d/10-after-wstunnel.conf
systemctl daemon-reload
```

### Проверка обфускации

```bash
# RU: handshake свежий + трафик ходит
wg show wg0                              # endpoint = 127.0.0.1:51821, latest handshake < 30s
ping -c3 -I wg0 1.1.1.1                  # 0% loss
curl -4 --interface wg0 ifconfig.me     # IP зарубежного VPS

# Foreign: на проводе от RU — только TLS/443, НЕ udp/51820
tcpdump -ni any host <RU_IP> and tcp port 443 -c 5     # видно TLS
tcpdump -ni any host <RU_IP> and udp port 51820 -c 3   # должно быть пусто
```

### Клиентов это НЕ касается

Плечо **клиент → RU** (VLESS/Reality :443) не меняется. Конфиги sing-box / v2rayNG / роутеров остаются прежними — обфускация только между серверами.

### Диагностика блокировки exit-IP

Если Foreign VPS точечно заблокировали (не помогает даже смена WG-порта — блок по сигнатуре/IP, а не по порту):

```bash
# С RU: доходит ли форвард до Foreign? (на Foreign — tcpdump)
# С Foreign: EU -> наш RU vs EU -> Yandex/VK (если Яндекс доступен, а наш RU нет — режут пару IP)
```

Быстрое лечение — **новый IP на Foreign VPS** (DO Reserved IP из другого диапазона): DO NAT-ит входящие на reserved IP так, что ответы уходят с него же, поэтому достаточно перенаправить `Endpoint` на новый IP. Долгое лечение — обфускация выше, чтобы IP не палили по WG-сигнатуре.

## Безопасность

- Данные подключения хранятся в `/root/vpn-credentials.txt` (chmod 600)
- Не передавайте Private Key по открытым каналам
- Секретный путь wstunnel (`/root/.wstunnel-secret`) — это пароль: не коммитьте его, при утечке перегенерируйте на обоих серверах
- Обновляйте XRay: `bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install`
- Обновляйте sing-box: `brew upgrade sing-box` (Mac) / скачайте новую версию с [GitHub](https://github.com/SagerNet/sing-box/releases)
