#!/usr/bin/env bash
# =============================================================================
# lib/providers.sh — скачивание и парсинг URL-провайдеров
#
# Читает providers/urls.conf, скачивает каждый URL,
# определяет формат и сохраняет CIDR-список в providers/<имя>.list
# =============================================================================

PROVIDERS_URLS_CONF="$PROVIDERS_DIR/urls.conf"
PROVIDER_CONNECT_TIMEOUT=10
PROVIDER_MAX_TIME=30
PROVIDER_MIN_LINES=1

# ─── Определить формат и извлечь CIDR из контента ────────────────────────────
_parse_provider_content() {
  local CONTENT="$1"
  local RESULT=""

  # Пробуем JSON объект с полем "prefixes": {"prefixes": ["cidr", ...]}
  if echo "$CONTENT" | jq -e '.prefixes' >/dev/null 2>&1; then
    RESULT=$(echo "$CONTENT" | jq -r '.prefixes[]' 2>/dev/null)

  # Пробуем JSON массив: ["cidr", ...]
  elif echo "$CONTENT" | jq -e 'if type == "array" then . else error end' >/dev/null 2>&1; then
    RESULT=$(echo "$CONTENT" | jq -r '.[]' 2>/dev/null)

  # Plain text — берём строки похожие на CIDR, остальное игнорируем
  else
    RESULT=$(echo "$CONTENT" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' || true)
  fi

  echo "$RESULT"
}

# ─── Скачать и сохранить один провайдер ──────────────────────────────────────
_download_provider() {
  local NAME="$1"
  local URL="$2"
  local DEST="$PROVIDERS_DIR/${NAME}.list"
  local TMP="${DEST}.tmp"

  log "  ↓ provider [$NAME] — скачиваем $URL"

  # Проверяем доступность
  if ! curl -fsS --head \
        --connect-timeout "$PROVIDER_CONNECT_TIMEOUT" \
        --max-time "$PROVIDER_MAX_TIME" \
        "$URL" >/dev/null 2>&1; then
    warn "provider [$NAME]: сервер недоступен ($URL)"
    return 1
  fi

  # Скачиваем
  local CONTENT
  CONTENT=$(curl -fsSL \
    --connect-timeout "$PROVIDER_CONNECT_TIMEOUT" \
    --max-time "$PROVIDER_MAX_TIME" \
    "$URL" 2>/dev/null) || {
    warn "provider [$NAME]: ошибка загрузки"
    return 1
  }

  # Парсим
  local PARSED
  PARSED=$(_parse_provider_content "$CONTENT")

  if [[ -z "$PARSED" ]]; then
    warn "provider [$NAME]: не удалось извлечь CIDR из ответа"
    return 1
  fi

  # Проверяем минимальное кол-во записей
  local LINES
  LINES=$(echo "$PARSED" | grep -c '.' || true)
  if (( LINES < PROVIDER_MIN_LINES )); then
    warn "provider [$NAME]: слишком мало записей ($LINES) — отклонён"
    return 1
  fi

  # Проверяем что всё похоже на CIDR
  local BAD
  BAD=$(echo "$PARSED" | grep -Ev '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' | wc -l)
  if (( BAD > 0 )); then
    warn "provider [$NAME]: $BAD нераспознанных строк — отклонён"
    return 1
  fi

  echo "$PARSED" > "$TMP"
  mv "$TMP" "$DEST"
  log "  ✓ provider [$NAME]: $LINES подсетей сохранено → providers/${NAME}.list"
}

# ─── Обновить все провайдеры из urls.conf ────────────────────────────────────
update_all_url_providers() {
  if [[ ! -f "$PROVIDERS_URLS_CONF" ]]; then
    warn "providers/urls.conf не найден, пропуск"
    return
  fi

  local COUNT=0
  local ERRORS=0

  while IFS= read -r LINE; do
    # Убираем комментарии и пустые строки
    LINE="${LINE%%#*}"
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue

    # Парсим формат имя|url
    local NAME URL
    NAME="${LINE%%|*}"
    URL="${LINE#*|}"

    if [[ -z "$NAME" || -z "$URL" || "$NAME" == "$URL" ]]; then
      warn "urls.conf: неверный формат строки: '$LINE' (ожидается имя|url)"
      continue
    fi

    if _download_provider "$NAME" "$URL"; then
      (( COUNT++ )) || true
    else
      (( ERRORS++ )) || true
      # Если .list уже существует — используем старую версию
      [[ -f "$PROVIDERS_DIR/${NAME}.list" ]] && \
        warn "provider [$NAME]: используем старый кэш"
    fi

  done < "$PROVIDERS_URLS_CONF"

  log "✓ URL-провайдеры обновлены: $COUNT успешно, $ERRORS ошибок"
}
