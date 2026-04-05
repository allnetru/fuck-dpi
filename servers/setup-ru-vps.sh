#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# setup-ru-vps.sh — XRay VLESS+Reality на российском VPS
#
# Что делает:
#   1. Ставит XRay и wireguard-tools
#   2. Генерирует ключи (Reality через xray x25519, WG через wg genkey)
#   3. Поднимает СИСТЕМНЫЙ WireGuard с policy routing
#   4. Настраивает XRay: VLESS+Reality inbound, freedom outbound через wg0
#   5. Генерирует готовый конфиг sing-box для клиента
#   6. Выводит VLESS-ссылку и инструкцию
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

parse_x25519_private() { echo "$1" | grep -i "private" | awk '{print $NF}'; }
parse_x25519_public()  { echo "$1" | grep -iE "(public|password)" | awk '{print $NF}'; }

[[ $EUID -ne 0 ]] && err "Запустите от root: sudo $0"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Установка XRay VLESS+Reality (Российский VPS)        ║"
echo "║                                                            ║"
echo "║  Клиент → [VLESS/Reality:443] → [sys WG] → Foreign VPS    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --- Сбор данных ---
echo -e "${CYAN}=== Данные зарубежного VPS ===${NC}"
echo ""

read -rp "IP зарубежного VPS: " FOREIGN_IP
[[ -z "$FOREIGN_IP" ]] && err "IP не может быть пустым"

read -rp "Порт WireGuard [51820]: " FOREIGN_PORT
FOREIGN_PORT=${FOREIGN_PORT:-51820}

read -rp "Public Key WireGuard зарубежного VPS: " FOREIGN_WG_PUBKEY
[[ -z "$FOREIGN_WG_PUBKEY" ]] && err "Public Key не может быть пустым"

read -rp "Ваш IP в WG-сети [10.0.0.2]: " WG_CLIENT_IP
WG_CLIENT_IP=${WG_CLIENT_IP:-10.0.0.2}

echo -e "${YELLOW}Совет: запустите ./find-reality-domain.sh чтобы найти домен в вашем AS${NC}"
read -rp "Сайт для маскировки Reality [www.google.com]: " REALITY_DEST
REALITY_DEST=${REALITY_DEST:-www.google.com}

WG_DNS="1.1.1.1"

# =====================================================================
# 1. УСТАНОВКА ПАКЕТОВ
# =====================================================================
log "Устанавливаю пакеты..."

if ! command -v xray &>/dev/null; then
    log "Устанавливаю XRay..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    log "XRay уже установлен: $(xray version 2>/dev/null | head -1)"
fi

if ! command -v wg &>/dev/null; then
    log "Устанавливаю wireguard-tools..."
    if [[ -f /etc/debian_version ]]; then
        apt update -qq && apt install -y -qq wireguard wireguard-tools
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y epel-release && yum install -y wireguard-tools
    else
        apt update -qq && apt install -y -qq wireguard wireguard-tools
    fi
else
    log "wireguard-tools уже установлены"
fi

XRAY_BIN=$(command -v xray)

# =====================================================================
# 2. ГЕНЕРАЦИЯ КЛЮЧЕЙ
# =====================================================================
log "Генерирую ключи..."

UUID=$($XRAY_BIN uuid)
log "UUID: $UUID"

REALITY_OUTPUT=$($XRAY_BIN x25519)
REALITY_PRIVATE_KEY=$(parse_x25519_private "$REALITY_OUTPUT")
REALITY_PUBLIC_KEY=$(parse_x25519_public "$REALITY_OUTPUT")
[[ -z "$REALITY_PRIVATE_KEY" ]] && err "Не удалось получить Reality Private Key.\nВывод: $REALITY_OUTPUT"
[[ -z "$REALITY_PUBLIC_KEY" ]] && err "Не удалось получить Reality Public Key.\nВывод: $REALITY_OUTPUT"
log "Reality Private Key: $REALITY_PRIVATE_KEY"
log "Reality Public Key:  $REALITY_PUBLIC_KEY"

SHORT_ID=$(openssl rand -hex 4)
log "Short ID: $SHORT_ID"

WG_PRIVATE=$(wg genkey)
WG_PUBLIC=$(echo "$WG_PRIVATE" | wg pubkey)
[[ ${#WG_PUBLIC} -ne 44 ]] && warn "WG Public Key нестандартная длина: ${#WG_PUBLIC}"
log "WG Private Key: ${WG_PRIVATE:0:10}..."
log "WG Public Key:  $WG_PUBLIC"

SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "UNKNOWN")
log "IP этого сервера: $SERVER_IP"

# =====================================================================
# 3. СИСТЕМНЫЙ WIREGUARD С POLICY ROUTING
# =====================================================================
log "Настраиваю системный WireGuard..."

systemctl stop xray 2>/dev/null || true
systemctl stop wg-quick@wg0 2>/dev/null || true
ip link delete wg0 2>/dev/null || true
ip rule del from "$WG_CLIENT_IP" table wgexit 2>/dev/null || true
ip route del default table wgexit 2>/dev/null || true

if ! grep -q "^100 wgexit" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "100 wgexit" >> /etc/iproute2/rt_tables
fi

mkdir -p /etc/wireguard

cat > /etc/wireguard/wg0.conf << WEOF
[Interface]
PrivateKey = ${WG_PRIVATE}
Address = ${WG_CLIENT_IP}/32
MTU = 1280
Table = off

PostUp = ip route add default dev wg0 table wgexit
PostUp = ip rule add from ${WG_CLIENT_IP} table wgexit priority 100
PostUp = sysctl -w net.ipv4.ip_forward=1

PostDown = ip route del default dev wg0 table wgexit 2>/dev/null || true
PostDown = ip rule del from ${WG_CLIENT_IP} table wgexit 2>/dev/null || true

[Peer]
PublicKey = ${FOREIGN_WG_PUBKEY}
Endpoint = ${FOREIGN_IP}:${FOREIGN_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WEOF

chmod 600 /etc/wireguard/wg0.conf

wg-quick up wg0
systemctl enable wg-quick@wg0

sleep 2

if ip link show wg0 &>/dev/null; then
    log "WireGuard wg0 поднят"
else
    err "Не удалось поднять wg0"
fi

log "Проверяю связь через WireGuard..."
if ping -c 2 -W 3 -I wg0 "$WG_DNS" &>/dev/null; then
    log "Ping через WG проходит — туннель работает!"
else
    warn "Ping через WG не прошёл — проверьте что Peer добавлен на зарубежном VPS"
fi

# =====================================================================
# 4. КОНФИГ XRAY
# =====================================================================
log "Создаю конфиг XRay..."

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${REALITY_DEST}:443",
          "serverNames": ["${REALITY_DEST}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "wg-exit",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "streamSettings": {
        "sockopt": {
          "interface": "wg0"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "dns": {
    "servers": [
      "${WG_DNS}",
      "8.8.8.8"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-reality-in"],
        "outboundTag": "wg-exit"
      }
    ]
  }
}
XEOF

log "Проверяю конфиг XRay..."
if xray run -test -config /usr/local/etc/xray/config.json 2>&1 | grep -q "Configuration OK"; then
    log "Конфиг валидный"
else
    warn "Результат проверки:"
    xray run -test -config /usr/local/etc/xray/config.json
fi

# =====================================================================
# 5. ФАЙРВОЛ И ЗАПУСК
# =====================================================================
log "Настраиваю файрвол..."
if command -v ufw &>/dev/null; then
    ufw allow 443/tcp 2>/dev/null || true
    log "UFW: порт 443/tcp открыт"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld: порт 443/tcp открыт"
fi

log "Запускаю XRay..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 3

if systemctl is-active --quiet xray; then
    log "XRay запущен и работает!"
else
    warn "XRay не стартовал. Логи:"
    journalctl -u xray -n 15 --no-pager
    echo ""
    err "XRay не запустился."
fi

# =====================================================================
# 6. ГЕНЕРАЦИЯ КОНФИГА SING-BOX ДЛЯ КЛИЕНТА
# =====================================================================
log "Генерирую конфиг sing-box для клиента..."

SINGBOX_CONFIG="/root/sing-box-client-config.json"

cat > "$SINGBOX_CONFIG" << SEOF
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
      "server": "${SERVER_IP}",
      "server_port": 443,
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DEST}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
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
        "domain_suffix": [".ru", ".рф", ".su"],
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
SEOF

chmod 644 "$SINGBOX_CONFIG"
log "Конфиг sing-box сохранён в ${SINGBOX_CONFIG}"

# =====================================================================
# 7. ВЫВОД РЕЗУЛЬТАТОВ
# =====================================================================

VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#RU-VPS-Reality"

CREDENTIALS_FILE="/root/vpn-credentials.txt"
cat > "$CREDENTIALS_FILE" << CEOF
===============================================================
  ДАННЫЕ ПОДКЛЮЧЕНИЯ — Российский VPS
  Сгенерировано: $(date)
===============================================================

--- Для клиента (sing-box / FoXray / v2rayN / Streisand) ---

VLESS-ссылка:
${VLESS_LINK}

--- Для зарубежного VPS ---

WireGuard Public Key (добавить как Peer):
${WG_PUBLIC}

Команда для зарубежного VPS:
sudo wg set wg0 peer ${WG_PUBLIC} allowed-ips ${WG_CLIENT_IP}/32
sudo wg-quick save wg0

--- Параметры ---

UUID:               ${UUID}
Reality Public Key:  ${REALITY_PUBLIC_KEY}
Reality Private Key: ${REALITY_PRIVATE_KEY}
Short ID:           ${SHORT_ID}
Маскировка:         ${REALITY_DEST}
Server IP:          ${SERVER_IP}
WG Client IP:       ${WG_CLIENT_IP}
WG Private Key:     ${WG_PRIVATE}
WG Public Key:      ${WG_PUBLIC}
Foreign Endpoint:   ${FOREIGN_IP}:${FOREIGN_PORT}

===============================================================
CEOF

chmod 600 "$CREDENTIALS_FILE"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    УСТАНОВКА ЗАВЕРШЕНА                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}VLESS-ссылка для клиента:${NC}"
echo -e "${YELLOW}${VLESS_LINK}${NC}"
echo ""
echo -e "${GREEN}WireGuard Public Key (добавить на зарубежный VPS):${NC}"
echo -e "${YELLOW}${WG_PUBLIC}${NC}"
echo ""
echo -e "${GREEN}Команда для зарубежного VPS:${NC}"
echo -e "${YELLOW}sudo wg set wg0 peer ${WG_PUBLIC} allowed-ips ${WG_CLIENT_IP}/32${NC}"
echo -e "${YELLOW}sudo wg-quick save wg0${NC}"
echo ""
echo -e "${GREEN}Все данные сохранены в:${NC} ${CREDENTIALS_FILE}"
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              КОНФИГ SING-BOX ДЛЯ КЛИЕНТА                   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Готовый конфиг:${NC} ${SINGBOX_CONFIG}"
echo ""
echo -e "Скопируйте его на клиент (Mac/Linux/Windows) и запустите:"
echo ""
echo -e "${CYAN}  Установка sing-box:${NC}"
echo -e "    Mac:     ${YELLOW}brew install sing-box${NC}"
echo -e "    Ubuntu:  ${YELLOW}sudo apt install sing-box${NC}"
echo -e "    Windows: ${YELLOW}скачайте с https://github.com/SagerNet/sing-box/releases${NC}"
echo ""
echo -e "${CYAN}  Скопировать конфиг с сервера на клиент:${NC}"
echo -e "    ${YELLOW}scp root@${SERVER_IP}:/root/sing-box-client-config.json ~/Downloads/${NC}"
echo ""
echo -e "${CYAN}  Запуск:${NC}"
echo -e "    ${YELLOW}sudo sing-box run -c ~/Downloads/sing-box-client-config.json${NC}"
echo ""
echo -e "${CYAN}  Проверка (в другом терминале):${NC}"
echo -e "    ${YELLOW}curl -4 ifconfig.me${NC}"
echo ""
echo -e "  Домены .ru / .рф / .su идут напрямую без VPN."
echo -e "  Также работает VLESS-ссылка в FoXray (iOS/macOS), v2rayNG (Android),"
echo -e "  v2RayTun (macOS) и других клиентах."
echo ""
