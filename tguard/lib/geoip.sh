#!/usr/bin/env bash
# =============================================================================
# lib/geoip.sh — загрузка, валидация и применение GeoIP-диапазонов
#
# Источник: https://www.ipdeny.com/ipblocks/data/aggregated/<cc>-aggregated.zone
# Формат: один CIDR на строку, без заголовков.
# =============================================================================

GEOIP_DIR="$TGUARD_DIR/geoip"
GEOIP_BASE_URL="https://www.ipdeny.com/ipblocks/data/aggregated"
GEOIP_MAX_AGE_DAYS=30          # обновлять файл если старше N дней
GEOIP_MIN_LINES=10             # минимум строк в файле (защита от пустого ответа)
GEOIP_CONNECT_TIMEOUT=10       # таймаут подключения curl (сек)
GEOIP_MAX_TIME=60              # максимальное время загрузки (сек)

# ─── Получить путь к файлу по коду страны ────────────────────────────────────
_geo_file() {
  local CC="${1,,}"   # приводим к нижнему регистру
  echo "$GEOIP_DIR/${CC}.zone"
}

# ─── Проверить не устарел ли файл ────────────────────────────────────────────
_geo_is_fresh() {
  local FILE="$1"
  [[ -f "$FILE" ]] || return 1
  local MTIME NOW AGE
  MTIME=$(stat -c %Y "$FILE" 2>/dev/null) || return 1
  NOW=$(date +%s)
  AGE=$(( (NOW - MTIME) / 86400 ))
  (( AGE < GEOIP_MAX_AGE_DAYS ))
}

# ─── Скачать и проверить файл для одной страны ───────────────────────────────
_geo_download() {
  local CC="${1,,}"
  local URL="${GEOIP_BASE_URL}/${CC}-aggregated.zone"
  local DEST
  DEST=$(_geo_file "$CC")
  local TMP="${DEST}.tmp"

  log "  ↓ GeoIP [$CC] — скачиваем $URL"

  # Проверяем доступность сервера (HEAD-запрос)
  if ! curl -fsS --head \
        --connect-timeout "$GEOIP_CONNECT_TIMEOUT" \
        --max-time "$GEOIP_MAX_TIME" \
        "$URL" >/dev/null 2>&1; then
    warn "GeoIP [$CC]: сервер недоступен или файл не найден ($URL)"
    return 1
  fi

  # Скачиваем во временный файл
  if ! curl -fsSL \
        --connect-timeout "$GEOIP_CONNECT_TIMEOUT" \
        --max-time "$GEOIP_MAX_TIME" \
        -o "$TMP" \
        "$URL" 2>/dev/null; then
    warn "GeoIP [$CC]: ошибка загрузки"
    rm -f "$TMP"
    return 1
  fi

  # Проверяем что файл не пустой и содержит минимальное кол-во строк
  local LINES
  LINES=$(wc -l < "$TMP" 2>/dev/null || echo 0)
  if (( LINES < GEOIP_MIN_LINES )); then
    warn "GeoIP [$CC]: файл подозрительно мал ($LINES строк, минимум $GEOIP_MIN_LINES) — отклонён"
    rm -f "$TMP"
    return 1
  fi

  # Проверяем что файл содержит только валидные CIDR (первые 20 строк)
  local BAD_LINES
  BAD_LINES=$(head -20 "$TMP" | grep -Ev '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' | wc -l)
  if (( BAD_LINES > 0 )); then
    warn "GeoIP [$CC]: файл содержит нераспознанные строки ($BAD_LINES в первых 20) — отклонён"
    rm -f "$TMP"
    return 1
  fi

  mv "$TMP" "$DEST"
  log "  ✓ GeoIP [$CC]: $LINES подсетей сохранено"
  return 0
}

# ─── Обновить файл если устарел (или принудительно) ──────────────────────────
_geo_ensure() {
  local CC="${1,,}"
  local FORCE="${2:-0}"   # 1 = принудительное обновление
  local FILE
  FILE=$(_geo_file "$CC")

  mkdir -p "$GEOIP_DIR"

  if [[ "$FORCE" == "1" ]] || ! _geo_is_fresh "$FILE"; then
    _geo_download "$CC" || {
      # Если скачать не удалось — используем старый файл если он есть
      if [[ -f "$FILE" ]]; then
        warn "GeoIP [$CC]: используем устаревший кэш"
        return 0
      else
        warn "GeoIP [$CC]: нет кэша и загрузка не удалась — пропускаем"
        return 1
      fi
    }
  else
    log "  GeoIP [${CC^^}]: кэш актуален (моложе $GEOIP_MAX_AGE_DAYS дней)"
  fi
}

# ─── Применить GeoIP для одной страны ────────────────────────────────────────
apply_geoip() {
  local CC="${1^^}"   # для логов в верхнем регистре
  local CC_LOWER="${CC,,}"

  _geo_ensure "$CC_LOWER" || return

  local FILE
  FILE=$(_geo_file "$CC_LOWER")
  local COUNT=0

  while IFS= read -r CIDR; do
    CIDR="${CIDR// /}"
    [[ -z "$CIDR" ]] && continue
    [[ "$CIDR" =~ ^# ]] && continue
    iptables -A INPUT -s "$CIDR" -j ACCEPT
    (( COUNT++ )) || true
  done < "$FILE"

  log "  + GeoIP [$CC]: добавлено $COUNT подсетей"
}

# ─── Применить все .zone файлы из geoip/ ─────────────────────────────────────
apply_all_geoip() {
  if [[ ! -d "$GEOIP_DIR" ]]; then
    warn "Директория geoip/ не найдена, пропуск"
    return
  fi

  local FOUND=0
  for FILE in "$GEOIP_DIR"/*.zone; do
    [[ -f "$FILE" ]] || continue
    local CC
    CC=$(basename "$FILE" .zone)
    apply_geoip "$CC"
    (( FOUND++ )) || true
  done

  [[ $FOUND -eq 0 ]] && warn "В geoip/ нет ни одного .zone файла"
}

# ─── Принудительное обновление всех существующих .zone файлов ────────────────
update_all_geoip() {
  if [[ ! -d "$GEOIP_DIR" ]]; then
    warn "Директория geoip/ не найдена — нечего обновлять"
    return
  fi

  local FOUND=0
  for FILE in "$GEOIP_DIR"/*.zone; do
    [[ -f "$FILE" ]] || continue
    local CC
    CC=$(basename "$FILE" .zone)
    _geo_ensure "$CC" "1"    # force=1
    (( FOUND++ )) || true
  done

  if [[ $FOUND -eq 0 ]]; then
    warn "Нет закэшированных .zone файлов. Используй 'basic geoRU' чтобы скачать."
  fi
}
