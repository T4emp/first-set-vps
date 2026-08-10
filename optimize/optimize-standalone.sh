#!/usr/bin/env bash
# optimize-standalone.sh — автономный оптимизатор для Remnawave-backend-ноды.
# Тюнит sysctl (BBR, conntrack 2M, буферы, fd), лимиты, swap, journald, THP, NIC, irqbalance.
# Идемпотентен. Бэкап старых конфигов в /root/optimize-backup-<ts>.
# ЗАПУСКАТЬ ОТ ROOT, на BACKEND-сервере (Remnawave-нода), НЕ на HAProxy-входе.
# Обязательно иметь привязанный домен для ноды
#
# Переменные (задать до запуска или в optimize.conf):
#   SSH_PORT  — порт SSH
#   PUB_KEY   — публичный ключ для authorized_keys
#   BEARER    — токен Cloudflare API (опционально, для автоопределения домена)

# ─── root-доступ ───
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "❌ Запусти от root (sudo bash optimize-standalone.sh)"; exit 1; }

# ─── Загрузка конфига ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/optimize.conf"
if [ -f "$CONF_FILE" ]; then
  # shellcheck source=./optimize.conf
  source "$CONF_FILE"
  echo "✓ Конфиг загружен: $CONF_FILE"
else
  echo "⚠ optimize.conf не найден, используются переменные окружения"
fi

# Проверка обязательных переменных
: "${SSH_PORT:?Задай SSH_PORT в optimize.conf или через export}"
: "${PUB_KEY:?Задай PUB_KEY в optimize.conf или через export}"
# BEARER — опциональный, не проверяем

# ─── Перезагрузка ───
echo "▶ Проверка перезагрузки..."
if [ -f "/var/run/reboot-required" ]; then
  echo "*** System restart required ***"
  reboot
  exit 1
fi
echo "✓ Перезагрузка не требуется"

# ─── Backup ───
BACKUP="/root/optimize-backup-$(date +%s)"
mkdir -p "$BACKUP"
echo "📦 Бэкап изменяемых файлов: $BACKUP"

# ─── Зависимости ───
echo "▶ Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get upgrade -y -qq || true
apt-get install -y \
  ca-certificates curl wget \
  irqbalance ethtool \
  iptables-persistent netfilter-persistent \
  cron \
  tcpdump fail2ban \
  nano \
  dnsutils jq \
  iproute2 net-tools iputils-ping traceroute mtr-tiny \
  htop lsof sysstat \
  openssl \
  ncdu logrotate \
  apt-transport-https gnupg lsb-release \
  >/dev/null 2>&1 || true
unset DEBIAN_FRONTEND
echo "✓ Зависимости"

# ─── Очистка ───
echo "▶ Очистка временных файлов..."
apt autoremove -y || true
apt clean
echo "✓ Временные файлы очищены"

# ─── Sysctl ───
echo "▶ Sysctl: BBR, буферы, conntrack 2M, fd, anti-spoof..."
[ -f /etc/sysctl.d/99-remnawave-optimize.conf ] && cp /etc/sysctl.d/99-remnawave-optimize.conf "$BACKUP/" 2>/dev/null || true
cat > /etc/sysctl.d/99-remnawave-optimize.conf <<'SYSCTL'
# === remnawave optimize standalone ===
# Network core
net.core.default_qdisc            = fq
net.core.netdev_max_backlog       = 250000
net.core.somaxconn                = 65535
net.core.rmem_default             = 2097152
net.core.wmem_default             = 2097152
net.core.rmem_max                 = 67108864
net.core.wmem_max                 = 67108864
net.core.optmem_max               = 65536
# TCP
net.ipv4.tcp_congestion_control   = bbr
net.ipv4.tcp_fastopen             = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse             = 1
net.ipv4.tcp_fin_timeout          = 15
net.ipv4.tcp_keepalive_time       = 300
net.ipv4.tcp_keepalive_intvl      = 30
net.ipv4.tcp_keepalive_probes     = 5
net.ipv4.tcp_max_syn_backlog      = 4096
net.ipv4.tcp_max_tw_buckets       = 2000000
net.ipv4.tcp_mtu_probing          = 1
net.ipv4.tcp_no_metrics_save      = 1
net.ipv4.tcp_rfc1337              = 1
net.ipv4.tcp_sack                 = 1
net.ipv4.tcp_window_scaling       = 1
net.ipv4.tcp_rmem                 = 4096 87380 67108864
net.ipv4.tcp_wmem                 = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat        = 131072
net.ipv4.tcp_ecn                  = 1
net.ipv4.ip_local_port_range      = 10000 65535
net.ipv4.tcp_timestamps           = 1
# UDP
net.ipv4.udp_rmem_min             = 8192
net.ipv4.udp_wmem_min             = 8192
# IP forwarding (for XRay/VLESS host network)
net.ipv4.ip_forward               = 1
net.ipv4.conf.all.forwarding      = 1
# Conntrack
net.netfilter.nf_conntrack_max                     = 2000000
net.nf_conntrack_max                               = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_buckets                 = 500000
# SYN flood
net.ipv4.tcp_syncookies           = 1
net.ipv4.tcp_synack_retries       = 2
net.ipv4.tcp_syn_retries          = 2
# Anti-spoof / ICMP
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# RAM
vm.swappiness                = 10
vm.dirty_ratio               = 10
vm.dirty_background_ratio    = 5
vm.overcommit_memory         = 1
# File descriptors
fs.file-max                  = 2097152
fs.nr_open                   = 2097152
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192
# IPV6
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
SYSCTL

modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
echo "tcp_bbr"      > /etc/modules-load.d/remnawave-bbr.conf
echo "nf_conntrack" > /etc/modules-load.d/remnawave-conntrack.conf
sysctl --system >/dev/null 2>&1 || true
if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr; then
  echo "✓ BBR активен"
else
  echo "⚠ BBR не применился — проверь ядро (uname -r)"
fi

# ─── SSHD ───
echo "▶ Аутентификация по ключу, смена порта..."
[ -f /etc/ssh/sshd_config.d/98-remnawave-optimize.conf ] && cp /etc/ssh/sshd_config.d/98-remnawave-optimize.conf "$BACKUP/" 2>/dev/null || true
cat > /etc/ssh/sshd_config.d/98-remnawave-optimize.conf <<SSHD
# === remnawave optimize standalone ===
PubkeyAuthentication yes
Port $SSH_PORT
SSHD

[ -f /root/.ssh/authorized_keys ] && cp /root/.ssh/authorized_keys "$BACKUP/" 2>/dev/null || true
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<KEYS
# === remnawave optimize standalone ===
$PUB_KEY
KEYS

chmod 700 "/root/.ssh" && chmod 600 "/root/.ssh/authorized_keys"
if sshd -T 2>/dev/null | grep -qx "port $SSH_PORT" && sshd -T 2>/dev/null | grep -qx "pubkeyauthentication yes"; then
  echo "✓ SSH изменен"
else
  echo "⚠ SSH не изменен"
fi

# ─── Лимиты ───
echo "▶ Лимиты nofile/nproc → 1M..."
cp /etc/security/limits.conf "$BACKUP/" 2>/dev/null || true
sed -i '/# === remnawave optimize ===/,/# === \/remnawave optimize ===/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<'LIMITS'
# === remnawave optimize ===
*       soft    nofile  1048576
*       hard    nofile  1048576
*       soft    nproc   1048576
*       hard    nproc   1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
# === /remnawave optimize ===
LIMITS
mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/remnawave-limits.conf <<'L'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
L
cp /etc/systemd/system.conf.d/remnawave-limits.conf /etc/systemd/user.conf.d/remnawave-limits.conf
echo "✓ Лимиты подняты"

# ─── Swap ───
echo "▶ Swap..."
SWAP_SIZE_MB=2048
CURRENT_SWAP=$(swapon --show=SIZE,NAME --noheadings 2>/dev/null | awk '/swapfile/{gsub(/G/,"*1024"); gsub(/M/,"*1"); print int($1)}')
if [ -z "$CURRENT_SWAP" ] || [ "$CURRENT_SWAP" -lt "$SWAP_SIZE_MB" ]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l ${SWAP_SIZE_MB}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "✓ Создан /swapfile ${SWAP_SIZE_MB}M"
else
  echo "✓ Swap уже есть (${CURRENT_SWAP}MB >= ${SWAP_SIZE_MB}MB)"
fi

# ─── journald ───
echo "▶ journald → 200M макс..."
[ -f /etc/sysctl.d/remnawave-size.conf ] && cp /etc/sysctl.d/remnawave-size.conf "$BACKUP/" 2>/dev/null || true
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/remnawave-size.conf <<'J'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
J
systemctl restart systemd-journald || true
echo "✓ journald"

# ─── NIC tuning ───
echo "▶ NIC tuning..."
NIC="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
if [ -n "${NIC:-}" ]; then
  [ -f /etc/systemd/system/remnawave-nic-tune.service ] && cp /etc/systemd/system/remnawave-nic-tune.service "$BACKUP/" 2>/dev/null || true
  cat > /etc/systemd/system/remnawave-nic-tune.service <<EOF
[Unit]
Description=Remnawave NIC tuning ($NIC)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ethtool -G $NIC rx 4096 tx 4096 2>/dev/null || true; ethtool -K $NIC gro on gso on tso on 2>/dev/null || true; ip link set $NIC txqueuelen 10000 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnawave-nic-tune.service >/dev/null 2>&1 || true
  echo "✓ NIC=$NIC: ring 4096, GRO/GSO/TSO on"
else
  echo "⚠ Интерфейс не определён, NIC tuning пропущен"
fi

# ─── CPU governor → performance ───
echo "▶ CPU governor..."
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  cat > /etc/systemd/system/remnawave-cpu-perf.service <<'EOF'
[Unit]
Description=Remnawave CPU governor performance
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c" 2>/dev/null || true; done'
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now remnawave-cpu-perf.service >/dev/null 2>&1 || true
  echo "✓ CPU governor → performance"
else
  echo "✓ cpufreq нет (виртуалка) — пропуск"
fi

# ─── THP off ───
echo "▶ THP → never..."

# Применяем немедленно если путь существует
THP_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
THP_DEFRAG="/sys/kernel/mm/transparent_hugepage/defrag"
if [ -f "$THP_ENABLED" ]; then
  echo never > "$THP_ENABLED" 2>/dev/null || true
  echo never > "$THP_DEFRAG"  2>/dev/null || true
  echo "✓ THP отключен немедленно"
else
  echo "⚠ THP недоступен на этом ядре/виртуалке — пропуск немедленного применения"
fi

# Создаём сервис для сохранения после перезагрузки
[ -f /etc/systemd/system/remnawave-thp-off.service ] && cp /etc/systemd/system/remnawave-thp-off.service "$BACKUP/" 2>/dev/null || true
cat > /etc/systemd/system/remnawave-thp-off.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now remnawave-thp-off.service 2>/dev/null || true
echo "✓ THP сервис установлен"

# ─── fail2ban ───
echo "▶ Настройка fail2ban..."
[ -f /etc/fail2ban/jail.local ] && cp /etc/fail2ban/jail.local "$BACKUP/" 2>/dev/null || true
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
bantime.increment = true
bantime.multiplier = 2 4 8 16 32 64
bantime.maxtime = 30d
findtime = 600
maxretry = 5
banaction = iptables-allports

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 300
EOF

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban
if systemctl is-active --quiet fail2ban; then
  echo "✓ fail2ban настроен"
else
  echo "⚠ fail2ban не настроен (journalctl -u fail2ban --no-pager -n 20)"
fi

# ─── Рестарт SSHD ───
echo "▶ Рестарт SSHD..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || true
echo "✓ SSHD перезагружен"

# ─── CertBot ───
echo "▶ Установка CertBot..."

# Определение домена:
# - если BEARER задан в конфиге → автоматически через Cloudflare API
# - иначе → запрос домена вручную
domain_check() {
  VPS_IP=$(curl -s https://api.ipify.org 2>/dev/null)
  echo "IP сервера: $VPS_IP"

  # Используем локальную копию чтобы не затирать глобальную при рекурсии
  local _BEARER="${BEARER:-}"

  if [ -n "$_BEARER" ]; then
    echo "🔑 Найден CF токен, определение домена по IP..."

    CF_AUTH_CHECK=$(curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" \
      -H "Authorization: Bearer $_BEARER")
    CF_TOKEN_VALID=$(echo "$CF_AUTH_CHECK" | jq -r '.success // "false"')

    if [ "$CF_TOKEN_VALID" != "true" ]; then
      echo "⚠ Токен CF недействителен, переход на ручную проверку..."
      BEARER=""
      domain_check
      return
    fi

    DOMAIN=$(curl -s "https://api.cloudflare.com/client/v4/zones?per_page=500" \
      -H "Authorization: Bearer $_BEARER" | \
      jq -r '.result[].id' | \
      while read -r ZONE_ID; do
        curl -s "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&content=${VPS_IP}" \
          -H "Authorization: Bearer $_BEARER" | \
          jq -r '.result[].name // empty'
      done | head -1)

    if [ -z "$DOMAIN" ]; then
      echo "⚠ IP $VPS_IP не найден в Cloudflare"
      read -rp "Повторить попытку? (y/n): " RETRY
      [ "$RETRY" = "y" ] && domain_check
      return 1
    fi

    echo "✓ Домен найден: $DOMAIN"

  else
    echo "⚠ Токен CF не задан, ручная проверка..."
    read -rp "Введите домен ноды: " DOMAIN
    DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -1)
    echo "IP домена ($DOMAIN): $DOMAIN_IP"

    if [ "$VPS_IP" != "$DOMAIN_IP" ]; then
      echo "⚠ Домен не совпадает с нодой"
      read -rp "Повторить попытку? (y/n): " RETRY
      [ "$RETRY" = "y" ] && domain_check
      return 1
    fi
  fi

  echo "✓ Домен: $DOMAIN → $VPS_IP"
}
domain_check

docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml down 2>/dev/null || true
docker compose --project-directory /opt/caddy -f /opt/caddy/docker-compose.yml down 2>/dev/null || true
docker compose --project-directory /opt/nginx-selfsteal -f /opt/nginx-selfsteal/docker-compose.yml down 2>/dev/null || true
[ -f /opt/certbot/docker-compose.yml ] && cp /opt/certbot/docker-compose.yml "$BACKUP/certbot" 2>/dev/null || true
mkdir -p /opt/certbot/certs /opt/certbot/var-lib-letsencrypt /opt/custom_script
cat > /opt/certbot/docker-compose.yml <<CERT
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
      - ./var-lib-letsencrypt:/var/lib/letsencrypt
CERT

# Открываем порт 80 только для получения сертификата
# Используем подоболочку чтобы trap не перехватил EXIT всего скрипта
echo "▶ Открытие порта 80 для Let's Encrypt..."
(
  trap 'iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true; echo "▶ Порт 80 закрыт"' EXIT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT

  docker run --rm \
    -v "/opt/certbot/certs:/etc/letsencrypt" \
    -v "/opt/certbot/var-lib-letsencrypt:/var/lib/letsencrypt" \
    --network host \
    certbot/certbot certonly --standalone \
    --non-interactive --agree-tos \
    --email "email@email.com" \
    -d "$DOMAIN"
)

[ -f /opt/custom_script/renew.sh ] && cp /opt/custom_script/renew.sh "$BACKUP/" 2>/dev/null || true
cat > "/opt/custom_script/renew.sh" <<'RENEW'
#!/usr/bin/env bash
# v1.2
set -euo pipefail

echo "▶ Открытие порта 80 для Let's Encrypt..."
(
  trap 'iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true; echo "▶ Порт 80 закрыт"' EXIT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT

  # Остановка контейнеров
  echo "▶ Остановка контейнеров..."
  docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml down  || true
  docker compose --project-directory /opt/caddy -f /opt/caddy/docker-compose.yml down  || true
  docker compose --project-directory /opt/nginx-selfsteal -f /opt/nginx-selfsteal/docker-compose.yml down 2>/dev/null || true

  # Перевыпуск
  echo "▶ Перевыпуск сертификата..."
  docker compose --project-directory /opt/certbot -f /opt/certbot/docker-compose.yml run --rm certbot renew
)

# Запуск контейнеров (после закрытия порта 80)
echo "▶ Запуск контейнеров..."
docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml up -d  || true
docker compose --project-directory /opt/caddy -f /opt/caddy/docker-compose.yml up -d  || true
docker compose --project-directory /opt/nginx-selfsteal -f /opt/nginx-selfsteal/docker-compose.yml up -d 2>/dev/null || true

echo "✓ Сертификат перевыпущен, контейнеры запущены"
RENEW

docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml up -d 2>/dev/null || true
docker compose --project-directory /opt/caddy -f /opt/caddy/docker-compose.yml up -d 2>/dev/null || true
docker compose --project-directory /opt/nginx-selfsteal -f /opt/nginx-selfsteal/docker-compose.yml up -d 2>/dev/null || true
chmod +x "/opt/custom_script/renew.sh"
(crontab -l 2>/dev/null | grep -v "/opt/custom_script/renew.sh" || true; echo "0 3 1 * * /opt/custom_script/renew.sh >> /var/log/certbot-renew.log 2>&1") | crontab -
echo "✓ CertBot настроен"

# ─── Compose RN ───
echo "▶ Правка docker-compose RN..."
[ -f /opt/remnanode/docker-compose.yml ] && cp /opt/remnanode/docker-compose.yml "$BACKUP/remnanode" 2>/dev/null || true
cat > /opt/remnanode/docker-compose.yml <<DOCKER
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:latest
    env_file:
      - .env
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - /var/lib/remnanode/xray:/usr/local/bin/xray
      - /var/lib/remnanode/geoip.dat:/usr/local/share/xray/geoip.dat
      - /var/lib/remnanode/geosite.dat:/usr/local/share/xray/geosite.dat
      - /dev/shm:/dev/shm
      - /opt/certbot/certs/live/$DOMAIN:/var/lib/remnanode/configs/xray/ssl:ro
      - /opt/certbot/certs/archive/$DOMAIN:/var/lib/remnanode/configs/archive/$DOMAIN:ro
DOCKER

docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml down 2>/dev/null || true
docker compose --project-directory /opt/remnanode -f /opt/remnanode/docker-compose.yml up -d 2>/dev/null || true
echo "✓ docker-compose RN правлен"

# ─── WARP ───
echo "▶ Добавление WARP..."
[ -f /opt/warp/docker-compose.yml ] && cp /opt/warp/docker-compose.yml "$BACKUP/" 2>/dev/null || true
mkdir -p /opt/warp && cat > /opt/warp/docker-compose.yml <<WARP
services:
  warp:
    image: caomingjun/warp
    container_name: warp
    restart: always
    ports: ["127.0.0.1:40000:1080"]
    environment: ["WARP_SLEEP=2"]
    cap_add: ["NET_ADMIN"]
    sysctls: ["net.ipv4.conf.all.src_valid_mark=1"]
    volumes: ["./data:/var/lib/cloudflare-warp"]
WARP

docker compose --project-directory /opt/warp -f /opt/warp/docker-compose.yml down 2>/dev/null || true
docker compose --project-directory /opt/warp -f /opt/warp/docker-compose.yml up -d 2>/dev/null || true

# Проверка запуска WARP с повторными попытками
echo "⏳ Ожидание запуска WARP (до 60 сек)..."
WARP_OK=0
for i in $(seq 1 12); do
  WARP_TRACE=$(curl -sx socks5h://127.0.0.1:40000 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  WARP_STATUS=$(echo "$WARP_TRACE" | grep "^warp=" | cut -d= -f2)
  WARP_IP=$(echo "$WARP_TRACE" | grep "^ip=" | cut -d= -f2)

  if [ "$WARP_STATUS" = "on" ]; then
    WARP_OK=1
    break
  fi

  echo "  попытка $i/12 — warp=${WARP_STATUS:-нет ответа}, ждём 5 сек..."
  sleep 5
done

if [ "$WARP_OK" = "1" ]; then
  echo "✓ WARP поднят (ip=$WARP_IP, warp=on)"
else
  echo "⚠ WARP не отвечает после 60 сек"
  echo "  Статус контейнера:"
  docker compose --project-directory /opt/warp -f /opt/warp/docker-compose.yml ps 2>/dev/null || true
  echo "  Последние логи:"
  docker compose --project-directory /opt/warp -f /opt/warp/docker-compose.yml logs --tail=20 2>/dev/null || true
fi

# ─── irqbalance ───
systemctl enable --now irqbalance >/dev/null 2>&1 || true
echo "✓ irqbalance"

echo ""
echo "═══════════ ГОТОВО ═══════════"
echo "Текущие значения:"
printf "  %-28s %s\n" "tcp_congestion_control:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "  %-28s %s\n" "default_qdisc:"          "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
printf "  %-28s %s\n" "somaxconn:"              "$(sysctl -n net.core.somaxconn 2>/dev/null)"
printf "  %-28s %s\n" "nf_conntrack_max:"       "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
printf "  %-28s %s\n" "file-max:"               "$(sysctl -n fs.file-max 2>/dev/null)"
echo ""
echo "⚠ Лимиты nofile для shell применятся после ПЕРЕЛОГИНА."
echo "⚠ Рекомендуется ПЕРЕЗАГРУЗКА чтобы systemd подхватил DefaultLimit* + docker перечитал лимиты."
echo "Бэкап старых конфигов: $BACKUP"
