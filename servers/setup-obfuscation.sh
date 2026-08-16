#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# setup-obfuscation.sh — обфускация межсерверного WireGuard в TLS/WebSocket
#
# Зачем:
#   DPI/ТСПУ распознаёт WireGuard по сигнатуре рукопожатия и точечно блокирует
#   exit-IP зарубежного VPS. Симптом: туннель работал, потом внезапно перестают
#   приходить пакеты обратно на RU (latest handshake не обновляется).
#
#   Скрипт заворачивает WG-трафик RU↔Foreign в WSS (WebSocket over TLS) через
#   wstunnel, спрятанный за Caddy на реальном домене. На проводе RU→Foreign
#   выглядит как обычный HTTPS-визит на сайт — WG-сигнатуры нет.
#
#     RU: WG(127.0.0.1:51821) → wstunnel client ─WSS/TLS:443→ Caddy(домен)
#                                              → wstunnel server → WG(127.0.0.1:WG_PORT) :Foreign
#
# Клиентов (VLESS/Reality) это НЕ касается — их конфиги не меняются.
#
# Использование (запускать ПОСЛЕ рабочего setup-foreign-vps.sh + setup-ru-vps.sh):
#   На зарубежном VPS:   sudo ./setup-obfuscation.sh foreign
#   На российском VPS:    sudo ./setup-obfuscation.sh ru
#   Откат (на любом):     sudo ./setup-obfuscation.sh disable
#
# Требования:
#   - Домен с A-записью на зарубежный VPS (для валидного Let's Encrypt-серта).
#     Если exit-IP заблокирован и вы подняли резервный IP — на RU можно указать
#     отдельный IP для подключения (домен резолвится в него через /etc/hosts).
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Запустите от root: sudo $0 <foreign|ru|disable>"

# --- Константы ---
PARAMS_FILE="/root/.vpn-params"
SECRET_FILE="/root/.wstunnel-secret"
WSTUNNEL_FALLBACK="10.6.2"          # версия, если GitHub API недоступен
WS_LOCAL_PORT="8080"                # локальный порт wstunnel-server на Foreign
RU_LOCAL_PORT="51821"               # локальный вход wstunnel-client на RU

# Подхватываем параметры от базовых скриптов (WG_PORT / FOREIGN_PORT и т.д.)
[[ -f "$PARAMS_FILE" ]] && source "$PARAMS_FILE" || true

# =====================================================================
# Установка wstunnel (один Go-бинарь, все арх.)
# =====================================================================
install_wstunnel() {
    if command -v wstunnel &>/dev/null; then
        log "wstunnel уже установлен: $(wstunnel --version 2>/dev/null | head -1)"
        return
    fi
    local arch tarch url tmp
    arch=$(uname -m)
    case "$arch" in
        x86_64)          tarch="amd64"  ;;
        aarch64|arm64)   tarch="arm64"  ;;
        armv7l)          tarch="armv7"  ;;
        *) err "Неизвестная архитектура: $arch" ;;
    esac
    url=$(curl -s --max-time 15 https://api.github.com/repos/erebe/wstunnel/releases/latest \
          | grep -oE "https://[^\"]*linux_${tarch}\.tar\.gz" | head -1 || true)
    [[ -z "$url" ]] && url="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_FALLBACK}/wstunnel_${WSTUNNEL_FALLBACK}_linux_${tarch}.tar.gz"
    log "Скачиваю wstunnel: $url"
    tmp=$(mktemp -d)
    curl -sL --max-time 60 -o "$tmp/w.tgz" "$url" || err "Не удалось скачать wstunnel"
    tar xzf "$tmp/w.tgz" -C "$tmp" || err "Не удалось распаковать wstunnel"
    install -m755 "$tmp/wstunnel" /usr/local/bin/wstunnel || err "Не удалось установить wstunnel"
    rm -rf "$tmp"
    log "wstunnel установлен: $(wstunnel --version 2>/dev/null | head -1)"
}

# =====================================================================
# Установка Caddy (официальный apt-репозиторий)
# =====================================================================
install_caddy() {
    command -v caddy &>/dev/null && { log "Caddy уже установлен"; return; }
    log "Устанавливаю Caddy..."
    if [[ -f /etc/debian_version ]]; then
        apt install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt update -qq && apt install -y -qq caddy
    else
        err "Автоустановка Caddy поддержана только для Debian/Ubuntu. Установите Caddy вручную: https://caddyserver.com/docs/install"
    fi
    log "Caddy установлен"
}

# =====================================================================
# Caddy: добавить маршрут секретного пути -> wstunnel в блок домена
# =====================================================================
configure_caddy_route() {
    local domain="$1" secret="$2"
    local cf="/etc/caddy/Caddyfile"
    mkdir -p /etc/caddy
    touch "$cf"

    if grep -qE "wstunnel-obfuscation|@wstun|127.0.0.1:${WS_LOCAL_PORT}" "$cf"; then
        log "Маршрут wstunnel в Caddyfile уже есть — пропускаю"
        return
    fi

    cp "$cf" "${cf}.bak.beforewstun"

    # Пытаемся вставить в существующий блок домена; иначе создаём новый.
    local inserted=0
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ $inserted -eq 0 && "$line" == *"$domain"* && "$line" == *"{" ]]; then
            printf '    # wstunnel-obfuscation (auto-added)\n'
            printf '    @wstun path /%s /%s/*\n' "$secret" "$secret"
            printf '    reverse_proxy @wstun 127.0.0.1:%s\n' "$WS_LOCAL_PORT"
            inserted=1
        fi
    done < "${cf}.bak.beforewstun" > "$cf"

    if [[ $inserted -eq 0 ]]; then
        warn "Блок домена ${domain} не найден — создаю новый в Caddyfile"
        cat >> "$cf" << EOF

${domain} {
    # wstunnel-obfuscation (auto-added)
    @wstun path /${secret} /${secret}/*
    reverse_proxy @wstun 127.0.0.1:${WS_LOCAL_PORT}
    respond "OK" 200
}
EOF
    fi

    if caddy validate --config "$cf" --adapter caddyfile >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        log "Caddy сконфигурирован и перезагружен"
    else
        warn "Caddyfile невалиден — откатываю"
        cp "${cf}.bak.beforewstun" "$cf"
        systemctl reload caddy 2>/dev/null || true
        err "Проверьте Caddyfile вручную: caddy validate --config $cf --adapter caddyfile"
    fi
}

# =====================================================================
# РОЛЬ: FOREIGN (зарубежный VPS — сервер wstunnel + Caddy)
# =====================================================================
setup_foreign() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   Обфускация: FOREIGN VPS (wstunnel server + Caddy/TLS)     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local wg_port="${WG_PORT:-51820}"
    read -rp "WireGuard порт этого VPS [${wg_port}]: " IN_PORT
    wg_port="${IN_PORT:-$wg_port}"

    read -rp "Домен для маскировки (A-запись должна указывать на этот VPS): " DOMAIN
    [[ -z "$DOMAIN" ]] && err "Домен обязателен для валидного TLS-сертификата"

    # Секрет = пароль пути. Переиспользуем, если уже есть.
    local secret
    if [[ -f "$SECRET_FILE" ]]; then
        secret=$(cat "$SECRET_FILE")
        log "Использую существующий секрет из $SECRET_FILE"
    else
        secret=$(openssl rand -hex 12)
        echo "$secret" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        log "Сгенерирован секретный путь"
    fi

    install_wstunnel
    install_caddy

    # wstunnel server: принимает WSS (TLS терминирует Caddy) -> локальный WG
    cat > /etc/systemd/system/wstunnel-server.service << EOF
[Unit]
Description=wstunnel server (WG-over-WSS obfuscation)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/wstunnel server ws://127.0.0.1:${WS_LOCAL_PORT} --restrict-to 127.0.0.1:${wg_port} --restrict-http-upgrade-path-prefix ${secret}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wstunnel-server >/dev/null 2>&1
    sleep 1
    systemctl is-active --quiet wstunnel-server || { journalctl -u wstunnel-server -n 15 --no-pager; err "wstunnel-server не запустился"; }
    log "wstunnel-server активен (127.0.0.1:${WS_LOCAL_PORT} → 127.0.0.1:${wg_port})"

    configure_caddy_route "$DOMAIN" "$secret"

    local ip; ip=$(curl -s4 ifconfig.me || echo "<FOREIGN_IP>")
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              FOREIGN настроен — данные для RU               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  Домен:          ${YELLOW}${DOMAIN}${NC}"
    echo -e "  Секретный путь: ${YELLOW}${secret}${NC}"
    echo -e "  IP этого VPS:   ${YELLOW}${ip}${NC}"
    echo ""
    echo -e "${GREEN}Теперь на РОССИЙСКОМ VPS запустите:${NC}"
    echo -e "  ${YELLOW}sudo ./setup-obfuscation.sh ru${NC}"
    echo -e "  (домен: ${DOMAIN}, секрет: ${secret})"
    echo ""
}

# =====================================================================
# РОЛЬ: RU (российский VPS — клиент wstunnel, разворот WG в туннель)
# =====================================================================
setup_ru() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   Обфускация: RU VPS (wstunnel client → WSS → Foreign)      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    [[ -f /etc/wireguard/wg0.conf ]] || err "Не найден /etc/wireguard/wg0.conf — сначала запустите setup-ru-vps.sh"

    read -rp "Домен зарубежного VPS: " DOMAIN
    [[ -z "$DOMAIN" ]] && err "Домен обязателен"

    read -rp "Секретный путь (с шага foreign): " SECRET
    [[ -z "$SECRET" ]] && err "Секрет обязателен"

    echo -e "${YELLOW}Если основной IP зарубежного VPS заблокирован — укажите резервный IP,${NC}"
    echo -e "${YELLOW}на который резолвить домен (иначе оставьте пусто = публичный DNS).${NC}"
    read -rp "IP для подключения (опционально): " CONNECT_IP

    local foreign_port="${FOREIGN_PORT:-51820}"
    read -rp "WireGuard порт зарубежного VPS [${foreign_port}]: " IN_FP
    foreign_port="${IN_FP:-$foreign_port}"

    echo "$SECRET" > "$SECRET_FILE"; chmod 600 "$SECRET_FILE"

    install_wstunnel

    # /etc/hosts: домен -> резервный IP (если задан)
    if [[ -n "$CONNECT_IP" ]]; then
        sed -i "/[[:space:]]${DOMAIN}\$/d" /etc/hosts
        sed -i "/^${CONNECT_IP}[[:space:]]/d" /etc/hosts
        echo "${CONNECT_IP} ${DOMAIN}" >> /etc/hosts
        log "/etc/hosts: ${DOMAIN} → ${CONNECT_IP}"
    fi

    # wstunnel client: локальный UDP:RU_LOCAL_PORT → WSS → WG(127.0.0.1:foreign_port) на Foreign
    cat > /etc/systemd/system/wstunnel-client.service << EOF
[Unit]
Description=wstunnel client (WG-over-WSS obfuscation to Foreign VPS)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/wstunnel client -L udp://127.0.0.1:${RU_LOCAL_PORT}:127.0.0.1:${foreign_port}?timeout_sec=0 --http-upgrade-path-prefix ${SECRET} wss://${DOMAIN}:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wstunnel-client >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet wstunnel-client || { journalctl -u wstunnel-client -n 15 --no-pager; err "wstunnel-client не запустился"; }
    log "wstunnel-client активен (127.0.0.1:${RU_LOCAL_PORT} → wss://${DOMAIN})"

    # Разворачиваем WG endpoint на локальный вход wstunnel
    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak.pre-obfs
    sed -i "s#^Endpoint = .*#Endpoint = 127.0.0.1:${RU_LOCAL_PORT}#" /etc/wireguard/wg0.conf

    # WG стартует после wstunnel-client
    mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
    cat > /etc/systemd/system/wg-quick@wg0.service.d/10-after-wstunnel.conf << EOF
[Unit]
After=wstunnel-client.service
Wants=wstunnel-client.service
EOF
    systemctl daemon-reload
    systemctl restart wg-quick@wg0

    # Проверка
    for i in 1 2 3; do ping -c1 -W3 -I wg0 1.1.1.1 >/dev/null 2>&1 || true; sleep 1; done
    sleep 2
    local hs now age
    hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    now=$(date +%s); age=$(( now - ${hs:-0} ))
    if [[ "${hs:-0}" -gt 0 && "$age" -lt 40 ]]; then
        log "Обфусцированный туннель РАБОТАЕТ (handshake ${age}s назад)"
        echo -e "  Exit IP через wg0: ${YELLOW}$(curl -4 -s --max-time 10 --interface wg0 ifconfig.me || echo '?')${NC}"
    else
        warn "Handshake не поднялся через wstunnel — откатываю на прямой WG"
        cp /etc/wireguard/wg0.conf.bak.pre-obfs /etc/wireguard/wg0.conf
        systemctl restart wg-quick@wg0
        err "Не удалось поднять туннель. Проверьте: journalctl -u wstunnel-client -n 30; и что домен резолвится в достижимый IP зарубежного VPS."
    fi

    echo ""
    log "Готово. На проводе RU→Foreign теперь только TLS/443 (проверка):"
    echo -e "  ${CYAN}tcpdump -ni any host <FOREIGN_IP> and udp port ${foreign_port}${NC}  # должно быть пусто"
    echo -e "  ${CYAN}wg show wg0${NC}  # endpoint = 127.0.0.1:${RU_LOCAL_PORT}"
    echo ""
    warn "Клиентские конфиги (VLESS/Reality) менять НЕ нужно."
}

# =====================================================================
# РОЛЬ: DISABLE (откат обфускации, возврат на прямой WG)
# =====================================================================
disable_obfuscation() {
    echo -e "${CYAN}Откат обфускации...${NC}"
    local did=0

    # RU-сторона
    if [[ -f /etc/systemd/system/wstunnel-client.service ]]; then
        systemctl disable --now wstunnel-client 2>/dev/null || true
        rm -f /etc/systemd/system/wstunnel-client.service
        rm -f /etc/systemd/system/wg-quick@wg0.service.d/10-after-wstunnel.conf
        if [[ -f /etc/wireguard/wg0.conf.bak.pre-obfs ]]; then
            cp /etc/wireguard/wg0.conf.bak.pre-obfs /etc/wireguard/wg0.conf
            log "wg0.conf восстановлен на прямой WG (из бэкапа)"
        else
            warn "Бэкап wg0.conf.bak.pre-obfs не найден — верните Endpoint вручную"
        fi
        systemctl daemon-reload
        systemctl restart wg-quick@wg0 2>/dev/null || true
        log "RU: wstunnel-client отключён"
        did=1
    fi

    # Foreign-сторона
    if [[ -f /etc/systemd/system/wstunnel-server.service ]]; then
        systemctl disable --now wstunnel-server 2>/dev/null || true
        rm -f /etc/systemd/system/wstunnel-server.service
        systemctl daemon-reload
        if [[ -f /etc/caddy/Caddyfile.bak.beforewstun ]]; then
            warn "Маршрут wstunnel в Caddyfile оставлен. Чтобы убрать: восстановите /etc/caddy/Caddyfile.bak.beforewstun и перезагрузите Caddy"
        fi
        log "Foreign: wstunnel-server отключён"
        did=1
    fi

    [[ "$did" -eq 0 ]] && warn "Обфускация не найдена на этом сервере"
    log "Откат завершён"
}

# =====================================================================
# MAIN
# =====================================================================
ROLE="${1:-}"
case "$ROLE" in
    foreign) setup_foreign ;;
    ru)      setup_ru ;;
    disable) disable_obfuscation ;;
    *)
        echo "Использование: sudo $0 <foreign|ru|disable>"
        echo ""
        echo "  foreign   — на зарубежном VPS: wstunnel server + Caddy (TLS)"
        echo "  ru        — на российском VPS: wstunnel client + разворот WG в туннель"
        echo "  disable   — откат обфускации, возврат на прямой WireGuard"
        exit 1
        ;;
esac
