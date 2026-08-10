#!/usr/bin/env bash
# =============================================================================
# setup-cron.sh — установка cron-задач для tguard
#
# Запусти один раз после первоначальной настройки:
#   ./setup-cron.sh
#
# Что устанавливает:
#   1. Ежемесячное обновление GeoIP-файлов (1-го числа в 03:00)
#   2. Восстановление правил после перезагрузки сервера (через @reboot)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TGUARD="$SCRIPT_DIR/tguard.sh"
LOG_GEO="/var/log/tguard-geo-update.log"
LOG_REBOOT="/var/log/tguard-reboot.log"

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root" >&2
  exit 1
fi

# ─── Убеждаемся что скрипт существует и исполняемый ─────────────────────────
if [[ ! -x "$TGUARD" ]]; then
  echo "Делаю $TGUARD исполняемым..."
  chmod +x "$TGUARD"
fi

# ─── Функция: добавить задачу в crontab (без дублей) ─────────────────────────
add_cron() {
  local MARKER="$1"
  local ENTRY="$2"
  (
    crontab -l 2>/dev/null | grep -v "$MARKER" || true
    echo "$ENTRY  # $MARKER"
  ) | crontab -
  echo "✓ Cron добавлен: $ENTRY"
}

# ─── 1. Ежемесячное обновление GeoIP ─────────────────────────────────────────
add_cron \
  "tguard-geo-update" \
  "0 3 1 * * $TGUARD update-geo >> $LOG_GEO 2>&1"

# ─── 2. Ежемесячное обновление URL-провайдеров ───────────────────────────────
LOG_PROVIDERS="/var/log/tguard-providers-update.log"
add_cron \
  "tguard-providers-update" \
  "0 4 1 * * $TGUARD update-providers >> $LOG_PROVIDERS 2>&1"

# ─── 3. Восстановление правил после перезагрузки ─────────────────────────────
# netfilter-persistent сам восстанавливает правила при старте,
# но если .last_flags существует — делаем полный reload для актуального состояния
add_cron \
  "tguard-reboot" \
  "@reboot sleep 10 && $TGUARD reload >> $LOG_REBOOT 2>&1"

echo ""
echo "Текущий crontab:"
crontab -l
