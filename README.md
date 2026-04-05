# VPN Gateway: обход DPI через цепочку серверов

## Схема

```
┌──────────┐  VLESS/Reality   ┌──────────────┐  WireGuard     ┌───────────────┐
│          │  (порт 443)      │              │  (системный)   │               │
│  Клиент  │ ──────────────── │  RU VPS      │ ────────────── │ Foreign VPS   │ → Интернет
│ sing-box │  DPI видит       │  XRay +      │  Policy        │ WireGuard     │
│  (TUN)   │  обычный HTTPS   │  sys wg0     │  routing       │ + NAT         │
└──────────┘                  └──────────────┘                └───────────────┘
```

**Что видит DPI:** обычное TLS-подключение к google.com на порту 443
**Что видит зарубежный VPN:** подключение с IP российского VPS
**Итоговый IP в интернете:** IP зарубежного VPS

## Ключевые решения (lessons learned)

1. **Системный WireGuard вместо встроенного в XRay** — у XRay built-in WireGuard outbound есть баг с DNS/UDP (`write udp: use of WriteTo with pre-connected connection`). Решение: системный `wg0` + XRay `freedom` outbound с `"interface": "wg0"`.

2. **Policy routing** — нельзя просто `AllowedIPs = 0.0.0.0/0` на системном WG, иначе он перехватит входящие VLESS-подключения. Решение: `Table = off` + отдельная таблица маршрутизации `wgexit`.

3. **WG-ключи через `wg genkey`** — ключи от `xray x25519` несовместимы с WireGuard (другой формат base64, 43 вместо 44 символов). Reality-ключи — через `xray x25519`, WG-ключи — через `wg genkey`.

4. **XRay 26.x** — изменён формат вывода `xray x25519`: `Password (PublicKey)` вместо `Public key`. Парсер использует `awk '{print $NF}'` для совместимости.

5. **Docker на зарубежном VPS** — Docker ставит `FORWARD policy DROP` и перехватывает трафик через `DOCKER-USER`/`DOCKER-FORWARD`. Решение: `iptables -I FORWARD 1` (вставка ПЕРЕД Docker-правилами).

6. **QUIC/UDP** — VLESS с `xtls-rprx-vision` поддерживает только TCP. Браузеры пытаются QUIC (UDP:443). Решение: в конфиге sing-box клиента блокируем QUIC, браузер откатывается на TCP.

7. **Клиент sing-box** — v2RayTun и другие старые клиенты могут быть несовместимы с XRay 26.x Reality. sing-box 1.13+ работает стабильно (но требует актуальный формат конфига — без legacy DNS/inbound fields).

## Требования

- **Российский VPS**: Ubuntu 20.04+ / Debian 11+, root, публичный IPv4
- **Зарубежный VPS**: Ubuntu 20.04+ / Debian 11+, root, публичный IPv4
- **Клиент**: sing-box (Mac/Linux/Windows), FoXray (iOS/macOS), v2rayNG (Android)

## Порядок установки

### Шаг 1: Зарубежный VPS

```bash
chmod +x setup-foreign-vps.sh
sudo ./setup-foreign-vps.sh
```

Запишите: **IP**, **порт**, **WG Public Key**.

### Шаг 2: Российский VPS

```bash
chmod +x setup-ru-vps.sh
sudo ./setup-ru-vps.sh
```

Скрипт спросит данные зарубежного VPS. Выведет **VLESS-ссылку** и **WG Public Key**.

### Шаг 3: Добавьте Peer на зарубежном VPS

```bash
sudo wg set wg0 peer <WG_PUBLIC_KEY_ОТ_RU_VPS> allowed-ips 10.0.0.2/32
sudo wg-quick save wg0
```

### Шаг 4: Клиент (Mac)

Установите sing-box:

```bash
brew install sing-box
```

Создайте конфиг `/usr/local/etc/sing-box/config.json`:

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "cloudflare-doh",
        "server": "1.1.1.1"
      }
    ],
    "final": "cloudflare-doh",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "utun99",
      "mtu": 1500,
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "<IP_РОССИЙСКОГО_VPS>",
      "server_port": 443,
      "uuid": "<UUID>",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "www.google.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "<REALITY_PUBLIC_KEY>",
          "short_id": "<SHORT_ID>"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "default_domain_resolver": {
      "server": "cloudflare-doh"
    },
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      },
      {
        "protocol": "quic",
        "action": "reject"
      }
    ],
    "auto_detect_interface": true,
    "final": "vless-out"
  }
}
```

Замените `<IP_РОССИЙСКОГО_VPS>`, `<UUID>`, `<REALITY_PUBLIC_KEY>`, `<SHORT_ID>` значениями из VLESS-ссылки.

Запуск:

```bash
sudo sing-box run -c /usr/local/etc/sing-box/config.json
```

Проверка (в другом терминале):

```bash
curl -4 ifconfig.me
# Должен показать IP зарубежного VPS
```

### Клиент (iOS)

FoXray или Streisand из App Store — импорт VLESS-ссылки.

### Клиент (Android)

v2rayNG из Google Play — импорт VLESS-ссылки.

## Проверка

```bash
# Клиент — должен показать IP зарубежного VPS
curl -4 ifconfig.me

# Российский VPS — XRay работает
systemctl status xray
journalctl -u xray -f

# Российский VPS — WireGuard работает
wg show wg0
ping -c 2 -I wg0 1.1.1.1

# Зарубежный VPS — WireGuard видит подключение
sudo wg show wg0
# Должен быть "latest handshake" и растущий transfer
```

## Управление

```bash
# Российский VPS
sudo systemctl restart xray
sudo systemctl restart wg-quick@wg0
journalctl -u xray -n 50

# Зарубежный VPS
sudo systemctl restart wg-quick@wg0
sudo wg show wg0
```

## Добавление клиентов

На российском VPS:

```bash
# Новый UUID
xray uuid

# Добавить в /usr/local/etc/xray/config.json → clients:
# { "id": "<новый_UUID>", "flow": "xtls-rprx-vision" }

sudo systemctl restart xray
```

VLESS-ссылка для нового клиента будет такой же, но с другим UUID.

## Troubleshooting

| Проблема | Решение |
|----------|---------|
| XRay не стартует | `journalctl -u xray -n 50` — обычно ошибка в JSON |
| `handshake did not complete` | Несовпадение ключей Reality — проверьте pbk в ссылке и privateKey в конфиге |
| `failed to lookup DNS` | Используете XRay built-in WG? Переключитесь на системный wg0 |
| `UDP is not supported` | Нормально — QUIC блокируется в клиенте, браузер откатится на TCP |
| Нет handshake на WG | Порт 51820/udp закрыт на зарубежном VPS, или Peer не добавлен |
| curl работает, браузер нет | Проверьте что QUIC заблокирован в конфиге sing-box |
| Docker мешает на зарубежном | `iptables -I FORWARD 1 -i wg0 -j ACCEPT` |
| `Key is not the correct length` | WG-ключ сгенерирован через `xray x25519` — нужен `wg genkey` |
| Медленная скорость | Попробуйте другой dest для Reality (microsoft.com, apple.com) |

## Безопасность

- Данные в `/root/vpn-credentials.txt` (chmod 600)
- Не передавайте Private Key по открытым каналам
- Обновляйте XRay: `bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install`
- Обновляйте sing-box: `brew upgrade sing-box`
