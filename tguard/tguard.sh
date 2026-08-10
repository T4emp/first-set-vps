#!/usr/bin/env bash
# =============================================================================
# tguard.sh — точка входа
# Расположение: /root/tguard/tguard.sh
#
# Использование:
#   ./tguard.sh basic                  # только базовые правила (core.sh)
#   ./tguard.sh basic geoRU            # базовые + GeoIP Россия
#   ./tguard.sh basic geoRU geoEU      # базовые + несколько GeoIP
#   ./tguard.sh basic yandex           # базовые + провайдер из providers/
#   ./tguard.sh whitelist              # только белые списки (без core)
#   ./tguard.sh full                   # basic + все списки из lists/ и providers/
#   ./tguard.sh add 1.2.3.4/32         # добавить IP/CIDR в ip.list + сразу в iptables
#   ./tguard.sh reload                 # полный пересброс с текущим набором флагов
#   ./tguard.sh update-geo             # принудительное обновление GeoIP-файлов
#   ./tguard.sh update-providers       # скачать/обновить провайдеров из urls.conf
# =============================================================================

set -euo pipefail

# ─── Пути ───────────────────────────────────────────────────────────────────
TGUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TGUARD_DIR/lib"
LISTS_DIR="$TGUARD_DIR/lists"
PROVIDERS_DIR="$TGUARD_DIR/providers"
STATE_FILE="$TGUARD_DIR/.last_flags"   # сохраняем флаги для reload
LOG_FILE="/var/log/tguard.log"

# ─── Подключение библиотек ───────────────────────────────────────────────────
source "$LIB_DIR/common.sh"
source "$LIB_DIR/core.sh"
source "$LIB_DIR/whitelist.sh"
source "$LIB_DIR/geoip.sh"
source "$LIB_DIR/providers.sh"

# ─── Загрузка конфига ────────────────────────────────────────────────────────
CONF_FILE="$TGUARD_DIR/tguard.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  die "Конфиг не найден: $CONF_FILE\nСкопируй tguard.conf.example и заполни."
fi
# shellcheck source=../tguard.conf
source "$CONF_FILE"

# ─── Root-проверка ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  die "Скрипт должен запускаться от root"
fi

# ─── Парсинг аргументов ──────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

CMD="$1"
shift || true

case "$CMD" in

  # ── basic [geoXX] [provider] ──────────────────────────────────────────────
  basic)
    log "▶ Режим: basic $*"
    save_flags "basic $*"
    run_core
    apply_extra_ports
    if [[ $# -gt 0 ]]; then
      for ARG in "$@"; do
        case "$ARG" in
          geo*)
            COUNTRY="${ARG#geo}"
            apply_geoip "$COUNTRY"
            ;;
          *)
            apply_provider "$ARG"
            ;;
        esac
      done
    fi
    finalize
    ;;

  # ── whitelist [group] ────────────────────────────────────────────────────
  whitelist)
    GROUP="${1:-}"
    log "▶ Режим: whitelist${GROUP:+ [$GROUP]}"
    save_flags "whitelist${GROUP:+ $GROUP}"
    run_core_whitelist_mode
    apply_extra_ports
    apply_ip_list "$GROUP"
    finalize
    ;;

  # ── full ──────────────────────────────────────────────────────────────────
  full)
    log "▶ Режим: full"
    save_flags "full"
    run_core
    apply_extra_ports
    apply_ip_list
    apply_all_providers
    apply_all_geoip
    finalize
    ;;

  # ── add <IP|CIDR> [group] [ports] ────────────────────────────────────────
  # Примеры:
  #   ./tguard.sh add 1.2.3.4/32
  #   ./tguard.sh add 1.2.3.4/32 usa
  #   ./tguard.sh add 1.2.3.4/32 usa 9443,8443
  add)
    if [[ $# -eq 0 ]]; then
      die "Укажи IP или CIDR: ./tguard.sh add 1.2.3.4/32 [group] [ports]"
    fi
    ENTRY="$1"
    ADD_GROUP="${2:-}"
    ADD_PORTS="${3:-}"
    validate_cidr "$ENTRY"
    add_ip_to_list "$ENTRY" "$ADD_GROUP" "$ADD_PORTS"
    inject_ip_rule "$ENTRY"
    log "✓ Добавлен: $ENTRY${ADD_GROUP:+ [группа: $ADD_GROUP]}${ADD_PORTS:+ [порты: $ADD_PORTS]}"
    ;;

  # ── reload ────────────────────────────────────────────────────────────────
  reload)
    if [[ ! -f "$STATE_FILE" ]]; then
      die "Нет сохранённых флагов. Запусти сначала basic/whitelist/full."
    fi
    SAVED=$(cat "$STATE_FILE")
    log "▶ Reload: $SAVED"
    # shellcheck disable=SC2086
    exec "$TGUARD_DIR/tguard.sh" $SAVED
    ;;

  # ── update-geo ────────────────────────────────────────────────────────────
  update-geo)
    log "▶ Обновление GeoIP-файлов..."
    update_all_geoip
    log "✓ GeoIP обновлён"
    ;;

  # ── update-providers ──────────────────────────────────────────────────────
  update-providers)
    log "▶ Обновление URL-провайдеров..."
    update_all_url_providers
    ;;

  *)
    usage
    die "Неизвестная команда: $CMD"
    ;;
esac
