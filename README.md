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

**Mac / Ubuntu / Debian:**
```bash
chmod +x clients/setup-desktop.sh
sudo ./clients/setup-desktop.sh
```

**Keenetic** (с установленным Entware/OPKG):
```bash
scp clients/setup-keenetic.sh root@<router-ip>:/opt/
ssh root@<router-ip> '/opt/setup-keenetic.sh'
```
Управление: `/opt/etc/init.d/S99singbox start|stop|restart`

**OpenWrt** (19.07+ iptables, 22.03+ nftables):
```bash
scp clients/setup-openwrt.sh root@<router-ip>:/tmp/
ssh root@<router-ip> '/tmp/setup-openwrt.sh'
```
Управление: `/etc/init.d/sing-box start|stop|restart`

**iOS:** FoXray / Streisand — импорт VLESS-ссылки.

**Android:** v2rayNG — импорт VLESS-ссылки.

Каждый скрипт спросит данные из VLESS-ссылки и настроит всё автоматически.

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

## Безопасность

- Данные подключения хранятся в `/root/vpn-credentials.txt` (chmod 600)
- Не передавайте Private Key по открытым каналам
- Обновляйте XRay: `bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install`
- Обновляйте sing-box: `brew upgrade sing-box` (Mac) / скачайте новую версию с [GitHub](https://github.com/SagerNet/sing-box/releases)
