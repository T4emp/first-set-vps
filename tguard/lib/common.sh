#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — утилиты: логирование, валидация, вспомогательные функции
# =============================================================================

# ─── Цвета (только если терминал) ───────────────────────────────────────────
if [[ -t 1 ]]; then
  C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"
  C_RED="\033[0;31m";   C_RESET="\033[0m"
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

# ─── Логирование ─────────────────────────────────────────────────────────────
log() {
  local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo -e "${C_GREEN}${MSG}${C_RESET}"
  echo "$MSG" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
  local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*"
  echo -e "${C_YELLOW}${MSG}${C_RESET}" >&2
  echo "$MSG" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
  local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*"
  echo -e "${C_RED}${MSG}${C_RESET}" >&2
  echo "$MSG" >> "$LOG_FILE" 2>/dev/null || true
  exit 1
}

# ─── Справка ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Использование: tguard.sh <команда> [параметры]

Команды:
  basic [geoXX] [provider]   Базовые правила + опционально GeoIP и/или провайдер
  whitelist [group]          Только белые списки (без connlimit), опционально группа из ip.list
  full                       Базовые + все списки и провайдеры из lists/ и providers/
  add <IP|CIDR> [group] [ports]  Добавить IP/CIDR в ip.list и сразу в iptables
  reload                     Повторить последний запуск (читает .last_flags)
  update-geo                 Скачать/обновить GeoIP-файлы
  update-providers           Скачать/обновить провайдеров из providers/urls.conf

Примеры:
  ./tguard.sh basic
  ./tguard.sh basic geoRU
  ./tguard.sh basic geoRU geoEU
  ./tguard.sh basic yandex
  ./tguard.sh basic geoRU yandex_cdn cloudflare
  ./tguard.sh whitelist
  ./tguard.sh whitelist usa
  ./tguard.sh full
  ./tguard.sh add 1.2.3.4/32
  ./tguard.sh add 1.2.3.4/32 usa
  ./tguard.sh add 1.2.3.4/32 usa 9443,8443
  ./tguard.sh update-geo
  ./tguard.sh update-providers

GeoIP коды:   RU, EU, US, DE, ...  (двухбуквенный ISO 3166-1 alpha-2)
Провайдеры:   имя файла из providers/ без расширения .list
              (пример: yandex → providers/yandex.list)
URL-провайдеры: заполни providers/urls.conf, затем ./tguard.sh update-providers
EOF
}

# ─── Сохранение флагов для reload ────────────────────────────────────────────
save_flags() {
  echo "$*" > "$STATE_FILE"
}

# ─── Валидация IP/CIDR ───────────────────────────────────────────────────────
# Поддерживает: 1.2.3.4  1.2.3.4/32  10.0.0.0/8
validate_cidr() {
  local ENTRY="$1"
  local IP PREFIX

  # Разбиваем на IP и префикс (префикс опционален)
  IP="${ENTRY%%/*}"
  PREFIX="${ENTRY##*/}"
  [[ "$ENTRY" != */* ]] && PREFIX="32"

  # Проверка формата IPv4
  local IFS='.'
  read -ra OCTETS <<< "$IP"
  if [[ ${#OCTETS[@]} -ne 4 ]]; then
    die "Неверный формат IP: $ENTRY"
  fi
  for OCT in "${OCTETS[@]}"; do
    if ! [[ "$OCT" =~ ^[0-9]+$ ]] || (( OCT < 0 || OCT > 255 )); then
      die "Неверный октет '$OCT' в IP: $ENTRY"
    fi
  done

  # Проверка префикса
  if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || (( PREFIX < 0 || PREFIX > 32 )); then
    die "Неверный префикс /$PREFIX в: $ENTRY"
  fi
}

# ─── Валидация порта ─────────────────────────────────────────────────────────
validate_port() {
  local PORT="$1"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "Неверный порт: $PORT (допустимо 1–65535)"
  fi
}

# ─── Проверка зависимостей ───────────────────────────────────────────────────
check_deps() {
  local MISSING=()
  for DEP in iptables ip6tables iptables-save ip6tables-save curl; do
    command -v "$DEP" &>/dev/null || MISSING+=("$DEP")
  done
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Не найдены утилиты: ${MISSING[*]}"
  fi
}

# ─── Определение внешнего интерфейса ─────────────────────────────────────────
get_iface() {
  ip route get 8.8.8.8 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# ─── Финализация: сохранение правил ──────────────────────────────────────────
finalize() {
  log "▶ Сохранение правил..."
  iptables-save  > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6
  systemctl enable netfilter-persistent >/dev/null 2>&1 || true
  netfilter-persistent save >/dev/null 2>&1 || true
  log "✓ Правила сохранены"
}

# ─── Горячее добавление одного IP без пересброса ─────────────────────────────
# Вставляем ПЕРЕД финальным DROP (последнее правило INPUT)
inject_ip_rule() {
  local ENTRY="$1"
  local LAST_NUM
  LAST_NUM=$(iptables -L INPUT --line-numbers -n | tail -n1 | awk '{print $1}')
  if [[ -z "$LAST_NUM" || "$LAST_NUM" == "num" ]]; then
    # Цепочка пуста — просто добавляем
    iptables -A INPUT -s "$ENTRY" -j ACCEPT
  else
    # Вставляем перед последним правилом (финальный DROP)
    iptables -I INPUT "$LAST_NUM" -s "$ENTRY" -j ACCEPT
  fi
  # Сохраняем сразу
  iptables-save > /etc/iptables/rules.v4
}
