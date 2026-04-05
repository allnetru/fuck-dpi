#!/usr/bin/env bash
set -u

trap 'echo -e "\n\033[0;31m[x]\033[0m Прервано."; exit 130' INT TERM

#===============================================================================
# find-reality-domain.sh — Поиск домена для маскировки Reality
#
# Ищет сайты с TLS на том же AS (автономной системе), что и текущий VPS.
# Такие домены идеальны для Reality — DPI не заметит несовпадения IP↔SNI.
#
# Три метода (от быстрого к медленному):
#   1. Reverse DNS (PTR) — мгновенный, без TCP-подключений
#   2. Certificate Transparency (crt.sh) — один HTTP-запрос
#   3. Прямое сканирование — TCP + TLS, последний fallback
#
# Запускать на RU VPS:
#   chmod +x find-reality-domain.sh
#   ./find-reality-domain.sh
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
# 0. ЗАВИСИМОСТИ
# =====================================================================

for cmd in curl dig whois openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        log "Устанавливаю $cmd..."
        if [[ -f /etc/debian_version ]]; then
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq curl dnsutils whois openssl 2>/dev/null
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y curl bind-utils whois openssl 2>/dev/null
        fi
    fi
done

for cmd in curl dig whois openssl; do
    command -v "$cmd" &>/dev/null || err "$cmd не найден, установите вручную"
done

# =====================================================================
# 1. ОПРЕДЕЛЯЕМ СВОЙ IP И AS
# =====================================================================

MY_IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 api.ipify.org || echo "")
[[ -z "$MY_IP" ]] && err "Не удалось определить внешний IP"
log "IP этого сервера: $MY_IP"

# Получаем AS
# Метод 1: Team Cymru DNS — самый надёжный, через dig
REVERSED_IP=$(echo "$MY_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
CYMRU_RESULT=$(dig +short TXT "${REVERSED_IP}.origin.asn.cymru.com" 2>/dev/null | tr -d '"' || true)
AS_INFO=""
if [[ -n "$CYMRU_RESULT" ]]; then
    AS_INFO="AS$(echo "$CYMRU_RESULT" | awk -F'|' '{gsub(/^ +| +$/, "", $1); print $1}')"
    log "AS (Team Cymru DNS): $AS_INFO"
fi

# Метод 2: whois напрямую по IP
if [[ -z "$AS_INFO" || "$AS_INFO" == "AS" ]]; then
    AS_INFO=$(whois "$MY_IP" 2>/dev/null | grep -iE "^origin:" | head -1 | awk '{print $NF}' || true)
    [[ -n "$AS_INFO" ]] && log "AS (whois): $AS_INFO"
fi

# Метод 3: RADB (fallback)
if [[ -z "$AS_INFO" ]]; then
    AS_INFO=$(whois -h whois.radb.net "$MY_IP" 2>/dev/null | grep -i "^origin:" | head -1 | awk '{print $NF}' || true)
    [[ -n "$AS_INFO" ]] && log "AS (RADB): $AS_INFO"
fi

[[ -z "$AS_INFO" ]] && err "Не удалось определить AS для $MY_IP"

# Имя AS и описание провайдера
AS_NUM=$(echo "$AS_INFO" | sed 's/^AS//')
AS_NAME=$(dig +short TXT "AS${AS_NUM}.asn.cymru.com" 2>/dev/null | tr -d '"' | awk -F'|' '{gsub(/^ +| +$/, "", $NF); print $NF}' || true)
if [[ -z "$AS_NAME" ]]; then
    AS_NAME=$(whois "$MY_IP" 2>/dev/null | grep -iE "^netname:" | head -1 | awk '{print $NF}' || true)
fi
WHOIS_DESCR=$(whois "$MY_IP" 2>/dev/null | grep -iE "^(descr|org-name|OrgName):" | head -1 | sed 's/^[^:]*:\s*//' | xargs 2>/dev/null || true)
[[ -n "$AS_NAME" ]] && log "Провайдер: $AS_NAME"
[[ -n "$WHOIS_DESCR" ]] && log "Описание: $WHOIS_DESCR"

# =====================================================================
# 2. ПОЛУЧАЕМ IP-ДИАПАЗОНЫ В ЭТОМ AS
# =====================================================================
log "Ищу IP-диапазоны в $AS_INFO..."

PREFIXES=$(whois -h whois.radb.net -- "-i origin $AS_INFO" 2>/dev/null | grep "^route:" | awk '{print $2}' | sort -u || true)

if [[ -z "$PREFIXES" ]]; then
    warn "RADB не вернул маршруты, пробую whois напрямую..."
    PREFIXES=$(whois "$MY_IP" 2>/dev/null | grep -iE "^(inetnum|CIDR|route):" | head -5 | awk '{print $2}' || true)
fi

if [[ -z "$PREFIXES" ]]; then
    warn "Не нашёл диапазонов через whois, сканирую свою /24"
    BASE=$(echo "$MY_IP" | cut -d'.' -f1-3)
    PREFIXES="${BASE}.0/24"
fi

PREFIX_COUNT=$(echo "$PREFIXES" | grep -c . || true)
log "Найдено диапазонов: $PREFIX_COUNT"

# =====================================================================
# Функция: проверить домен на пригодность для Reality
# Аргументы: домен [ip]
# Возвращает строку "домен|ip|статус" или пустую
# =====================================================================
check_domain() {
    local DOMAIN="$1"
    local IP="${2:-}"

    # Пропускаем wildcard, пустые, IP-like
    [[ -z "$DOMAIN" ]] && return
    [[ "$DOMAIN" == \** ]] && return
    [[ "$DOMAIN" =~ ^[0-9.]+$ ]] && return

    # Уже проверяли?
    for SEEN in "${SEEN_DOMAINS[@]+"${SEEN_DOMAINS[@]}"}"; do
        [[ "$SEEN" == "$DOMAIN" ]] && return
    done
    SEEN_DOMAINS+=("$DOMAIN")

    # Резолвим если IP не передан
    if [[ -z "$IP" ]]; then
        IP=$(dig +short "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || IP=""
        [[ -z "$IP" ]] && return
    fi

    # Пропускаем свой IP
    [[ "$IP" == "$MY_IP" ]] && return

    # Порт 443 открыт?
    if ! timeout 2 bash -c "echo >/dev/tcp/$IP/443" 2>/dev/null; then
        return
    fi

    # TLS работает?
    local CERT_CN
    CERT_CN=$(echo | timeout 3 openssl s_client -connect "$IP:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null) || CERT_CN=""
    [[ -z "$CERT_CN" ]] && return

    # HTTP отвечает?
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "https://$DOMAIN/" -k 2>/dev/null) || HTTP_CODE="000"
    [[ ! "$HTTP_CODE" =~ ^(200|301|302|403)$ ]] && return

    # TLS 1.3?
    local TLS_VER TLS13=""
    TLS_VER=$(echo | timeout 3 openssl s_client -connect "$IP:443" -servername "$DOMAIN" -tls1_3 2>/dev/null | grep "Protocol" | awk '{print $NF}') || TLS_VER=""
    [[ "$TLS_VER" == "TLSv1.3" ]] && TLS13=" TLS1.3"

    echo "$DOMAIN|$IP|HTTP $HTTP_CODE$TLS13"
}

CANDIDATES=()
SEEN_DOMAINS=()

# =====================================================================
# 3. МЕТОД 1: Reverse DNS (PTR) — быстрый
# =====================================================================
echo ""
echo -e "${CYAN}[Метод 1] Reverse DNS — ищу домены по PTR-записям...${NC}"

PTR_FOUND=0
PTR_CHECKED=0
MAX_PTR=500

# Берём случайные подсети
if command -v shuf &>/dev/null; then
    SHUFFLED=$(echo "$PREFIXES" | shuf | head -80)
else
    SHUFFLED=$(echo "$PREFIXES" | sort -R | head -80)
fi

for PREFIX in $SHUFFLED; do
    [[ ${#CANDIDATES[@]} -ge 10 ]] && break
    [[ $PTR_CHECKED -ge $MAX_PTR ]] && break

    BASE=$(echo "$PREFIX" | cut -d'/' -f1 | cut -d'.' -f1-3)

    # PTR для нескольких IP из подсети
    if command -v shuf &>/dev/null; then
        OCTETS=$(shuf -i 1-254 -n 6)
    else
        OCTETS=$(awk 'BEGIN{srand(); for(i=0;i<6;i++) print int(rand()*254)+1}')
    fi

    for LAST_OCTET in $OCTETS; do
        [[ ${#CANDIDATES[@]} -ge 10 ]] && break
        [[ $PTR_CHECKED -ge $MAX_PTR ]] && break

        IP="${BASE}.${LAST_OCTET}"
        PTR_CHECKED=$((PTR_CHECKED + 1))

        printf "\r  PTR проверено: %d/%d  Найдено: %d  Подтверждено: %d  " \
            "$PTR_CHECKED" "$MAX_PTR" "$PTR_FOUND" "${#CANDIDATES[@]}"

        [[ "$IP" == "$MY_IP" ]] && continue

        # PTR-запрос — мгновенный, без TCP
        PTR=$(dig +short -x "$IP" 2>/dev/null | head -1 | sed 's/\.$//' || true)
        [[ -z "$PTR" ]] && continue

        PTR_FOUND=$((PTR_FOUND + 1))

        # Пропускаем явно автогенерённые PTR (IP в имени)
        # Например: 94-241-141-229.timeweb.cloud или ip-94-241-141-229.example.com
        IP_DASHED=$(echo "$IP" | tr '.' '-')
        [[ "$PTR" == *"$IP_DASHED"* ]] && continue
        IP_DOTTED="$IP"
        [[ "$PTR" == *"$IP_DOTTED"* ]] && continue

        # Проверяем домен
        RESULT=$(check_domain "$PTR" "$IP")
        if [[ -n "$RESULT" ]]; then
            CANDIDATES+=("$RESULT")
            DOMAIN=$(echo "$RESULT" | cut -d'|' -f1)
            STATUS=$(echo "$RESULT" | cut -d'|' -f3)
            printf "\r%-70s\n" ""
            echo -e "  ${GREEN}[+]${NC} $DOMAIN ($IP) — $STATUS"
        fi
    done
done

printf "\r%-70s\n" ""
log "PTR: проверено $PTR_CHECKED IP, нашёл $PTR_FOUND PTR-записей, подтверждено ${#CANDIDATES[@]}"

# =====================================================================
# 4. МЕТОД 2: Certificate Transparency (crt.sh) — если PTR мало нашёл
# =====================================================================
if [[ ${#CANDIDATES[@]} -lt 5 ]]; then
    echo ""
    echo -e "${CYAN}[Метод 2] Certificate Transparency (crt.sh)...${NC}"

    # Определяем домен хостера из нескольких источников
    HOSTER_DOMAIN=""

    # 1) Из AS_NAME — пробуем разные TLD
    if [[ -n "$AS_NAME" ]]; then
        NAME_LOWER="${AS_NAME,,}"
        for TRY in "${NAME_LOWER}.ru" "${NAME_LOWER}.com" "${NAME_LOWER}.cloud" "${NAME_LOWER}.net"; do
            RESOLVED=$(dig +short "$TRY" 2>/dev/null | head -1 || true)
            if [[ -n "$RESOLVED" ]]; then
                HOSTER_DOMAIN="$TRY"
                break
            fi
        done
    fi

    # 2) Из whois descr/org — ищем слова, похожие на домен
    if [[ -z "$HOSTER_DOMAIN" && -n "$WHOIS_DESCR" ]]; then
        # Извлекаем слова, проверяем как домены
        for WORD in $WHOIS_DESCR; do
            WORD_LOWER="${WORD,,}"
            # Пропускаем короткие и общие слова
            [[ ${#WORD_LOWER} -lt 3 ]] && continue
            for TLD in ".ru" ".com" ".cloud" ".net"; do
                TRY="${WORD_LOWER}${TLD}"
                RESOLVED=$(dig +short "$TRY" 2>/dev/null | head -1 || true)
                if [[ -n "$RESOLVED" ]]; then
                    HOSTER_DOMAIN="$TRY"
                    break 2
                fi
            done
        done
    fi

    # 3) Из PTR-записей — если были найдены, берём корневой домен
    if [[ -z "$HOSTER_DOMAIN" ]]; then
        SAMPLE_PTR=$(dig +short -x "$MY_IP" 2>/dev/null | head -1 | sed 's/\.$//' || true)
        if [[ -n "$SAMPLE_PTR" ]]; then
            # Берём последние 2 части: foo.bar.timeweb.cloud -> timeweb.cloud
            HOSTER_DOMAIN=$(echo "$SAMPLE_PTR" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF}')
            # Проверяем что резолвится
            RESOLVED=$(dig +short "$HOSTER_DOMAIN" 2>/dev/null | head -1 || true)
            [[ -z "$RESOLVED" ]] && HOSTER_DOMAIN=""
        fi
    fi

    CRT_DOMAINS=""

    # crt.sh по домену хостера
    if [[ -n "$HOSTER_DOMAIN" ]]; then
        log "Ищу сертификаты для *.$HOSTER_DOMAIN..."
        CRT_DOMAINS=$(curl -s --max-time 15 "https://crt.sh/?q=%25.${HOSTER_DOMAIN}&output=json" 2>/dev/null \
            | grep -oP '"common_name"\s*:\s*"\K[^"]+' 2>/dev/null \
            | grep -v '\*' \
            | sort -u \
            | head -50 || true)
    fi

    # Сканируем соседей по /24 — все 254 IP
    MY_BASE=$(echo "$MY_IP" | cut -d'.' -f1-3)
    log "Сканирую соседей $MY_BASE.* на порту 443..."
    NEIGHBOR_FOUND=0
    for OCTET in $(seq 1 254); do
        NEIGHBOR="${MY_BASE}.${OCTET}"
        [[ "$NEIGHBOR" == "$MY_IP" ]] && continue

        printf "\r  Соседи: %d/254  Найдено: %d  " "$OCTET" "$NEIGHBOR_FOUND"

        # Быстрая проверка порта
        if ! timeout 1 bash -c "echo >/dev/tcp/$NEIGHBOR/443" 2>/dev/null; then
            continue
        fi

        CERT_CN=$(echo | timeout 3 openssl s_client -connect "$NEIGHBOR:443" -servername "" 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed 's/.*CN\s*=\s*//' | sed 's/,.*//' || true)
        if [[ -n "$CERT_CN" && "$CERT_CN" != \** ]]; then
            CRT_DOMAINS="${CRT_DOMAINS}"$'\n'"${CERT_CN}"
            NEIGHBOR_FOUND=$((NEIGHBOR_FOUND + 1))
        fi
    done
    printf "\r%-70s\n" ""
    CRT_DOMAINS=$(echo "$CRT_DOMAINS" | sort -u | grep . || true)

    CRT_COUNT=$(echo "$CRT_DOMAINS" | grep -c . || true)
    log "Найдено доменов из CT/сертификатов: $CRT_COUNT"

    CRT_VERIFIED=0
    for DOMAIN in $CRT_DOMAINS; do
        [[ ${#CANDIDATES[@]} -ge 10 ]] && break
        CRT_VERIFIED=$((CRT_VERIFIED + 1))

        printf "\r  Проверяю: %d/%d  Подтверждено: %d  " \
            "$CRT_VERIFIED" "$CRT_COUNT" "${#CANDIDATES[@]}"

        RESULT=$(check_domain "$DOMAIN")
        if [[ -n "$RESULT" ]]; then
            CANDIDATES+=("$RESULT")
            D=$(echo "$RESULT" | cut -d'|' -f1)
            S=$(echo "$RESULT" | cut -d'|' -f3)
            printf "\r%-70s\n" ""
            echo -e "  ${GREEN}[+]${NC} $D — $S"
        fi
    done
    printf "\r%-70s\n" ""
fi

# =====================================================================
# 5. МЕТОД 3: Прямое сканирование — последний fallback
# =====================================================================
if [[ ${#CANDIDATES[@]} -lt 3 ]]; then
    echo ""
    echo -e "${CYAN}[Метод 3] Прямое сканирование портов (fallback)...${NC}"

    SCAN_CHECKED=0
    SCAN_OPEN=0
    MAX_SCAN=100

    if command -v shuf &>/dev/null; then
        SCAN_PREFIXES=$(echo "$PREFIXES" | shuf | head -40)
    else
        SCAN_PREFIXES=$(echo "$PREFIXES" | sort -R | head -40)
    fi

    for PREFIX in $SCAN_PREFIXES; do
        [[ ${#CANDIDATES[@]} -ge 10 ]] && break
        [[ $SCAN_CHECKED -ge $MAX_SCAN ]] && break

        BASE=$(echo "$PREFIX" | cut -d'/' -f1 | cut -d'.' -f1-3)

        if command -v shuf &>/dev/null; then
            OCTETS=$(shuf -i 1-254 -n 3)
        else
            OCTETS=$(awk 'BEGIN{srand(); for(i=0;i<3;i++) print int(rand()*254)+1}')
        fi

        for LAST_OCTET in $OCTETS; do
            [[ ${#CANDIDATES[@]} -ge 10 ]] && break
            [[ $SCAN_CHECKED -ge $MAX_SCAN ]] && break

            IP="${BASE}.${LAST_OCTET}"
            SCAN_CHECKED=$((SCAN_CHECKED + 1))

            printf "\r  Сканирование: %d/%d  Порт 443: %d  Подтверждено: %d  " \
                "$SCAN_CHECKED" "$MAX_SCAN" "$SCAN_OPEN" "${#CANDIDATES[@]}"

            [[ "$IP" == "$MY_IP" ]] && continue

            if ! timeout 2 bash -c "echo >/dev/tcp/$IP/443" 2>/dev/null; then
                continue
            fi
            SCAN_OPEN=$((SCAN_OPEN + 1))

            # Берём домен из сертификата
            CERT_INFO=$(echo | timeout 3 openssl s_client -connect "$IP:443" -servername "" 2>/dev/null \
                | openssl x509 -noout -text 2>/dev/null) || CERT_INFO=""
            [[ -z "$CERT_INFO" ]] && continue

            CN=$(echo "$CERT_INFO" | grep "Subject:" | sed 's/.*CN\s*=\s*//' | sed 's/,.*//' | xargs 2>/dev/null) || CN=""
            SANS=$(echo "$CERT_INFO" | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/DNS://g' | tr ',' '\n' | xargs 2>/dev/null) || SANS=""

            for D in $CN $SANS; do
                RESULT=$(check_domain "$D" "$IP")
                if [[ -n "$RESULT" ]]; then
                    CANDIDATES+=("$RESULT")
                    DNAME=$(echo "$RESULT" | cut -d'|' -f1)
                    STAT=$(echo "$RESULT" | cut -d'|' -f3)
                    printf "\r%-70s\n" ""
                    echo -e "  ${GREEN}[+]${NC} $DNAME ($IP) — $STAT"
                    break
                fi
            done
        done
    done
    printf "\r%-70s\n" ""
fi

# =====================================================================
# 6. РЕЗУЛЬТАТЫ
# =====================================================================
echo ""

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    warn "Не нашёл подходящих доменов в $AS_INFO (${AS_NAME:-unknown})"
    echo ""
    echo "Попробуйте:"
    echo "  1. Запустить скрипт ещё раз (сканирует случайные IP)"
    echo "  2. Использовать www.google.com или www.microsoft.com как fallback"
    echo "  3. Вручную найти сайт на том же хостинге"
    exit 0
fi

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Найденные домены в $AS_INFO (${AS_NAME:-unknown})${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
printf "  ${YELLOW}%-35s %-18s %s${NC}\n" "ДОМЕН" "IP" "СТАТУС"
echo "  ---------------------------------------------------------------"

BEST_DOMAIN=""
for ENTRY in "${CANDIDATES[@]}"; do
    DOMAIN=$(echo "$ENTRY" | cut -d'|' -f1)
    IP=$(echo "$ENTRY" | cut -d'|' -f2)
    STATUS=$(echo "$ENTRY" | cut -d'|' -f3)
    printf "  %-35s %-18s %s\n" "$DOMAIN" "$IP" "$STATUS"
    if [[ -z "$BEST_DOMAIN" ]]; then
        BEST_DOMAIN="$DOMAIN"
    elif [[ "$STATUS" == *"TLS1.3"* ]] && [[ ! "$BEST_DOMAIN" == *"TLS1.3"* ]]; then
        BEST_DOMAIN="$DOMAIN"
    fi
done

echo ""
echo -e "${GREEN}Рекомендация:${NC} ${YELLOW}${BEST_DOMAIN}${NC}"
echo ""
echo "Используйте это значение при запуске setup-ru-vps.sh:"
echo -e "  ${CYAN}Сайт для маскировки Reality:${NC} $BEST_DOMAIN"
echo ""
echo -e "${YELLOW}Совет:${NC} домены с TLS 1.3 предпочтительнее — Reality лучше"
echo "маскируется под современный TLS."
echo ""
