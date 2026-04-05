#!/bin/sh

#===============================================================================
# setup-keenetic.sh — Настройка sing-box на роутере Keenetic (Entware)
#
# Что делает:
#   1. Проверяет наличие Entware
#   2. Скачивает sing-box для архитектуры роутера
#   3. Создаёт конфиг с tproxy (прозрачное проксирование)
#   4. Настраивает iptables и policy routing
#   5. Создаёт init.d сервис для автозапуска
#
# Требования:
#   - Keenetic с установленным Entware (Пакеты → OPKG)
#   - SSH-доступ к роутеру
#   - Данные из VLESS-ссылки (после запуска setup-ru-vps.sh)
#
# Использование:
#   scp setup-keenetic.sh root@<keenetic-ip>:/opt/
#   ssh root@<keenetic-ip>
#   chmod +x /opt/setup-keenetic.sh
#   /opt/setup-keenetic.sh
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

if [ ! -d /opt/etc ]; then
    err "Entware не найден. Установите через веб-интерфейс: Управление → Пакеты → OPKG"
fi

if [ "$(id -u)" -ne 0 ]; then
    err "Запустите от root"
fi

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    aarch64)      SINGBOX_ARCH="arm64" ;;
    armv7l|armv7) SINGBOX_ARCH="armv7" ;;
    mips)         SINGBOX_ARCH="mips-softfloat" ;;
    mipsel)       SINGBOX_ARCH="mipsle-softfloat" ;;
    x86_64)       SINGBOX_ARCH="amd64" ;;
    *)            err "Неизвестная архитектура: $ARCH" ;;
esac

log "Архитектура: $ARCH -> sing-box $SINGBOX_ARCH"

echo -e "${CYAN}"
echo "============================================================"
echo "  Настройка sing-box на Keenetic (Entware)"
echo ""
echo "  Весь трафик LAN -> [sing-box tproxy] -> VLESS/Reality"
echo "============================================================"
echo -e "${NC}"

# =====================================================================
# 1. СБОР ДАННЫХ
# =====================================================================

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
[ -z "$SHORT_ID" ] && err "Short ID не может быть пустым"

printf "Сайт маскировки Reality [www.google.com]: "
read REALITY_SNI
REALITY_SNI=${REALITY_SNI:-www.google.com}

printf "Порт VLESS [443]: "
read VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}

# =====================================================================
# 2. УСТАНОВКА ЗАВИСИМОСТЕЙ
# =====================================================================
log "Устанавливаю зависимости..."

opkg update
opkg install ca-certificates curl iptables ip-full

# =====================================================================
# 3. СКАЧИВАНИЕ SING-BOX
# =====================================================================
log "Скачиваю sing-box..."

SINGBOX_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
[ -z "$SINGBOX_VERSION" ] && err "Не удалось определить версию sing-box"
log "Последняя версия: $SINGBOX_VERSION"

SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz"
SINGBOX_TMP="/tmp/sing-box.tar.gz"

curl -L -o "$SINGBOX_TMP" "$SINGBOX_URL" || err "Не удалось скачать sing-box"

cd /tmp
tar xzf "$SINGBOX_TMP"
cp "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}/sing-box" /opt/bin/sing-box
chmod +x /opt/bin/sing-box
rm -rf "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}" "$SINGBOX_TMP"

log "sing-box установлен: $(/opt/bin/sing-box version 2>/dev/null | head -1)"

# =====================================================================
# 4. КОНФИГУРАЦИЯ SING-BOX
# =====================================================================
log "Создаю конфиг..."

mkdir -p /opt/etc/sing-box

cat > /opt/etc/sing-box/config.json << SEOF
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
    },
    {
      "type": "redirect",
      "tag": "redirect-in",
      "listen": "::",
      "listen_port": 12346,
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
if /opt/bin/sing-box check -c /opt/etc/sing-box/config.json 2>&1; then
    log "Конфиг валидный"
else
    warn "Проверьте конфиг вручную"
fi

# =====================================================================
# 5. СКРИПТ IPTABLES ДЛЯ TPROXY
# =====================================================================
log "Создаю скрипт iptables..."

cat > /opt/etc/sing-box/iptables.sh << 'IEOF'
#!/bin/sh

TPROXY_PORT=12345
REDIRECT_PORT=12346
MARK=1
TABLE=100
RU_VPS_IP="__RU_VPS_IP__"

start() {
    # Таблица маршрутизации для помеченных пакетов
    ip rule add fwmark $MARK table $TABLE 2>/dev/null || true
    ip route add local default dev lo table $TABLE 2>/dev/null || true

    # Создаём цепочку SING_BOX
    iptables -t mangle -N SING_BOX 2>/dev/null || iptables -t mangle -F SING_BOX

    # Исключения: не проксируем трафик к VPS и локальные сети
    iptables -t mangle -A SING_BOX -d $RU_VPS_IP/32 -j RETURN
    iptables -t mangle -A SING_BOX -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX -d 100.64.0.0/10 -j RETURN
    iptables -t mangle -A SING_BOX -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SING_BOX -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX -d 240.0.0.0/4 -j RETURN

    # TCP и UDP -> TPROXY
    iptables -t mangle -A SING_BOX -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK
    iptables -t mangle -A SING_BOX -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK

    # Применяем к PREROUTING (трафик от LAN-клиентов)
    iptables -t mangle -A PREROUTING -j SING_BOX

    # Для трафика самого роутера (OUTPUT)
    iptables -t mangle -N SING_BOX_SELF 2>/dev/null || iptables -t mangle -F SING_BOX_SELF
    iptables -t mangle -A SING_BOX_SELF -d $RU_VPS_IP/32 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 100.64.0.0/10 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A SING_BOX_SELF -p tcp -j MARK --set-mark $MARK
    iptables -t mangle -A SING_BOX_SELF -p udp -j MARK --set-mark $MARK
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
    ip rule del fwmark $MARK table $TABLE 2>/dev/null || true
    ip route del local default dev lo table $TABLE 2>/dev/null || true
    echo "iptables rules removed"
}

case "$1" in
    start) start ;;
    stop)  stop ;;
    restart) stop; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac
IEOF

# Подставляем реальный IP VPS
sed -i "s|__RU_VPS_IP__|${RU_VPS_IP}|g" /opt/etc/sing-box/iptables.sh
chmod +x /opt/etc/sing-box/iptables.sh

# =====================================================================
# 6. INIT.D СЕРВИС
# =====================================================================
log "Создаю init.d сервис..."

cat > /opt/etc/init.d/S99singbox << 'DEOF'
#!/bin/sh

ENABLED=yes
PROCS=sing-box
ARGS="run -c /opt/etc/sing-box/config.json"
PREARGS="nohup"
DESC="sing-box proxy"
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
IPTABLES_SCRIPT=/opt/etc/sing-box/iptables.sh

. /opt/etc/init.d/rc.func

start_post() {
    sleep 2
    $IPTABLES_SCRIPT start
}

stop_pre() {
    $IPTABLES_SCRIPT stop
}
DEOF

chmod +x /opt/etc/init.d/S99singbox

# =====================================================================
# 7. NDMS HOOK (автозапуск при загрузке)
# =====================================================================
log "Настраиваю автозапуск..."

NDMS_HOOK="/opt/etc/ndm/netfilter.d/010-singbox.sh"
mkdir -p /opt/etc/ndm/netfilter.d

cat > "$NDMS_HOOK" << 'HEOF'
#!/bin/sh
# Переприменяем правила iptables после перестроения netfilter Keenetic-ом
[ -x /opt/etc/sing-box/iptables.sh ] && /opt/etc/sing-box/iptables.sh start
HEOF

chmod +x "$NDMS_HOOK"

# =====================================================================
# 8. ЗАПУСК
# =====================================================================
echo ""
log "Запускаю sing-box..."
/opt/etc/init.d/S99singbox start

sleep 3

if pidof sing-box >/dev/null 2>&1; then
    log "sing-box запущен!"
else
    warn "sing-box не стартовал. Проверьте логи:"
    echo "  /opt/bin/sing-box run -c /opt/etc/sing-box/config.json"
fi

# =====================================================================
# ИТОГ
# =====================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${GREEN}Конфиг:${NC}    /opt/etc/sing-box/config.json"
echo -e "${GREEN}iptables:${NC}  /opt/etc/sing-box/iptables.sh"
echo -e "${GREEN}Сервис:${NC}    /opt/etc/init.d/S99singbox"
echo ""
echo -e "${GREEN}Управление:${NC}"
echo "  /opt/etc/init.d/S99singbox start    — запуск"
echo "  /opt/etc/init.d/S99singbox stop     — остановка"
echo "  /opt/etc/init.d/S99singbox restart  — перезапуск"
echo ""
echo -e "${GREEN}Проверка (с любого устройства в сети):${NC}"
echo -e "  ${YELLOW}curl -4 ifconfig.me${NC}"
echo "  Должен показать IP зарубежного VPS"
echo ""
echo -e "${GREEN}Маршрутизация:${NC}"
echo "  .ru / .xn--p1ai / .su / локальные сети -> напрямую"
echo "  Остальной трафик -> через VPN"
echo ""
echo -e "${YELLOW}Важно:${NC} Keenetic может сбрасывать iptables правила при"
echo "  изменении сетевых настроек. Хук в netfilter.d их восстановит."
echo ""
