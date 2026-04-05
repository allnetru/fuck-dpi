#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# setup-foreign-vps.sh — WireGuard Exit Node на зарубежном VPS
#
# Что делает:
#   1. Ставит WireGuard
#   2. Генерирует серверные ключи
#   3. Настраивает NAT и IP-форвардинг (совместимо с Docker)
#   4. Добавляет российский VPS как Peer (если ключ известен)
#   5. Выводит данные для настройки российского VPS
#
# Запустите ПЕРВЫМ, затем используйте выведенные данные при запуске
# setup-ru-vps.sh на российском сервере.
#
# Использование:
#   chmod +x setup-foreign-vps.sh
#   sudo ./setup-foreign-vps.sh
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Запустите от root: sudo $0"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Установка WireGuard Exit Node (Зарубежный VPS)       ║"
echo "║                                                            ║"
echo "║  Трафик: RU VPS → [WireGuard:51820] → NAT → Интернет      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --- Параметры ---
WG_SERVER_IP="10.0.0.1"
WG_CLIENT_IP="10.0.0.2"

read -rp "WireGuard подсеть сервера [${WG_SERVER_IP}]: " INPUT_SERVER_IP
WG_SERVER_IP=${INPUT_SERVER_IP:-$WG_SERVER_IP}

read -rp "WireGuard IP клиента (RU VPS) [${WG_CLIENT_IP}]: " INPUT_CLIENT_IP
WG_CLIENT_IP=${INPUT_CLIENT_IP:-$WG_CLIENT_IP}

read -rp "WireGuard порт [51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}

echo ""
echo -e "${CYAN}Есть ли у вас уже Public Key российского VPS?${NC}"
echo "  Если сначала запускаете этот скрипт — введите 'n'."
echo "  Public Key можно будет добавить позже."
read -rp "Ввести Public Key сейчас? [y/n]: " HAS_PUBKEY

RU_VPS_PUBKEY=""
if [[ "$HAS_PUBKEY" =~ ^[Yy] ]]; then
    read -rp "Public Key российского VPS: " RU_VPS_PUBKEY
    [[ -z "$RU_VPS_PUBKEY" ]] && err "Public Key не может быть пустым"
fi

# --- Установка WireGuard ---
log "Устанавливаю WireGuard..."

if [[ -f /etc/debian_version ]]; then
    apt update -qq
    apt install -y -qq wireguard wireguard-tools iptables curl
elif [[ -f /etc/redhat-release ]]; then
    yum install -y epel-release
    yum install -y wireguard-tools iptables curl
else
    apt update -qq && apt install -y -qq wireguard wireguard-tools iptables curl
fi

log "WireGuard установлен"

# --- Генерация ключей ---
log "Генерирую серверные ключи..."

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIVATE=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

log "Server Public Key: $SERVER_PUBLIC"

# --- Определяем сетевой интерфейс ---
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && err "Не удалось определить сетевой интерфейс"
log "Основной интерфейс: $DEFAULT_IFACE"

# --- Определяем IP сервера ---
SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 api.ipify.org || echo "UNKNOWN")
log "IP этого сервера: $SERVER_IP"

# --- Создаём конфиг WireGuard ---
log "Создаю конфиг WireGuard..."

cat > /etc/wireguard/wg0.conf << WEOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE}

# IP forwarding и NAT
# Правила вставляются ПЕРЕД Docker-правилами для совместимости
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT
PostUp = iptables -I FORWARD 1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o ${DEFAULT_IFACE} -j MASQUERADE 2>/dev/null || true

WEOF

# Добавляем Peer если ключ известен
if [[ -n "$RU_VPS_PUBKEY" ]]; then
    cat >> /etc/wireguard/wg0.conf << PEOF
[Peer]
# Российский VPS
PublicKey = ${RU_VPS_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}/32
PEOF
    log "Peer (российский VPS) добавлен"
else
    warn "Peer не добавлен — добавьте позже командой:"
    echo "    sudo wg set wg0 peer <PUBLIC_KEY> allowed-ips ${WG_CLIENT_IP}/32"
    echo "    sudo wg-quick save wg0"
fi

chmod 600 /etc/wireguard/wg0.conf

# --- IP forwarding (постоянно) ---
log "Включаю IP forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- Файрвол ---
log "Настраиваю файрвол..."
if command -v ufw &>/dev/null; then
    ufw allow "${WG_PORT}/udp" 2>/dev/null || true
    ufw allow OpenSSH 2>/dev/null || true
    if grep -q "DEFAULT_FORWARD_POLICY=\"DROP\"" /etc/default/ufw 2>/dev/null; then
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        ufw reload 2>/dev/null || true
    fi
    log "UFW: порт ${WG_PORT}/udp открыт, форвардинг разрешён"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${WG_PORT}/udp" 2>/dev/null || true
    firewall-cmd --permanent --add-masquerade 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld: порт ${WG_PORT}/udp открыт"
else
    warn "Файрвол не найден — убедитесь что порт ${WG_PORT}/udp открыт"
fi

# --- Запуск WireGuard ---
log "Запускаю WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 2

if systemctl is-active --quiet wg-quick@wg0; then
    log "WireGuard запущен и работает!"
else
    err "WireGuard не запустился. Проверьте: journalctl -u wg-quick@wg0 -n 50"
fi

# --- Сохраняем данные ---
CREDENTIALS_FILE="/root/vpn-credentials.txt"
cat > "$CREDENTIALS_FILE" << CEOF
===============================================================
  ДАННЫЕ ПОДКЛЮЧЕНИЯ — Зарубежный VPS (Exit Node)
  Сгенерировано: $(date)
===============================================================

--- Данные для setup-ru-vps.sh ---

IP зарубежного VPS:       ${SERVER_IP}
WireGuard порт:           ${WG_PORT}
WireGuard Public Key:     ${SERVER_PUBLIC}
IP клиента в WG-сети:     ${WG_CLIENT_IP}

--- Команда для добавления Peer позже ---

sudo wg set wg0 peer <RU_VPS_PUBLIC_KEY> allowed-ips ${WG_CLIENT_IP}/32
sudo wg-quick save wg0

===============================================================
CEOF

chmod 600 "$CREDENTIALS_FILE"

# --- Итог ---
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    УСТАНОВКА ЗАВЕРШЕНА                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Данные для настройки российского VPS:${NC}"
echo ""
echo -e "  IP зарубежного VPS:     ${YELLOW}${SERVER_IP}${NC}"
echo -e "  WireGuard порт:         ${YELLOW}${WG_PORT}${NC}"
echo -e "  WireGuard Public Key:   ${YELLOW}${SERVER_PUBLIC}${NC}"
echo -e "  IP клиента в WG-сети:   ${YELLOW}${WG_CLIENT_IP}${NC}"
echo ""

if [[ -z "$RU_VPS_PUBKEY" ]]; then
    echo -e "${YELLOW}Не забудьте добавить Peer после запуска setup-ru-vps.sh:${NC}"
    echo -e "  ${CYAN}sudo wg set wg0 peer <PUBLIC_KEY> allowed-ips ${WG_CLIENT_IP}/32${NC}"
    echo -e "  ${CYAN}sudo wg-quick save wg0${NC}"
    echo ""
fi

echo -e "${GREEN}Все данные сохранены в:${NC} ${CREDENTIALS_FILE}"
echo ""
