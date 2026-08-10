#!/usr/bin/env bash
# =============================================================================
# lib/whitelist.sh — применение ip.list и провайдерских списков
#
# Формат ip.list:
#   # комментарий        ← игнорируется
#   ##group_name         ← начало группы
#   1.2.3.4/32           ← IP/CIDR, открывает 443 (по умолчанию)
#   1.2.3.4/32 9443,8443 ← IP/CIDR + доп. порты (443 тоже открывается)
#
# Пример:
#   # основные серверы
#   ##ge
#   31.177.111.14/32
#   ##usa
#   31.177.134.14/32 9443,10443
# =============================================================================

DEFAULT_WHITELIST_PORT=443

# ─── Применить одну запись IP [порты] в iptables ─────────────────────────────
_apply_ip_entry() {
  local IP="$1"
  local EXTRA_RAW="${2:-}"

  validate_cidr "$IP"

  # Всегда открываем дефолтный порт
  iptables -A INPUT -s "$IP" -p tcp --dport "$DEFAULT_WHITELIST_PORT" -j ACCEPT
  iptables -A INPUT -s "$IP" -p udp --dport "$DEFAULT_WHITELIST_PORT" -j ACCEPT

  # Дополнительные порты если указаны
  if [[ -n "$EXTRA_RAW" ]]; then
    IFS=',' read -ra PORTS <<< "$EXTRA_RAW"
    for PORT in "${PORTS[@]}"; do
      PORT="${PORT// /}"
      [[ -z "$PORT" ]] && continue
      validate_port "$PORT"
      iptables -A INPUT -s "$IP" -p tcp --dport "$PORT" -j ACCEPT
      iptables -A INPUT -s "$IP" -p udp --dport "$PORT" -j ACCEPT
    done
  fi
}

# ─── Разобрать строку файла на IP и порты ────────────────────────────────────
_parse_ip_line() {
  local LINE="$1"
  PARSED_IP=""
  PARSED_PORTS=""
  read -r PARSED_IP PARSED_PORTS <<< "$LINE"
  PARSED_PORTS="${PARSED_PORTS// /}"
}

# ─── Применить ip.list — всю или конкретную группу ───────────────────────────
apply_ip_list() {
  local TARGET_GROUP="${1:-}"
  local LIST="$LISTS_DIR/ip.list"

  if [[ ! -f "$LIST" ]]; then
    warn "lists/ip.list не найден, пропуск"
    return
  fi

  local CURRENT_GROUP=""
  local IN_TARGET=0
  local COUNT=0

  # Если группа не указана — берём всё
  [[ -z "$TARGET_GROUP" ]] && IN_TARGET=1

  while IFS= read -r RAW_LINE; do
    # Trim
    local LINE="${RAW_LINE#"${RAW_LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"

    # Пустая строка
    [[ -z "$LINE" ]] && continue

    # ## — заголовок группы
    if [[ "$LINE" == "##"* ]]; then
      CURRENT_GROUP="${LINE:2}"
      CURRENT_GROUP="${CURRENT_GROUP# }"

      if [[ -z "$TARGET_GROUP" ]]; then
        IN_TARGET=1
        log "  группа: $CURRENT_GROUP"
      elif [[ "$CURRENT_GROUP" == "$TARGET_GROUP" ]]; then
        IN_TARGET=1
        log "  группа: $CURRENT_GROUP"
      else
        IN_TARGET=0
      fi
      continue
    fi

    # # — обычный комментарий, пропускаем
    [[ "$LINE" == "#"* ]] && continue

    # Обычная строка с IP
    [[ "$IN_TARGET" -eq 0 ]] && continue

    _parse_ip_line "$LINE"
    [[ -z "$PARSED_IP" ]] && continue

    _apply_ip_entry "$PARSED_IP" "$PARSED_PORTS"
    (( COUNT++ )) || true
  done < "$LIST"

  if [[ $COUNT -eq 0 && -n "$TARGET_GROUP" ]]; then
    warn "ip.list: группа '##$TARGET_GROUP' не найдена или пуста"
  else
    log "  + ip.list${TARGET_GROUP:+ [##$TARGET_GROUP]}: добавлено $COUNT записей"
  fi
}

# ─── Применить один провайдер ────────────────────────────────────────────────
apply_provider() {
  local NAME="$1"
  local FILE="$PROVIDERS_DIR/${NAME}.list"

  if [[ ! -f "$FILE" ]]; then
    warn "Провайдер не найден: providers/${NAME}.list — пропуск"
    return
  fi

  local COUNT=0
  while IFS= read -r LINE; do
    LINE="${LINE%%#*}"
    LINE="${LINE// /}"
    [[ -z "$LINE" ]] && continue
    validate_cidr "$LINE"
    iptables -A INPUT -s "$LINE" -j ACCEPT
    (( COUNT++ )) || true
  done < "$FILE"
  log "  + provider [$NAME]: добавлено $COUNT записей"
}

# ─── Применить все провайдеры из providers/ ──────────────────────────────────
apply_all_providers() {
  if [[ ! -d "$PROVIDERS_DIR" ]]; then
    warn "Директория providers/ не найдена, пропуск"
    return
  fi

  local FOUND=0
  for FILE in "$PROVIDERS_DIR"/*.list; do
    [[ -f "$FILE" ]] || continue
    local NAME
    NAME=$(basename "$FILE" .list)
    apply_provider "$NAME"
    (( FOUND++ )) || true
  done

  [[ $FOUND -eq 0 ]] && warn "В providers/ нет ни одного .list файла"
}

# ─── Добавить IP в ip.list (для команды add) ─────────────────────────────────
add_ip_to_list() {
  local ENTRY="$1"
  local GROUP="${2:-}"
  local PORTS="${3:-}"
  local LIST="$LISTS_DIR/ip.list"
  mkdir -p "$LISTS_DIR"
  touch "$LIST"

  # Проверяем дубликат
  if grep -qE "^${ENTRY}([[:space:]]|$)" "$LIST" 2>/dev/null; then
    warn "$ENTRY уже есть в ip.list"
    return
  fi

  local RECORD="$ENTRY"
  [[ -n "$PORTS" ]] && RECORD="$ENTRY $PORTS"

  if [[ -n "$GROUP" ]]; then
    if grep -q "^##${GROUP}$" "$LIST" 2>/dev/null; then
      sed -i "/^##${GROUP}$/a ${RECORD}" "$LIST"
      log "  ✓ Записан в ip.list [группа: ##$GROUP]: $RECORD"
    else
      printf "\n##%s\n%s\n" "$GROUP" "$RECORD" >> "$LIST"
      log "  ✓ Создана группа [##$GROUP] и записан: $RECORD"
    fi
  else
    echo "$RECORD" >> "$LIST"
    log "  ✓ Записан в ip.list: $RECORD"
  fi
}
