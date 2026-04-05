#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# setup-desktop.sh — Установка sing-box клиента на Mac / Ubuntu / Debian
#
# Что делает:
#   1. Определяет ОС и устанавливает sing-box
#   2. Спрашивает данные из VLESS-ссылки
#   3. Генерирует конфиг с TUN (перехват всего трафика)
#   4. Настраивает автозапуск (launchd на Mac, systemd на Linux)
#   5. Запускает sing-box
#
# Использование:
#   chmod +x setup-desktop.sh
#   sudo ./setup-desktop.sh
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# =====================================================================
# 0. ОПРЕДЕЛЕНИЕ ОС
# =====================================================================

OS="unknown"
case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)
        if [ -f /etc/debian_version ]; then
            OS="debian"
        elif [ -f /etc/redhat-release ]; then
            OS="rhel"
        else
            OS="linux"
        fi
        ;;
    *) err "Неподдерживаемая ОС: $(uname -s)" ;;
esac

log "ОС: $OS ($(uname -m))"

# На Linux нужен root, на Mac — sudo запросится при необходимости
if [ "$OS" != "mac" ] && [ "$(id -u)" -ne 0 ]; then
    err "Запустите от root: sudo $0"
fi

echo -e "${CYAN}"
echo "============================================================"
echo "  Установка sing-box клиента"
echo ""
echo "  Клиент (TUN) -> VLESS/Reality -> Интернет"
echo "  .ru / .рф / .su -> напрямую"
echo "============================================================"
echo -e "${NC}"

# =====================================================================
# 1. УСТАНОВКА SING-BOX
# =====================================================================
log "Устанавливаю sing-box..."

case "$OS" in
    mac)
        if ! command -v brew &>/dev/null; then
            err "Homebrew не найден. Установите: https://brew.sh"
        fi
        if command -v sing-box &>/dev/null; then
            log "sing-box уже установлен: $(sing-box version 2>/dev/null | head -1)"
        else
            brew install sing-box
        fi
        SINGBOX_BIN=$(command -v sing-box)
        CONFIG_DIR="/usr/local/etc/sing-box"
        ;;
    debian)
        if command -v sing-box &>/dev/null; then
            log "sing-box уже установлен: $(sing-box version 2>/dev/null | head -1)"
        else
            # Пробуем из репозитория, иначе скачиваем бинарник
            apt-get update -qq
            if apt-cache show sing-box &>/dev/null 2>&1; then
                apt-get install -y -qq sing-box
            else
                log "Скачиваю бинарник..."
                apt-get install -y -qq curl ca-certificates

                ARCH=$(uname -m)
                case "$ARCH" in
                    x86_64)  SINGBOX_ARCH="amd64" ;;
                    aarch64) SINGBOX_ARCH="arm64" ;;
                    armv7l)  SINGBOX_ARCH="armv7" ;;
                    *)       err "Неизвестная архитектура: $ARCH" ;;
                esac

                SINGBOX_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
                [ -z "$SINGBOX_VERSION" ] && err "Не удалось определить версию"

                curl -L -o /tmp/sing-box.tar.gz \
                    "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz"
                tar xzf /tmp/sing-box.tar.gz -C /tmp
                cp "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}/sing-box" /usr/local/bin/sing-box
                chmod +x /usr/local/bin/sing-box
                rm -rf "/tmp/sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}" /tmp/sing-box.tar.gz
            fi
        fi
        SINGBOX_BIN=$(command -v sing-box)
        CONFIG_DIR="/etc/sing-box"
        ;;
    *)
        err "Автоустановка не поддерживается для этой ОС. Установите sing-box вручную."
        ;;
esac

log "sing-box: $($SINGBOX_BIN version 2>/dev/null | head -1)"

# =====================================================================
# 2. СБОР ДАННЫХ
# =====================================================================

echo ""
echo -e "${CYAN}=== Данные из VLESS-ссылки ===${NC}"
echo ""

read -rp "IP российского VPS: " RU_VPS_IP
[[ -z "$RU_VPS_IP" ]] && err "IP не может быть пустым"

read -rp "UUID: " UUID
[[ -z "$UUID" ]] && err "UUID не может быть пустым"

read -rp "Reality Public Key: " REALITY_PUBKEY
[[ -z "$REALITY_PUBKEY" ]] && err "Public Key не может быть пустым"

read -rp "Short ID: " SHORT_ID
[[ -z "$SHORT_ID" ]] && err "Short ID не может быть пустым"

read -rp "Сайт маскировки Reality [www.google.com]: " REALITY_SNI
REALITY_SNI=${REALITY_SNI:-www.google.com}

read -rp "Порт VLESS [443]: " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}

# =====================================================================
# 3. КОНФИГ SING-BOX
# =====================================================================
log "Создаю конфиг..."

mkdir -p "$CONFIG_DIR"

# TUN-имя зависит от ОС
if [ "$OS" = "mac" ]; then
    TUN_NAME="utun99"
else
    TUN_NAME="tun0"
fi

cat > "$CONFIG_DIR/config.json" << SEOF
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
      "interface_name": "${TUN_NAME}",
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
if $SINGBOX_BIN check -c "$CONFIG_DIR/config.json" 2>&1; then
    log "Конфиг валидный"
else
    warn "Проверьте конфиг вручную: $CONFIG_DIR/config.json"
fi

# =====================================================================
# 4. ЗАПУСК
# =====================================================================

if [ "$OS" = "mac" ]; then
    # --- launchd ---
    PLIST="/Library/LaunchDaemons/com.sing-box.plist"

    cat > "$PLIST" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sing-box</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SINGBOX_BIN}</string>
        <string>run</string>
        <string>-c</string>
        <string>${CONFIG_DIR}/config.json</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/sing-box.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/sing-box.log</string>
</dict>
</plist>
PEOF

    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    launchctl start com.sing-box

    sleep 3

    if pgrep -q sing-box; then
        log "sing-box запущен!"
    else
        warn "sing-box не стартовал. Логи: /var/log/sing-box.log"
    fi

    # Спрашиваем про автозапуск
    echo ""
    read -rp "Включить автозапуск при загрузке системы? [y/n]: " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy] ]]; then
        # Меняем RunAtLoad и KeepAlive на true
        sed -i '' 's|<key>RunAtLoad</key>|<key>RunAtLoad</key>|' "$PLIST"
        sed -i '' '/<key>RunAtLoad<\/key>/{n;s|<false/>|<true/>|;}' "$PLIST"
        sed -i '' '/<key>KeepAlive<\/key>/{n;s|<false/>|<true/>|;}' "$PLIST"
        launchctl unload "$PLIST" 2>/dev/null || true
        launchctl load "$PLIST"
        log "Автозапуск включён"
    else
        log "Автозапуск не включён"
    fi

else
    # --- systemd ---
    cat > /etc/systemd/system/sing-box.service << UEOF
[Unit]
Description=sing-box proxy client
After=network.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UEOF

    systemctl daemon-reload
    systemctl restart sing-box

    sleep 3

    if systemctl is-active --quiet sing-box; then
        log "sing-box запущен!"
    else
        warn "sing-box не стартовал. Логи:"
        journalctl -u sing-box -n 10 --no-pager
    fi

    # Спрашиваем про автозапуск
    echo ""
    read -rp "Включить автозапуск при загрузке системы? [y/n]: " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy] ]]; then
        systemctl enable sing-box
        log "Автозапуск включён"
    else
        log "Автозапуск не включён"
    fi
fi

# =====================================================================
# 5. ИТОГ
# =====================================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  УСТАНОВКА ЗАВЕРШЕНА${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${GREEN}Конфиг:${NC} $CONFIG_DIR/config.json"

if [ "$OS" = "mac" ]; then
    echo -e "${GREEN}Сервис:${NC} $PLIST"
    echo ""
    echo -e "${GREEN}Управление:${NC}"
    echo "  sudo launchctl start com.sing-box   — запуск"
    echo "  sudo launchctl stop com.sing-box    — остановка"
    echo "  Автозапуск вкл: установить RunAtLoad=true в $PLIST"
    echo "  Логи: tail -f /var/log/sing-box.log"
else
    echo ""
    echo -e "${GREEN}Управление:${NC}"
    echo "  sudo systemctl start sing-box    — запуск"
    echo "  sudo systemctl stop sing-box     — остановка"
    echo "  sudo systemctl restart sing-box  — перезапуск"
    echo "  sudo systemctl enable sing-box   — включить автозапуск"
    echo "  sudo systemctl disable sing-box  — выключить автозапуск"
    echo "  Логи: journalctl -u sing-box -f"
fi

echo ""
echo -e "${GREEN}Проверка:${NC}"
echo -e "  ${YELLOW}curl -4 ifconfig.me${NC}"
echo "  Должен показать IP зарубежного VPS"
echo ""
echo -e "${GREEN}Маршрутизация:${NC}"
echo "  .ru / .рф / .su / локальные сети -> напрямую"
echo "  Остальной трафик -> через VPN"
echo ""
