#!/usr/bin/env bash
# =============================================================================
# lib/core.sh — базовые правила iptables
# Содержит весь оригинальный iptables.sh, оформленный как функции.
# Вызывается из tguard.sh через run_core() или run_core_whitelist_mode().
# =============================================================================

# ─── Переменные из tguard.conf ───────────────────────────────────────────────
# SSH_PORT        — порт SSH
# REMNAWARE_IP    — IP сервера управления (remnaware)
# REMNAWARE_PORT  — порт общения remnaware с нодой
# USER_PORTS      — пользовательские порты через запятую (в basic/full 443 уже открыт глобально)

# ─── Сброс и подготовка ──────────────────────────────────────────────────────
_reset_firewall() {
  log "▶ Сброс UFW и iptables..."

  # Бэкап текущих правил
  local BACKUP="/root/tguard/backup/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP"
  [[ -f /etc/iptables/rules.v4 ]] && cp /etc/iptables/rules.v4 "$BACKUP/" 2>/dev/null || true
  [[ -f /etc/iptables/rules.v6 ]] && cp /etc/iptables/rules.v6 "$BACKUP/" 2>/dev/null || true

  # Отключаем UFW
  ufw disable        >/dev/null 2>&1 || true
  ufw --force reset  >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  # Сброс iptables в ACCEPT (чтобы не отрезать себя при настройке)
  iptables  -P INPUT ACCEPT && iptables  -P FORWARD ACCEPT && iptables  -P OUTPUT ACCEPT
  iptables  -F && iptables  -X && iptables  -Z
  ip6tables -P INPUT ACCEPT && ip6tables -P FORWARD ACCEPT && ip6tables -P OUTPUT ACCEPT
  ip6tables -F && ip6tables -X && ip6tables -Z

  mkdir -p /etc/iptables
  systemctl enable netfilter-persistent >/dev/null 2>&1 || true
  log "✓ UFW отключён, iptables сброшен (бэкап: $BACKUP)"
}

# ─── Очистка цепочек (без сброса политик) ────────────────────────────────────
_flush_chains() {
  local IFACE="$1"
  iptables -F INPUT
  iptables -F OUTPUT
  iptables -F FORWARD
  iptables -t nat -F PREROUTING
  iptables -t nat -F OUTPUT
  iptables -F PORT_SCAN   2>/dev/null || true
  iptables -F DOCKER-USER 2>/dev/null || true
  iptables -X PORT_SCAN   2>/dev/null || true
  iptables -X DOCKER-USER 2>/dev/null || true
}

# ─── Политики по умолчанию ───────────────────────────────────────────────────
_set_policies() {
  iptables -P INPUT   DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT  ACCEPT
}

# ─── Базовые разрешения ──────────────────────────────────────────────────────
_allow_basic() {
  # Loopback
  iptables -A INPUT -i lo -j ACCEPT
  # INVALID до ESTABLISHED (пакеты-аномалии не должны матчиться как RELATED)
  iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
  # Установленные соединения
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

# ─── Docker ──────────────────────────────────────────────────────────────────
_setup_docker() {
  local IFACE="$1"
  iptables -A INPUT   -i docker0 -j ACCEPT
  iptables -A FORWARD -i docker0 -o "$IFACE" -j ACCEPT
  iptables -A FORWARD -i "$IFACE" -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -N DOCKER-USER 2>/dev/null || true
  iptables -I DOCKER-USER -j RETURN
}

# ─── TCP: невалидные флаги ───────────────────────────────────────────────────
_drop_bad_tcp_flags() {
  iptables -A INPUT -p tcp --tcp-flags ALL NONE    -j DROP  # NULL-сканирование
  iptables -A INPUT -p tcp --tcp-flags ALL ALL     -j DROP  # XMAS-сканирование
  iptables -A INPUT -p tcp --tcp-flags ALL FIN     -j DROP  # FIN без ACK
  iptables -A INPUT -p tcp --tcp-flags SYN,FIN  SYN,FIN  -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,RST  SYN,RST  -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,RST  FIN,RST  -j DROP
  iptables -A INPUT -p tcp --tcp-flags PSH,ACK  PSH      -j DROP
  iptables -A INPUT -p tcp --tcp-flags URG,ACK  URG      -j DROP
}

# ─── UDP: невалидные пакеты ──────────────────────────────────────────────────
_drop_bad_udp() {
  # Слишком короткий UDP (IP-заголовок 20 + UDP-заголовок 8 = 28 байт минимум)
  iptables -A INPUT -p udp -m length --length 0:27 -j DROP
  # Зарезервированный порт 0
  iptables -A INPUT -p udp --dport 0 -j DROP
  iptables -A INPUT -p udp --sport 0 -j DROP
  # QUIC Initial по RFC 9000 >= 1200 байт; мелкие пакеты на UDP/443 — не QUIC
  iptables -A INPUT -p udp --dport 443 -m length --length 0:1199 -j DROP
}

# ─── Спуфинг приватных IP на внешнем интерфейсе ─────────────────────────────
_drop_spoofed() {
  local IFACE="$1"
  # Docker-сети разрешаем ДО DROP по IFACE
  iptables -A INPUT -s 172.16.0.0/12  -i docker0 -j ACCEPT
  iptables -A INPUT -s 192.168.0.0/16 -i docker0 -j ACCEPT
  # Все приватные/резервные диапазоны на внешнем интерфейсе — дроп
  iptables -A INPUT -i "$IFACE" -s 0.0.0.0/8       -j DROP  # "This" network
  iptables -A INPUT -i "$IFACE" -s 10.0.0.0/8       -j DROP  # RFC 1918
  iptables -A INPUT -i "$IFACE" -s 100.64.0.0/10    -j DROP  # CGNAT
  iptables -A INPUT -i "$IFACE" -s 127.0.0.0/8      -j DROP  # Loopback
  iptables -A INPUT -i "$IFACE" -s 169.254.0.0/16   -j DROP  # Link-local
  iptables -A INPUT -i "$IFACE" -s 172.16.0.0/12    -j DROP  # RFC 1918
  iptables -A INPUT -i "$IFACE" -s 192.0.0.0/24     -j DROP  # IETF protocol
  iptables -A INPUT -i "$IFACE" -s 192.0.2.0/24     -j DROP  # TEST-NET-1
  iptables -A INPUT -i "$IFACE" -s 192.168.0.0/16   -j DROP  # RFC 1918
  iptables -A INPUT -i "$IFACE" -s 198.18.0.0/15    -j DROP  # Benchmark
  iptables -A INPUT -i "$IFACE" -s 198.51.100.0/24  -j DROP  # TEST-NET-2
  iptables -A INPUT -i "$IFACE" -s 203.0.113.0/24   -j DROP  # TEST-NET-3
  iptables -A INPUT -i "$IFACE" -s 224.0.0.0/4      -j DROP  # Multicast
  iptables -A INPUT -i "$IFACE" -s 240.0.0.0/4      -j DROP  # Reserved
}

# ─── Flood-защита ────────────────────────────────────────────────────────────
_setup_flood_protection() {
  # SYN-флуд
  iptables -A INPUT -p tcp --syn \
    -m hashlimit --hashlimit-above 10/sec \
    --hashlimit-burst 20 \
    --hashlimit-mode srcip \
    --hashlimit-name syn_flood \
    --hashlimit-htable-expire 30000 \
    -j DROP
  # UDP-флуд
  iptables -A INPUT -p udp \
    -m hashlimit --hashlimit-above 50/sec \
    --hashlimit-burst 100 \
    --hashlimit-mode srcip \
    --hashlimit-name udp_flood \
    --hashlimit-htable-expire 30000 \
    -j DROP
}

# ─── ICMP ────────────────────────────────────────────────────────────────────
_setup_icmp() {
  iptables -A INPUT -p icmp --icmp-type echo-request \
    -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
  iptables -A INPUT -p icmp --icmp-type echo-reply \
    -m limit --limit 5/sec --limit-burst 10 -j ACCEPT
  iptables -A INPUT -p icmp --icmp-type destination-unreachable \
    -m limit --limit 10/sec --limit-burst 20 -j ACCEPT
  iptables -A INPUT -p icmp --icmp-type time-exceeded \
    -m limit --limit 10/sec --limit-burst 20 -j ACCEPT
  iptables -A INPUT -p icmp -j DROP
}

# ─── Ограничение одновременных соединений (НЕ применяется в whitelist-режиме) ─
_setup_connlimit() {
  iptables -A INPUT -p tcp --syn \
    -m connlimit --connlimit-above 200 --connlimit-mask 32 -j DROP
  iptables -A INPUT -p udp \
    -m connlimit --connlimit-above 200 --connlimit-mask 32 -j DROP
}

# ─── Пользовательские порты из USER_PORTS ────────────────────────────────────
apply_extra_ports() {
  local VAR_VALUE="${USER_PORTS:-}"
  if [[ -z "$VAR_VALUE" ]]; then
    warn "USER_PORTS не задан, пропуск"
    return
  fi
  IFS=',' read -ra PORTS <<< "$VAR_VALUE"
  for PORT in "${PORTS[@]}"; do
    PORT="${PORT// /}"
    validate_port "$PORT"
    iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
    log "  + user port $PORT (tcp+udp)"
  done
}

# ─── Общая часть сервисов (всегда) ───────────────────────────────────────────
_allow_services_base() {
  # SSH — порт может быть нестандартным; abuse обрабатывает fail2ban
  local SSH_P="${SSH_PORT:-22}"
  validate_port "$SSH_P"
  iptables -A INPUT -p tcp --dport "$SSH_P" -j ACCEPT
  log "  + SSH port $SSH_P"

  # Remnaware — доступ только с конкретного IP на конкретный порт
  local R_IP="${REMNAWARE_IP:-}"
  local R_PORT="${REMNAWARE_PORT:-}"
  if [[ -n "$R_IP" && -n "$R_PORT" ]]; then
    validate_cidr "$R_IP"
    validate_port "$R_PORT"
    iptables -A INPUT -s "$R_IP" -p tcp --dport "$R_PORT" -j ACCEPT
    log "  + remnaware $R_IP → port $R_PORT"
  else
    warn "REMNAWARE_IP / REMNAWARE_PORT не заданы, правило пропущено"
  fi
}

# ─── Публичный режим: 80/443 открыты для всех (basic, full) ──────────────────
_allow_services() {
  _allow_services_base
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
  iptables -A INPUT -p udp --dport 443 -j ACCEPT
  iptables -A INPUT -p tcp --dport 80  -j ACCEPT
  log "  + публичные порты 80, 443 (для всех)"
}

# ─── Whitelist режим: 80/443 НЕ открываются глобально ────────────────────────
# Доступ к портам выдаётся только IP из ip.list через _apply_ip_entry()
_allow_services_whitelist() {
  _allow_services_base
  log "  whitelist-режим: 80/443 не открыты глобально (только для IP из ip.list)"
}

# ─── Защита от сканирования портов ───────────────────────────────────────────
_setup_portscan_protection() {
  iptables -N PORT_SCAN 2>/dev/null || true
  iptables -A PORT_SCAN -m limit --limit 1/s --limit-burst 5 -j RETURN
  iptables -A PORT_SCAN -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j PORT_SCAN
}

# ─── Финальный DROP + IPv6 полная блокировка ─────────────────────────────────
_final_drop() {
  iptables -A INPUT -j DROP

  ip6tables -F
  ip6tables -X
  ip6tables -P INPUT   DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT  DROP
}

# =============================================================================
# Публичные функции, вызываемые из tguard.sh
# =============================================================================

# Полный core (включая connlimit) — для basic и full
run_core() {
  check_deps
  _reset_firewall
  local IFACE
  IFACE=$(get_iface)
  log "  интерфейс: $IFACE"
  _flush_chains "$IFACE"
  _set_policies
  _allow_basic
  _setup_docker "$IFACE"
  _drop_bad_tcp_flags
  _drop_bad_udp
  _drop_spoofed "$IFACE"
  _setup_flood_protection
  _setup_icmp
  _setup_connlimit          # ← есть
  _allow_services
  _setup_portscan_protection
  log "✓ Core (с connlimit) применён"
}

# Core без connlimit — для whitelist-режима
run_core_whitelist_mode() {
  check_deps
  _reset_firewall
  local IFACE
  IFACE=$(get_iface)
  log "  интерфейс: $IFACE"
  _flush_chains "$IFACE"
  _set_policies
  _allow_basic
  _setup_docker "$IFACE"
  _drop_bad_tcp_flags
  _drop_bad_udp
  _drop_spoofed "$IFACE"
  _setup_flood_protection
  _setup_icmp
  # _setup_connlimit — намеренно пропущен в whitelist-режиме
  _allow_services_whitelist   # 80/443 не открываются глобально
  _setup_portscan_protection
  log "✓ Core (без connlimit, whitelist-режим) применён"
}
