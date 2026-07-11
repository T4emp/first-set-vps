#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  GRE TUNNEL SETUP — STEALTHNET / XNet Proxies
#  Универсальный интерактивный установщик для обеих сторон.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Цвета ──────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
  C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# ── Утилиты вывода ─────────────────────────────────────────────
banner() {
  echo
  echo "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  $1${C_RESET}"
  echo "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════════════════${C_RESET}"
}
step()  { echo "${C_BLUE}${C_BOLD}[$1]${C_RESET} ${C_BOLD}$2${C_RESET}"; }
info()  { echo "${C_DIM}    $1${C_RESET}"; }
ok()    { echo "${C_GREEN}  ✓${C_RESET} $1"; }
warn()  { echo "${C_YELLOW}  ⚠${C_RESET} $1"; }
fail()  { echo "${C_RED}  ✗${C_RESET} $1"; }
die()   { fail "$1"; exit 1; }
ask()   { local p="$1"; local d="${2:-}"; local v
         if [ -n "$d" ]; then read -rp "${C_MAGENTA}❯${C_RESET} ${p} ${C_DIM}[$d]${C_RESET} " v
         else read -rp "${C_MAGENTA}❯${C_RESET} ${p} " v; fi
         echo "${v:-$d}"; }

# ── Проверка прав ─────────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "Запусти от root (sudo bash $0)"

# ── Заголовок ─────────────────────────────────────────────────
banner "GRE TUNNEL SETUP — STEALTHNET"
echo
echo "${C_DIM}Назначение: проброс 443/tcp с фронт-сервера на бэкенд-ноду${C_RESET}"
echo "${C_DIM}            (любую — Reality, nginx, что угодно слушающее 443).${C_RESET}"
echo "${C_DIM}Реальные IP клиентов сохраняются (без MASQUERADE).${C_RESET}"

# ═════════════════════════════════════════════════════════════
# [1/5] Тип сервера
# ═════════════════════════════════════════════════════════════
echo
step "1/5" "Тип сервера"
echo "    ${C_BOLD}1)${C_RESET} ${C_GREEN}Отдающий (фронт)${C_RESET}    ${C_DIM}— ловит 443/tcp, пробрасывает через GRE${C_RESET}"
echo "    ${C_BOLD}2)${C_RESET} ${C_BLUE}Принимающий (бэк)${C_RESET}   ${C_DIM}— получает GRE, слушает 443 (Reality / nginx / что-то ещё)${C_RESET}"
echo
ROLE_NUM="$(ask "Выбери [1/2]:")"
case "$ROLE_NUM" in
  1) ROLE="front"; ROLE_LABEL="${C_GREEN}Отдающий (фронт)${C_RESET}";;
  2) ROLE="back";  ROLE_LABEL="${C_BLUE}Принимающий (бэк)${C_RESET}";;
  *) die "Неверный выбор: $ROLE_NUM";;
esac
ok "Выбрано: $ROLE_LABEL"

# ═════════════════════════════════════════════════════════════
# [2/5] Сетевой интерфейс
# ═════════════════════════════════════════════════════════════
echo
step "2/5" "Сетевой интерфейс (откуда идёт публичный трафик)"
echo

# Собираем интерфейсы с IPv4 (исключая lo и docker)
mapfile -t IFACES < <(
  ip -4 -o addr show \
  | awk '{print $2 "|" $4}' \
  | grep -vE "^(lo|docker|br-|veth|gre|tun|tap)" \
  | sort -u
)
[ "${#IFACES[@]}" -gt 0 ] || die "Нет подходящих сетевых интерфейсов"

# Определяем дефолтный (тот, через который идёт default route)
DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
DEFAULT_NUM=1

# Выводим таблицу
printf "    ${C_DIM}%-3s %-12s %-18s %s${C_RESET}\n" "#" "iface" "IP" ""
i=1
for entry in "${IFACES[@]}"; do
  IFNAME="${entry%%|*}"
  IFADDR_CIDR="${entry##*|}"
  IFADDR="${IFADDR_CIDR%%/*}"
  if [ "$IFNAME" = "$DEFAULT_IF" ]; then
    DEFAULT_NUM=$i
    printf "    ${C_BOLD}%-3s %-12s %-18s${C_RESET} ${C_GREEN}← default${C_RESET}\n" "$i)" "$IFNAME" "$IFADDR"
  else
    printf "    %-3s %-12s %-18s\n" "$i)" "$IFNAME" "$IFADDR"
  fi
  i=$((i+1))
done
echo
IF_NUM="$(ask "Номер интерфейса:" "$DEFAULT_NUM")"
[[ "$IF_NUM" =~ ^[0-9]+$ ]] && [ "$IF_NUM" -ge 1 ] && [ "$IF_NUM" -le "${#IFACES[@]}" ] \
  || die "Неверный номер: $IF_NUM"

WAN_IF="${IFACES[$((IF_NUM-1))]%%|*}"
LOCAL_IP="${IFACES[$((IF_NUM-1))]##*|}"
LOCAL_IP="${LOCAL_IP%%/*}"
ok "Интерфейс: ${C_BOLD}$WAN_IF${C_RESET} (${C_BOLD}$LOCAL_IP${C_RESET})"

# ═════════════════════════════════════════════════════════════
# [3/5] IP противоположного сервера
# ═════════════════════════════════════════════════════════════
echo
step "3/5" "IP противоположного сервера (peer)"
if [ "$ROLE" = "front" ]; then
  info "Введи публичный IP ${C_BLUE}принимающего сервера${C_RESET}${C_DIM} (куда пробрасывать 443)${C_RESET}"
else
  info "Введи публичный IP ${C_GREEN}отдающего сервера${C_RESET}${C_DIM} (откуда придёт GRE)${C_RESET}"
fi
echo
PEER_IP="$(ask "Peer IP:")"
[[ "$PEER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Не похоже на IPv4: $PEER_IP"

# ═════════════════════════════════════════════════════════════
# [4/5] Подтверждение
# ═════════════════════════════════════════════════════════════
echo
step "4/5" "Подтверждение настроек"
echo
echo "    ${C_BOLD}Тип:${C_RESET}          $ROLE_LABEL"
echo "    ${C_BOLD}Интерфейс:${C_RESET}    $WAN_IF"
echo "    ${C_BOLD}Локальный IP:${C_RESET} $LOCAL_IP"
echo "    ${C_BOLD}Peer IP:${C_RESET}      $PEER_IP"
if [ "$ROLE" = "front" ]; then
  echo "    ${C_BOLD}Туннель:${C_RESET}      ${C_CYAN}10.255.255.1/30${C_RESET} → ${C_DIM}10.255.255.2/30${C_RESET}"
  echo "    ${C_BOLD}Действие:${C_RESET}     ${C_YELLOW}DNAT 443/tcp${C_RESET} → 10.255.255.2:443 через GRE"
  echo "    ${C_BOLD}SNAT:${C_RESET}         ${C_DIM}нет (реальные IP клиентов сохраняются)${C_RESET}"
else
  echo "    ${C_BOLD}Туннель:${C_RESET}      ${C_DIM}10.255.255.1/30${C_RESET} ← ${C_CYAN}10.255.255.2/30${C_RESET}"
  echo "    ${C_BOLD}Действие:${C_RESET}     ${C_YELLOW}policy routing${C_RESET} (ответы → gre1)"
  echo "    ${C_BOLD}rp_filter:${C_RESET}    ${C_DIM}loose mode (для асимметричного маршрута)${C_RESET}"
fi
echo
CONFIRM="$(ask "Применить? [y/N]" "n")"
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) warn "Отменено пользователем"; exit 0;;
esac

# ═════════════════════════════════════════════════════════════
# [5/5] Установка
# ═════════════════════════════════════════════════════════════
echo
step "5/5" "Установка"
echo

# ── Общее: ip_gre ──────────────────────────────────────────
info "Загружаю модуль ip_gre..."
modprobe ip_gre 2>&1 | sed 's/^/        /' || true
echo ip_gre > /etc/modules-load.d/ip_gre.conf
ok "ip_gre загружен и добавлен в /etc/modules-load.d/"

# ═══════════════════════════════ FRONT ═══════════════════════════
if [ "$ROLE" = "front" ]; then
  if ! command -v iptables >/dev/null; then
    info "Устанавливаю iptables-persistent..."
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent >/dev/null 2>&1
    ok "iptables установлен"
  else
    ok "iptables уже установлен"
  fi

  cat > /etc/sysctl.d/99-gre-tunnel.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
EOF
  ok "sysctl: ip_forward=1"

  cat > /usr/local/sbin/gre-tunnel.sh <<EOSH
#!/bin/bash
# Auto-generated by gre-setup.sh ($(date -Iseconds))
# Role: FRONT (отдающий) | DNAT 443/tcp -> backend through GRE
set -e
PEER_REMOTE="$PEER_IP"
PEER_LOCAL="$LOCAL_IP"
WAN_IF="$WAN_IF"
TUN_LOCAL_IP="10.255.255.1"
TUN_PEER_IP="10.255.255.2"

case "\$1" in
  up)
    modprobe ip_gre || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null
    if ip link show gre1 >/dev/null 2>&1; then ip link del gre1; fi
    ip tunnel add gre1 mode gre remote "\$PEER_REMOTE" local "\$PEER_LOCAL" ttl 64
    ip addr add "\$TUN_LOCAL_IP/30" dev gre1
    ip link set gre1 up
    iptables -t nat -C PREROUTING -i "\$WAN_IF" -p tcp --dport 443 -j DNAT --to-destination "\$TUN_PEER_IP:443" 2>/dev/null \\
      || iptables -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 443 -j DNAT --to-destination "\$TUN_PEER_IP:443"
    iptables -C FORWARD -i "\$WAN_IF" -o gre1 -p tcp --dport 443 -j ACCEPT 2>/dev/null \\
      || iptables -A FORWARD -i "\$WAN_IF" -o gre1 -p tcp --dport 443 -j ACCEPT
    iptables -C FORWARD -i gre1 -o "\$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \\
      || iptables -A FORWARD -i gre1 -o "\$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre1 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre1 -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i gre1 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -i gre1 -j TCPMSS --clamp-mss-to-pmtu
    echo "[gre-tunnel] UP  front=\$PEER_LOCAL -> back=\$PEER_REMOTE  (DNAT 443 -> \$TUN_PEER_IP)"
    ;;
  down)
    iptables -t nat -D PREROUTING -i "\$WAN_IF" -p tcp --dport 443 -j DNAT --to-destination "\$TUN_PEER_IP:443" 2>/dev/null || true
    iptables -D FORWARD -i "\$WAN_IF" -o gre1 -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i gre1 -o "\$WAN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre1 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i gre1 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    if ip link show gre1 >/dev/null 2>&1; then ip link del gre1; fi
    echo "[gre-tunnel] DOWN"
    ;;
  *) echo "usage: \$0 {up|down}"; exit 1 ;;
esac
EOSH
  chmod +x /usr/local/sbin/gre-tunnel.sh
  ok "Скрипт: /usr/local/sbin/gre-tunnel.sh"

# ═══════════════════════════════ BACK ═══════════════════════════
else
  cat > /etc/sysctl.d/99-gre-tunnel.conf <<EOF
net.ipv4.conf.gre1.rp_filter=0
net.ipv4.conf.all.rp_filter=2
EOF
  ok "sysctl: rp_filter loose mode"

  cat > /usr/local/sbin/gre-tunnel.sh <<EOSH
#!/bin/bash
# Auto-generated by gre-setup.sh ($(date -Iseconds))
# Role: BACK (принимающий) | 443 listener + policy routing
set -e
PEER_REMOTE="$PEER_IP"
PEER_LOCAL="$LOCAL_IP"
TUN_LOCAL_IP="10.255.255.2"
RT_TABLE_ID="100"
RT_TABLE_NAME="gre_back"

case "\$1" in
  up)
    modprobe ip_gre || true
    grep -qE "^\${RT_TABLE_ID}\s+\${RT_TABLE_NAME}\b" /etc/iproute2/rt_tables \\
      || echo "\${RT_TABLE_ID} \${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
    if ip link show gre1 >/dev/null 2>&1; then ip link del gre1; fi
    ip tunnel add gre1 mode gre remote "\$PEER_REMOTE" local "\$PEER_LOCAL" ttl 64
    ip addr add "\$TUN_LOCAL_IP/30" dev gre1
    ip link set gre1 up
    sysctl -w net.ipv4.conf.gre1.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
    ip route replace default dev gre1 table "\$RT_TABLE_NAME"
    while ip rule del from "\$TUN_LOCAL_IP" table "\$RT_TABLE_NAME" 2>/dev/null; do :; done
    ip rule add from "\$TUN_LOCAL_IP" table "\$RT_TABLE_NAME" priority 100
    echo "[gre-tunnel] UP  back=\$PEER_LOCAL <- front=\$PEER_REMOTE  (policy routing -> gre_back)"
    ;;
  down)
    while ip rule del from "\$TUN_LOCAL_IP" table "\$RT_TABLE_NAME" 2>/dev/null; do :; done
    ip route flush table "\$RT_TABLE_NAME" 2>/dev/null || true
    if ip link show gre1 >/dev/null 2>&1; then ip link del gre1; fi
    echo "[gre-tunnel] DOWN"
    ;;
  *) echo "usage: \$0 {up|down}"; exit 1 ;;
esac
EOSH
  chmod +x /usr/local/sbin/gre-tunnel.sh
  ok "Скрипт: /usr/local/sbin/gre-tunnel.sh"
fi

# ── Общее: systemd unit ──────────────────────────────────
cat > /etc/systemd/system/gre-tunnel.service <<EOF
[Unit]
Description=GRE tunnel ($([ "$ROLE" = "front" ] && echo "front -> back, DNAT 443" || echo "back <- front, policy routing"))
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gre-tunnel.sh up
ExecStop=/usr/local/sbin/gre-tunnel.sh down

[Install]
WantedBy=multi-user.target
EOF
ok "systemd unit: /etc/systemd/system/gre-tunnel.service"

systemctl daemon-reload
systemctl enable gre-tunnel.service >/dev/null 2>&1 || true
systemctl restart gre-tunnel.service
ok "Сервис запущен: $(systemctl is-active gre-tunnel.service)"
ok "Сервис в автозапуске: $(systemctl is-enabled gre-tunnel.service)"

# ═════════════════════════════════════════════════════════════
# Watchdog: проверка живости туннеля + автореконнект
# ═════════════════════════════════════════════════════════════
echo
info "Устанавливаю watchdog (ping peer через gre1 + автореконнект)..."

cat > /etc/default/gre-watchdog <<'EOF'
# GRE watchdog tuning (раскомменти и поменяй что нужно)
# PEER_TUN_IP=AUTO       # AUTO = определить по локальному адресу gre1
# PING_INTERVAL=10       # секунд между проверками
# PING_TIMEOUT=2         # таймаут одного ping (сек)
# FAIL_THRESHOLD=3       # сколько провалов подряд до реконнекта
# TUNNEL_SCRIPT=/usr/local/sbin/gre-tunnel.sh
EOF
ok "Конфиг: /etc/default/gre-watchdog"

cat > /usr/local/sbin/gre-watchdog.sh <<'EOSH'
#!/bin/bash
# GRE tunnel watchdog: ping peer через gre1; реконнект при потере связи.
set -u

PEER_TUN_IP="${PEER_TUN_IP:-AUTO}"
PING_INTERVAL="${PING_INTERVAL:-10}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
TUNNEL_SCRIPT="${TUNNEL_SCRIPT:-/usr/local/sbin/gre-tunnel.sh}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

detect_peer() {
  local local_ip
  local_ip="$(ip -4 -o addr show dev gre1 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  case "$local_ip" in
    10.255.255.1) echo "10.255.255.2" ;;
    10.255.255.2) echo "10.255.255.1" ;;
    *) echo "" ;;
  esac
}

# Ждём пока туннель поднимется впервые (gre-tunnel.service может ещё доезжать)
for _ in $(seq 1 30); do
  ip link show gre1 up >/dev/null 2>&1 && break
  sleep 1
done

[ "$PEER_TUN_IP" = "AUTO" ] && PEER_TUN_IP="$(detect_peer)"
[ -n "$PEER_TUN_IP" ] || { log "FATAL: не могу определить peer tunnel IP (gre1 не поднят?)"; exit 1; }

log "started: peer=$PEER_TUN_IP interval=${PING_INTERVAL}s timeout=${PING_TIMEOUT}s threshold=$FAIL_THRESHOLD"

fails=0
restarts=0

reconnect() {
  restarts=$((restarts+1))
  log "RECONNECT #$restarts (после $fails провалов)"
  "$TUNNEL_SCRIPT" down 2>&1 | sed 's/^/    /' || true
  sleep 1
  if "$TUNNEL_SCRIPT" up 2>&1 | sed 's/^/    /'; then
    log "реконнект ok"
  else
    log "реконнект FAILED — повтор на следующей итерации"
  fi
  fails=0
  sleep 3
}

while true; do
  if ! ip link show gre1 up >/dev/null 2>&1; then
    log "gre1 пропал или DOWN"
    reconnect
    continue
  fi
  if ping -c 1 -W "$PING_TIMEOUT" -I gre1 "$PEER_TUN_IP" >/dev/null 2>&1; then
    if [ "$fails" -gt 0 ]; then
      log "восстановилось после $fails провалов"
    fi
    fails=0
  else
    fails=$((fails+1))
    log "ping FAIL $fails/$FAIL_THRESHOLD (peer=$PEER_TUN_IP)"
    [ "$fails" -ge "$FAIL_THRESHOLD" ] && reconnect
  fi
  sleep "$PING_INTERVAL"
done
EOSH
chmod +x /usr/local/sbin/gre-watchdog.sh
ok "Watchdog: /usr/local/sbin/gre-watchdog.sh"

cat > /etc/systemd/system/gre-watchdog.service <<EOF
[Unit]
Description=GRE tunnel watchdog (ping + auto-reconnect)
After=gre-tunnel.service
PartOf=gre-tunnel.service
Wants=gre-tunnel.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/gre-watchdog
ExecStart=/usr/local/sbin/gre-watchdog.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
ok "systemd unit: /etc/systemd/system/gre-watchdog.service"

systemctl daemon-reload
systemctl enable gre-watchdog.service >/dev/null 2>&1 || true
systemctl restart gre-watchdog.service
ok "Watchdog запущен: $(systemctl is-active gre-watchdog.service)"
ok "Watchdog в автозапуске: $(systemctl is-enabled gre-watchdog.service)"

# ═════════════════════════════════════════════════════════════
# Финальная проверка
# ═════════════════════════════════════════════════════════════
banner "ПРОВЕРКА"
echo

# Туннель
if ip a show gre1 >/dev/null 2>&1; then
  GRE_INFO="$(ip -br a show gre1 | awk '{print $3}')"
  ok "Туннель gre1 поднят: ${C_BOLD}$GRE_INFO${C_RESET}"
else
  fail "Туннель gre1 не найден!"
  exit 1
fi

# Ping
if [ "$ROLE" = "front" ]; then PING_TARGET="10.255.255.2"; else PING_TARGET="10.255.255.1"; fi
echo
info "Пинг противоположной стороны ($PING_TARGET)..."
if ping -c 3 -W 2 -q "$PING_TARGET" >/tmp/.gre_ping 2>&1; then
  RTT="$(grep "rtt min" /tmp/.gre_ping | awk -F'/' '{print $5}')"
  ok "Связь есть, RTT ${C_BOLD}${RTT}ms${C_RESET}"
else
  warn "Пинг не идёт. Проверь что на ${C_BOLD}противоположной стороне${C_RESET} тоже запущен скрипт"
  warn "Если запущен — возможно хостер режет GRE. Проверь: tcpdump -i $WAN_IF proto gre"
fi
rm -f /tmp/.gre_ping

# Спец. проверки по роли
if [ "$ROLE" = "front" ]; then
  echo
  info "DNAT правило:"
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "DNAT.*443" | sed 's/^/        /' \
    && ok "DNAT 443 → 10.255.255.2:443 активно" \
    || fail "DNAT правило не найдено"
else
  echo
  info "Policy routing:"
  ip rule show | grep "gre_back" | sed 's/^/        /' \
    && ok "Правило from 10.255.255.2 → gre_back активно" \
    || fail "Policy rule не найдено"
fi

# ═════════════════════════════════════════════════════════════
# Финал
# ═════════════════════════════════════════════════════════════
banner "ГОТОВО"
echo
echo "${C_GREEN}${C_BOLD}  ✅ GRE-туннель развёрнут${C_RESET}"
echo
echo "  ${C_BOLD}Управление туннелем:${C_RESET}"
echo "    systemctl status  gre-tunnel"
echo "    systemctl restart gre-tunnel"
echo "    systemctl stop    gre-tunnel"
echo "    journalctl -u gre-tunnel -n 50"
echo
echo "  ${C_BOLD}Watchdog (автореконнект при потере связи):${C_RESET}"
echo "    systemctl status  gre-watchdog"
echo "    journalctl -u gre-watchdog -f          ${C_DIM}# live-лог проверок и реконнектов${C_RESET}"
echo "    ${C_DIM}тюнинг: /etc/default/gre-watchdog (PING_INTERVAL, FAIL_THRESHOLD, ...)${C_RESET}"
echo
if [ "$ROLE" = "front" ]; then
  echo "  ${C_BOLD}Тест извне:${C_RESET}"
  echo "    echo | openssl s_client -connect $LOCAL_IP:443 -servername <SNI>"
  echo "    ${C_DIM}(должен вернуть тот же cert что и при коннекте к $PEER_IP:443)${C_RESET}"
fi
echo
