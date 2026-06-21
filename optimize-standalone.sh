#!/usr/bin/env bash
# optimize-standalone.sh — автономный оптимизатор для Remnawave-backend-ноды.
# Тюнит sysctl (BBR, conntrack 2M, буферы, fd), лимиты, swap, journald, THP, NIC, irqbalance.
# Идемпотентен. Бэкап старых конфигов в /root/optimize-backup-<ts>.
# ЗАПУСКАТЬ ОТ ROOT, на BACKEND-сервере (Remnawave-нода), НЕ на HAProxy-входе.
# Перед применением экспортируй необходимые переменные:
# export SSH_PORT - порт SSH, PUB_KEY - публичный ключ, ALLOWED_IP - ip RW, ALLOWED_PORT - порт RW
# Обязательно иметь привязанный домен для ноды

set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "❌ Запусти от root (sudo bash optimize-standalone.sh)"; exit 1; }

BACKUP="/root/optimize-backup-$(date +%s)"
mkdir -p "$BACKUP"
echo "📦 Бэкап изменяемых файлов: $BACKUP"

# ─── 0.1. Перезагрузка ───
echo "▶ Проверка перезагрузки..."
if [ -f "/var/run/reboot-required" ]; then
  echo "*** System restart required ***"
  reboot
  exit 1
fi
echo "✓ Перезагрузка не требуется"

# ─── 1. Зависимости ───
echo "▶ Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get upgrade -y -qq || true
apt-get install -y ca-certificates curl irqbalance ethtool >/dev/null 2>&1 || true
apt-get install -y fail2ban nano dnsutils >/dev/null 2>&1 || true
echo "✓ Зависимости"

# ─── 1.1. Перезагрузка ───
echo "▶ Проверка перезагрузки..."
if [ -f "/var/run/reboot-required" ]; then
  echo "*** System restart required ***"
  reboot
  exit 1
fi
echo "✓ Перезагрузка не требуется"

# ─── 1.2. Очистка ───
echo "▶ Очистка временных файлов..."
apt autoremove -y || true
apt clean
echo "✓ Временные файлы очищены"

# ─── 2. Sysctl ───
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
net.ipv4.tcp_max_syn_backlog      = 65535
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
# IP forwarding (для XRay/VLESS host network)
net.ipv4.ip_forward               = 1
net.ipv4.conf.all.forwarding      = 1
# Conntrack — БОЛЬШЕ соединений (главное против "работает потом отключается")
net.netfilter.nf_conntrack_max                  = 2000000
net.nf_conntrack_max                            = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7440
net.netfilter.nf_conntrack_buckets              = 500000
# SYN flood
net.ipv4.tcp_syncookies           = 1
net.ipv4.tcp_synack_retries       = 2
net.ipv4.tcp_syn_retries          = 2
# Anti-spoof / ICMP (rp_filter=1 — если асимметричный роутинг ломает, поставь 0)
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
# Память
vm.swappiness                = 10
vm.dirty_ratio               = 10
vm.dirty_background_ratio    = 5
vm.overcommit_memory         = 1
# Файловые дескрипторы
fs.file-max                  = 2097152
fs.nr_open                   = 2097152
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192
# IPV6
net.ipv6.conf.all.disable_ipv6  = 1
net.ipv6.conf.default.disable_ipv6  = 1
net.ipv6.conf.lo.disable_ipv6 =  1
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

# ─── 2.1. SSHD ───
echo "▶ Аутентификация по ключу, смена порта..."
[ -f /etc/ssh/sshd_config.d/99-remnawave-optimize.conf ] && cp /etc/ssh/sshd_config.d/99-remnawave-optimize.conf "$BACKUP/" 2>/dev/null || true
cat > /etc/ssh/sshd_config.d/99-remnawave-optimize.conf <<SSHD
# === remnawave optimize standalone ===
# Авторизация по ключу
PubkeyAuthentication yes
# Смена порта ssh
Port $SSH_PORT
SSHD

[ -f /root/.ssh/authorized_keys ] && cp /root/.ssh/authorized_keys "$BACKUP/" 2>/dev/null || true
cat > /root/.ssh/authorized_keys <<KEYS
# === remnawave optimize standalone ===
# Публичный ключ
$PUB_KEY
KEYS

chmod 700 "/root/.ssh" && chmod 600 "/root/.ssh/authorized_keys"
if sshd -T 2>/dev/null | grep -qx "port $SSH_PORT" && sshd -T 2>/dev/null | grep -qx "pubkeyauthentication yes"; then
  echo "✓ SSH изменен"
else
  echo "⚠ SSH не изменен"
fi

# ─── 3. Лимиты ───
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

# ─── 4. Swap ───
echo "▶ Swap..."
if [ ! -f /swapfile ] && ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "✓ Создан /swapfile 2G"
else
  echo "✓ Swap уже есть"
fi

# ─── 5. journald ───
echo "▶ journald → 200M макс..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/remnawave-size.conf <<'J'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
J
systemctl restart systemd-journald || true
echo "✓ journald"

# ─── 6. NIC tuning (на BACKEND можно — это реальный VPN-выход, не за нашим шейпингом) ───
echo "▶ NIC tuning..."
NIC="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
if [ -n "${NIC:-}" ]; then
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

# ─── 7. CPU governor → performance ───
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

# ─── 8. THP off ───
echo "▶ THP → never..."
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
systemctl daemon-reload
systemctl enable --now remnawave-thp-off.service >/dev/null 2>&1 || true
echo "✓ THP отключен"

# ─── 8.1 UFW iptables default ───
echo "▶ Сброс UFW и iptables..."
ufw disable >/dev/null 2>&1
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F && iptables -X && iptables -Z
ip6tables -P INPUT ACCEPT && ip6tables -P FORWARD ACCEPT && ip6tables -P OUTPUT ACCEPT && ip6tables -F && ip6tables -X && ip6tables -Z
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
else
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
fi
echo "✓ UFW отключен, ipitables сброшен"

# ─── 8.2 Настройка iptables ───
echo "▶ Настройка iptables..."
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
# Очистка
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
iptables -t nat -F PREROUTING
iptables -t nat -F OUTPUT
iptables -F PORT_SCAN 2>/dev/null || true
iptables -F DOCKER-USER 2>/dev/null || true
iptables -X PORT_SCAN 2>/dev/null || true
iptables -X DOCKER-USER 2>/dev/null || true
# Отклонять все по умолчанию
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
# Loopback
iptables -A INPUT -i lo -j ACCEPT
# Разрешить уже установленные соединения
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Docker
iptables -A INPUT -i docker0 -j ACCEPT
iptables -A FORWARD -i docker0 -o $IFACE -j ACCEPT
iptables -A FORWARD -i $IFACE -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -N DOCKER-USER 2>/dev/null || true
iptables -I DOCKER-USER -j RETURN
# Отброс недействительных пакетов
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
# Отброс TCP-пакетов с недопустимыми флагами
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
# XMAS сканирование портов
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
# FIN без ACK
iptables -A INPUT -p tcp --tcp-flags ALL FIN -j DROP
# SYN + FIN
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
# SYN + RST
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
# FIN + RST
iptables -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
# Приватные ip
iptables -A INPUT -i $IFACE -s 0.0.0.0/8 -j DROP                    # "This" network
iptables -A INPUT -i $IFACE -s 10.0.0.0/8 -j DROP                   # RFC 1918 private
iptables -A INPUT -i $IFACE -s 100.64.0.0/10 -j DROP                # Carrier-grade NAT
iptables -A INPUT -i $IFACE -s 127.0.0.0/8 -j DROP                  # Loopback
iptables -A INPUT -i $IFACE -s 169.254.0.0/16 -j DROP               # Link-local
iptables -A INPUT -i $IFACE -s 172.16.0.0/12 ! -i docker0 -j DROP   # RFC 1918 private
iptables -A INPUT -i $IFACE -s 192.0.0.0/24 -j DROP                 # IETF protocol
iptables -A INPUT -i $IFACE -s 192.0.2.0/24 -j DROP                 # TEST-NET-1
iptables -A INPUT -i $IFACE -s 192.168.0.0/16 ! -i docker0 -j DROP  # RFC 1918 private
iptables -A INPUT -i $IFACE -s 198.18.0.0/15 -j DROP                # Benchmark testing
iptables -A INPUT -i $IFACE -s 198.51.100.0/24 -j DROP              # TEST-NET-2
iptables -A INPUT -i $IFACE -s 203.0.113.0/24 -j DROP               # TEST-NET-3
iptables -A INPUT -i $IFACE -s 224.0.0.0/4 -j DROP                  # Multicast
iptables -A INPUT -i $IFACE -s 240.0.0.0/4 -j DROP                  # Reserved
# SYN флуд
iptables -A INPUT -p tcp --syn \
  -m hashlimit --hashlimit-above 25/sec \
  --hashlimit-mode srcip \
  --hashlimit-name syn_flood \
  --hashlimit-htable-expire 30000 \
  -j DROP
# Включение SYN cookies
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.tcp_max_syn_backlog=4096
sysctl -w net.ipv4.tcp_synack_retries=2
# UDP флуд
iptables -A INPUT -p udp \
  -m hashlimit --hashlimit-above 50/sec \
  --hashlimit-mode srcip \
  --hashlimit-name udp_flood \
  --hashlimit-htable-expire 30000 \
  -j DROP
# Ограничение ICMP - лучше отключить
iptables -A INPUT -p icmp --icmp-type echo-request \
  -m limit --limit 5/sec --limit-burst 10 \
  -j ACCEPT
# Отключение лишних ICMP
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
# Разрешить важные типы ICMP (MTU)
iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
# Ограничение одновременных подключений
iptables -A INPUT -p tcp --syn \
  -m connlimit --connlimit-above 200 \
  --connlimit-mask 32 \
  -j DROP
iptables -A INPUT -p udp \
  -m connlimit --connlimit-above 200 \
  --connlimit-mask 32 \
  -j DROP
# Доступ к сервисам
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT                      # SSH
iptables -A INPUT -p tcp --dport 443 -j ACCEPT                            # HTTPS
iptables -A INPUT -p udp --dport 443 -j ACCEPT                            # UDP
iptables -A INPUT -p tcp --dport 80 -j ACCEPT                             # 80
iptables -A INPUT -s $ALLOWED_IP -p tcp --dport $ALLOWED_PORT -j ACCEPT   # RW
# Защита от сканирования портов
iptables -N PORT_SCAN 
iptables -A PORT_SCAN -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -j RETURN
iptables -A PORT_SCAN -j DROP
# Перенаправление отклоненных соеденений в цепоку PORT_SCAN
iptables -A INPUT -p tcp --syn -m conntrack --ctstate NEW -j PORT_SCAN
# Финальный сброс
iptables -A INPUT -j DROP
# Сохранение правил
iptables-save > /etc/iptables/rules.v4
# Очистка
ip6tables -F
ip6tables -X
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
# Сохранение правил
ip6tables-save > /etc/iptables/rules.v6
echo "✓ iptables настроен"

# ─── 8.3 Настройка fail2ban ───
echo "▶ Настройка fail2ban..."
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

# ─── 8.4 Рестарт SSHD ───
echo "▶ Рестарт SSHD..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || true
echo "✓ SSHD перезагружен"

# ─── 8.5 CertBot ───
echo "▶ Установка CertBot..."
domain_check() {
read -rp "Введите домен ноды: " DOMAIN
declare -g DOMAIN
VPS_IP=$(curl -s https://api.ipify.org 2>/dev/null)
DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -1)
echo "IP server : $VPS_IP, IP domain : $DOMAIN_IP"
if [ "$VPS_IP" != "$DOMAIN_IP" ]; then
  echo "⚠ Домен не совпадает с нодой"
  domain_check
fi
}
domain_check
[ -f /opt/certbot/docker-compose.yml ] && cp /opt/certbot/docker-compose.yml "$BACKUP/" 2>/dev/null || true
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

docker run --rm \
  -v "/opt/certbot/certs:/etc/letsencrypt" \
  -v "/opt/certbot/var-lib-letsencrypt:/var/lib/letsencrypt" \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "email@email.com" \
  -d "$DOMAIN"
[ -f /opt/custom_script/renew.sh ] && cp /opt/custom_script/renew.sh "$BACKUP/" 2>/dev/null || true
cat > "/opt/custom_script/renew.sh" <<'RENEW'
#!/usr/bin/env bash
set -euo pipefail
# Остановка контейнеров
echo "▶ Остановка контейнеров..."
docker compose -f "/opt/remnanode/docker-compose.yml" down
docker compose -f "/opt/caddy/docker-compose.yml" down
# Перевыпуск
echo "▶ Перевыпуск сертификата..."
cd /opt/certbot
docker compose run --rm certbot renew
# Запуск контейнеры
echo "▶ Запуск контейнеров..."
docker compose -f "/opt/remnanode/docker-compose.yml" up -d
docker compose -f "/opt/caddy/docker-compose.yml" up -d
echo "✓ Сертификат перевыпущен, контейнеры запущены"
RENEW

chmod +x "/opt/custom_script/renew.sh"
(crontab -l 2>/dev/null | grep -v certbot; echo "0 3 28 * * /opt/custom_script/renew.sh >> /var/log/certbot-renew.log 2>&1") | crontab -
echo "✓ CertBot настроен"

# ─── 8.6 GEO-файлы ───
echo "▶ Добавление GEO-файлов..."
wget -O /var/lib/remnanode/runetfreedomip.dat https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat 2>/dev/null
wget -O /var/lib/remnanode/runetfreedomsite.dat https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat 2>/dev/null
[ -f /opt/custom_script/geofiles.sh ] && cp /opt/custom_script/geofiles.sh "$BACKUP/" 2>/dev/null || true
cat > "/opt/custom_script/geofiles.sh" <<'GEO'
#!/usr/bin/env bash
set -euo pipefail
# Обновление GEO-файлов
echo "▶ Обновление GEO-файлов..."
wget -O /var/lib/remnanode/runetfreedomip.dat https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat
wget -O /var/lib/remnanode/runetfreedomsite.dat https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat
echo "✓ GEO-файлы обновлены"
GEO

chmod +x "/opt/custom_script/geofiles.sh"
(crontab -l 2>/dev/null | grep -v geofiles; echo "0 3 * * 7 /opt/custom_script/geofiles.sh >> /var/log/geofiles.log 2>&1") | crontab -
echo "✓ GEO-файлы настроены"

# ─── 8.7 Compose RN ───
echo "▶ Правка docker-compose RN..."
[ -f /opt/remnanode/docker-compose.yml ] && cp /opt/remnanode/docker-compose.yml "$BACKUP/" 2>/dev/null || true
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
      - /var/lib/remnanode/runetfreedomip.dat:/usr/local/share/xray/runetfreedomip.dat
      - /var/lib/remnanode/runetfreedomsite.dat:/usr/local/share/xray/runetfreedomsite.dat
      # - /var/log/remnanode:/var/log/remnanode
      - /dev/shm:/dev/shm  # Uncomment for selfsteal socket access
      - /opt/certbot/certs/:/var/lib/remnanode/configs/xray/ssl
DOCKER

docker compose -f "/opt/caddy/docker-compose.yml" down
docker compose -f "/opt/remnanode/docker-compose.yml" up -d
echo "✓ docker-compose RN правлен"

# ─── 8.8 apt update ───
echo "▶ Добавление авто-обновление apt..."
[ -f /opt/custom_script/apt_update.sh ] && cp /opt/custom_script/apt_update.sh "$BACKUP/" 2>/dev/null || true
cat > "/opt/custom_script/apt_update.sh" <<'APT'
#!/usr/bin/env bash
set -euo pipefail
# Обновление apt
echo "▶ Обновление apt..."
apt-get update -qq || true
apt-get upgrade -y -qq || true
# Очистка
echo "▶ Очистка временных файлов..."
apt autoremove -y || true
apt clean
echo "✓ Временные файлы очищены"
# Перезагрузка
echo "▶ Проверка перезагрузки..."
if [ -f "/var/run/reboot-required" ]; then
  echo "*** System restart required ***"
  reboot
fi
echo "✓ Перезагрузка не требуется"
APT

chmod +x "/opt/custom_script/apt_update.sh"
(crontab -l 2>/dev/null | grep -v apt_update; echo "0 5 * * 7 /opt/custom_script/apt_update.sh >> /var/log/apt_update.log 2>&1") | crontab -
echo "✓ Авто-обновление добавлено"

# ─── 9. irqbalance ───
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