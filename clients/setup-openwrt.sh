#!/bin/sh

#===============================================================================
# setup-openwrt.sh — Настройка sing-box на роутере с OpenWrt
#
# Что делает:
#   1. Устанавливает sing-box через opkg
#   2. Создаёт конфиг с tproxy (прозрачное проксирование)
#   3. Настраивает nftables/iptables и policy routing
#   4. Создаёт procd init-сервис для автозапуска
#
# Требования:
#   - OpenWrt 22.03+ (nftables) или 19.07+ (iptables)
#   - SSH-доступ к роутеру
#   - Данные из VLESS-ссылки (после запуска setup-ru-vps.sh)
#
# Использование:
#   /tmp/setup-openwrt.sh                            # интерактивный ввод
#   /tmp/setup-openwrt.sh --from /tmp/.vpn-params    # из файла параметров
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# =====================================================================
# 0. ПРОВЕРКИ
# =====================================================================

[ "$(id -u)" -ne 0 ] && err "Запустите от root"

if ! grep -qi "openwrt" /etc/os-release 2>/dev/null; then
    warn "Не похоже на OpenWrt — продолжаю на свой страх и риск"
fi

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    aarch64)      SINGBOX_ARCH="arm64" ;;
    armv7l|armv7) SINGBOX_ARCH="armv7" ;;
    mips)         SINGBOX_ARCH="mips-softfloat" ;;
    mipsel)       SINGBOX_ARCH="mipsle-softfloat" ;;
    x86_64)       SINGBOX_ARCH="amd64" ;;
    i686|i386)    SINGBOX_ARCH="386" ;;
    *)            err "Неизвестная архитектура: $ARCH" ;;
esac

# Определяем firewall: nftables (fw4) или iptables (fw3)
if command -v nft >/dev/null 2>&1; then
    FW_TYPE="nftables"
else
    FW_TYPE="iptables"
fi

log "Архитектура: $ARCH -> sing-box $SINGBOX_ARCH"
log "Firewall: $FW_TYPE"

echo -e "${CYAN}"
echo "============================================================"
echo "  Настройка sing-box на OpenWrt"
echo ""
echo "  Весь трафик LAN -> [sing-box tproxy] -> VLESS/Reality"
echo "  .ru / .рф / .su -> напрямую"
echo "============================================================"
echo -e "${NC}"

# =====================================================================
# 1. ПОЛУЧЕНИЕ ПАРАМЕТРОВ ПОДКЛЮЧЕНИЯ
# =====================================================================

RU_VPS_IP=""
REALITY_PUBKEY=""
REALITY_SNI="www.google.com"
VLESS_PORT="443"

# Парсим --from аргумент
PARAMS_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) PARAMS_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -n "$PARAMS_FILE" ]; then
    [ ! -f "$PARAMS_FILE" ] && err "Файл не найден: $PARAMS_FILE"
    . "$PARAMS_FILE"
    # Маппинг имён из .vpn-params
    RU_VPS_IP="${SERVER_IP:-}"
    REALITY_PUBKEY="${REALITY_PUBLIC_KEY:-}"
    REALITY_SNI="${REALITY_DEST:-www.google.com}"
    log "Параметры загружены из $PARAMS_FILE"
else
    echo -e "${CYAN}=== Данные из VLESS-ссылки ===${NC}"
    echo ""

    printf "IP российского VPS: "
    read RU_VPS_IP
    [ -z "$RU_VPS_IP" ] && err "IP не может быть пустым"

    printf "UUID: "
    read UUID
    [ -z "$UUID" ] && err "UUID не может быть пустым"

    printf "Reality Public Key: "
    read REALITY_PUBKEY
    [ -z "$REALITY_PUBKEY" ] && err "Public Key не может быть пустым"

    printf "Short ID: "
    read SHORT_ID
    [ -z "$SHORT_ID" ] && err "Short ID не задан"

    printf "Сайт маскировки Reality [www.google.com]: "
    read REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.google.com}

    printf "Порт VLESS [443]: "
    read VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}
fi

[ -z "$RU_VPS_IP" ] && err "IP сервера не задан"
[ -z "$UUID" ] && err "UUID не задан"
[ -z "$REALITY_PUBKEY" ] && err "Reality Public Key не задан"
[ -z "$SHORT_ID" ] && err "Short ID не задан"

# =====================================================================
# 2. УСТАНОВКА SING-BOX
# =====================================================================
log "Устанавливаю зависимости..."

opkg update
opkg install ca-certificates curl ip-full kmod-tun

# Пробуем установить sing-box из репозитория
if opkg list | grep -q "^sing-box"; then
    log "Устанавливаю sing-box из opkg..."
    opkg install sing-box
else
    log "sing-box нет в opkg, скачиваю бинарник..."

    SINGBOX_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    [ -z "$SINGBOX_VERSION" ] && err "Не удалось определить версию sing-box"
    log "Версия: $SINGBOX_VERSION"

    SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz"

    curl -L -o /tmp/sing-box.tar.gz "$SINGBOX_URL" || err "Не удалось скачать sing-box"

    cd /tmp
    tar xzf sing-box.tar.gz
    cp "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}/sing-box" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    rm -rf "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}" /tmp/sing-box.tar.gz
fi

log "sing-box: $(sing-box version 2>/dev/null | head -1)"

# =====================================================================
# 3. КОНФИГУРАЦИЯ SING-BOX
# =====================================================================
log "Создаю конфиг..."

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json << SEOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "cloudflare-doh",
        "server": "1.1.1.1"
      },
      {
        "type": "local",
        "tag": "local-dns"
      }
    ],
    "final": "cloudflare-doh",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": 12345,
      "network": "tcp",
      "sniff": true,
      "sniff_override_destination": false
    },
    {
      "type": "tproxy",
      "tag": "tproxy-udp-in",
      "listen": "::",
      "listen_port": 12345,
      "network": "udp",
      "sniff": true,
      "sniff_override_destination": false
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "${RU_VPS_IP}",
      "server_port": ${VLESS_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBKEY}",
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
    },
    {
      "type": "dns",
      "tag": "dns-out"
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

log "Проверяю конфиг..."
if sing-box check -c /etc/sing-box/config.json 2>&1; then
    log "Конфиг валидный"
else
    warn "Проверьте конфиг вручную"
fi

# =====================================================================
# 4. ПРАВИЛА FIREWALL
# =====================================================================
log "Настраиваю firewall ($FW_TYPE)..."

TPROXY_PORT=12345
MARK=1
TABLE=100

if [ "$FW_TYPE" = "nftables" ]; then
    # --- nftables (OpenWrt 22.03+, fw4) ---

    cat > /etc/sing-box/nftables.sh << NEOF
#!/bin/sh

TPROXY_PORT=${TPROXY_PORT}
MARK=${MARK}
TABLE=${TABLE}
RU_VPS_IP="${RU_VPS_IP}"

start() {
    ip rule add fwmark \$MARK table \$TABLE 2>/dev/null || true
    ip route add local default dev lo table \$TABLE 2>/dev/null || true

    nft add table inet sing-box 2>/dev/null || nft flush table inet sing-box

    nft -f - <<'NFT_EOF'
table inet sing-box {
    set bypass_ipv4 {
        type ipv4_addr
        flags interval
        elements = {
            10.0.0.0/8,
            100.64.0.0/10,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        }
    }

    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ip daddr @bypass_ipv4 return
        meta l4proto { tcp, udp } tproxy to :12345 meta mark set 1
    }

    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr @bypass_ipv4 return
        meta l4proto { tcp, udp } meta mark set 1
    }
}
NFT_EOF

    # Добавляем IP VPS в bypass
    nft add element inet sing-box bypass_ipv4 "{ \$RU_VPS_IP }"

    echo "nftables rules applied"
}

stop() {
    nft delete table inet sing-box 2>/dev/null || true
    ip rule del fwmark \$MARK table \$TABLE 2>/dev/null || true
    ip route del local default dev lo table \$TABLE 2>/dev/null || true
    echo "nftables rules removed"
}

case "\$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; start ;;
    *) echo "Usage: \$0 {start|stop|restart}" ;;
esac
NEOF

    chmod +x /etc/sing-box/nftables.sh
    FW_SCRIPT="/etc/sing-box/nftables.sh"

else
    # --- iptables (OpenWrt 19.07+, fw3) ---

    cat > /etc/sing-box/iptables.sh << IEOF
#!/bin/sh

TPROXY_PORT=${TPROXY_PORT}
MARK=${MARK}
TABLE=${TABLE}
RU_VPS_IP="${RU_VPS_IP}"

start() {
    ip rule add fwmark \$MARK table \$TABLE 2>/dev/null || true
    ip route add local default dev lo table \$TABLE 2>/dev/null || true

    iptables -t mangle -N SING_BOX 2>/dev/null || iptables -t mangle -F SING_BOX

    iptables -t mangle -A SING_BOX -d \$RU_VPS_IP/32 -j RETURN
    iptables -t mangle -A SING_BOX -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX -d 100.64.0.0/10 -j RETURN
    iptables -t mangle -A SING_BOX -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SING_BOX -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$MARK
    iptables -t mangle -A SING_BOX -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$MARK
    iptables -t mangle -A PREROUTING -j SING_BOX

    iptables -t mangle -N SING_BOX_SELF 2>/dev/null || iptables -t mangle -F SING_BOX_SELF
    iptables -t mangle -A SING_BOX_SELF -d \$RU_VPS_IP/32 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 100.64.0.0/10 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -p tcp -j MARK --set-mark \$MARK
    iptables -t mangle -A SING_BOX_SELF -p udp -j MARK --set-mark \$MARK
    iptables -t mangle -A OUTPUT -j SING_BOX_SELF

    echo "iptables rules applied"
}

stop() {
    iptables -t mangle -D PREROUTING -j SING_BOX 2>/dev/null || true
    iptables -t mangle -D OUTPUT -j SING_BOX_SELF 2>/dev/null || true
    iptables -t mangle -F SING_BOX 2>/dev/null || true
    iptables -t mangle -X SING_BOX 2>/dev/null || true
    iptables -t mangle -F SING_BOX_SELF 2>/dev/null || true
    iptables -t mangle -X SING_BOX_SELF 2>/dev/null || true
    ip rule del fwmark \$MARK table \$TABLE 2>/dev/null || true
    ip route del local default dev lo table \$TABLE 2>/dev/null || true
    echo "iptables rules removed"
}

case "\$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; start ;;
    *) echo "Usage: \$0 {start|stop|restart}" ;;
esac
IEOF

    chmod +x /etc/sing-box/iptables.sh
    FW_SCRIPT="/etc/sing-box/iptables.sh"
fi

# =====================================================================
# 5. PROCD INIT-СЕРВИС
# =====================================================================
log "Создаю procd init-сервис..."

cat > /etc/init.d/sing-box << DEOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

FW_SCRIPT="${FW_SCRIPT}"

start_service() {
    \$FW_SCRIPT start

    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    \$FW_SCRIPT stop
}

reload_service() {
    stop
    start
}
DEOF

chmod +x /etc/init.d/sing-box

# =====================================================================
# 6. HOTPLUG (восстановление правил при смене интерфейса)
# =====================================================================
log "Настраиваю hotplug..."

mkdir -p /etc/hotplug.d/iface

cat > /etc/hotplug.d/iface/99-singbox << 'HEOF'
#!/bin/sh
# Переприменяем правила при поднятии WAN-интерфейса
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && {
    sleep 3
    /etc/init.d/sing-box reload
}
HEOF

chmod +x /etc/hotplug.d/iface/99-singbox

# =====================================================================
# 7. ЗАПУСК
# =====================================================================
log "Запускаю sing-box..."

/etc/init.d/sing-box enable
/etc/init.d/sing-box start

sleep 3

if pidof sing-box >/dev/null 2>&1; then
    log "sing-box запущен!"
else
    warn "sing-box не стартовал. Проверьте:"
    echo "  sing-box run -c /etc/sing-box/config.json"
    echo "  logread | grep sing-box"
fi

# =====================================================================
# ИТОГ
# =====================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${GREEN}Конфиг:${NC}    /etc/sing-box/config.json"
echo -e "${GREEN}Firewall:${NC}  ${FW_SCRIPT}"
echo -e "${GREEN}Сервис:${NC}    /etc/init.d/sing-box"
echo ""
echo -e "${GREEN}Управление:${NC}"
echo "  /etc/init.d/sing-box start    — запуск"
echo "  /etc/init.d/sing-box stop     — остановка"
echo "  /etc/init.d/sing-box restart  — перезапуск"
echo "  /etc/init.d/sing-box disable  — выключить автозапуск"
echo ""
echo -e "${GREEN}Логи:${NC}"
echo "  logread | grep sing-box"
echo ""
echo -e "${GREEN}Проверка (с любого устройства в сети):${NC}"
echo -e "  ${YELLOW}curl -4 ifconfig.me${NC}"
echo "  Должен показать IP зарубежного VPS"
echo ""
echo -e "${GREEN}Маршрутизация:${NC}"
echo "  .ru / .рф / .su / локальные сети -> напрямую"
echo "  Остальной трафик -> через VPN"
echo ""
