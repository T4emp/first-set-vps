#!/bin/bash
##alpha0.1.1
##VARIABLE
REBOOT_REQUIRED="/var/run/reboot-required"
SSHD_CONFIG="/etc/ssh/sshd_config"
SYSCTL_CFG="/etc/sysctl.conf"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"
ENTER=""
UFW_CONF="/etc/default/ufw"
GRUB_CONF="/etc/default/grub"
##SUDO\ROOT##
enable_root(){
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Sudo/root privileges required${NC}"
    exit 0
fi
}
##SYSTEM REBOOT REQUIRED##
reboot_required() {
    if [ -f "$REBOOT_REQUIRED" ]; then
        echo -e "${RED}*** System restart required ***${NC}"
        read -rp "$(echo -e "${GREEN}Reboot now? (y/n):${NC}")" ANSWER
        case "$ANSWER" in
            [yY]*)
                echo -e "${GREEN}Rebooting...${NC}"
                reboot
                exit 0
                ;;
            [nN]*)
                return 0
                ;;
            *)
                echo -e "${YELLOW}Invalid input${NC}"
                reboot_required
                ;;
        esac
    fi
}
##UPDATE##
update(){
    local SKIP_ENTER="$1"

    echo -e "${GREEN}Update apt...${NC}"
    apt update && apt upgrade -y
    reboot_required
    echo -e "${GREEN}Successful${NC}"
}
##CLEAN APT##
clean_apt(){
    local SKIP_ENTER="$1"

    echo -e "${GREEN}Cleaning apt...${NC}"
    apt autoremove -y
    apt clean
    echo -e "${GREEN}Successful${NC}"
}
##INSTALL BASED APPS##
install_based(){
    update
    echo -e "${GREEN}Installing apt...${NC}"
    apt-get install ufw -y
    apt-get install -yqq --no-install-recommends ca-certificates
    apt-get install fail2ban -y
    clean_apt
    reboot_required
    echo -e "${GREEN}Successful${NC}"
}
##SSH PORT##
change_port() {
if grep -qE "^#Port " "$SSHD_CONFIG"; then
    sed -i "s/^#Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
    echo -e "${YELLOW}Port uncommented and set to $NEW_PORT${NC}"
    systemctl restart ssh sshd

elif grep -qE "^Port " "$SSHD_CONFIG"; then
    CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" | awk '{print $2}')
    if [ "$CURRENT_PORT" = "$NEW_PORT" ]; then
        echo -e "${YELLOW}Port is already set to $NEW_PORT, skipping${NC}"
    else
        sed -i "s/^Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
        echo -e "${GREEN}Port changed from $CURRENT_PORT to $NEW_PORT${NC}"
        systemctl restart ssh sshd
    fi

else
    echo "Port $NEW_PORT" >> "$SSHD_CONFIG"
    echo -e "${GREEN}Port $NEW_PORT added to $SSHD_CONFIG${NC}"
    systemctl restart ssh sshd
fi
}
##CREATE NEW USER AND ADD TO SUDO##
create_user() {
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}User $USERNAME already exists, skipping${NC}"
else
    adduser --gecos "" --disabled-password "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/$USERNAME
    echo -e "${GREEN}User $USERNAME created and added to sudo${NC}"
fi
}
##DISABLE ROOT##
disable_root_login() {
if grep -qE "^PermitRootLogin no" "$SSHD_CONFIG"; then
    echo -e "${YELLOW}Root login already disabled, skipping${NC}"

elif grep -qE "^#PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
    echo -e "${YELLOW}Root login disabled${NC}"
    systemctl restart ssh sshd

elif grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
    echo -e "${YELLOW}Root login disabled${NC}"
    systemctl restart ssh sshd

else
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    echo -e "${YELLOW}Root login disabled${NC}"
    systemctl restart ssh sshd
fi
}
##CREATE PUB KEY AND ACTIVATE##
setup_pubkey_auth() {
    SSH_DIR="/home/$USERNAME/.ssh"
    AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"
    read -rp "$(echo -e "${GREEN}Enter pub key:${NC} ")" PUB_KEY
    echo "$PUB_KEY" > "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
    chmod 700 "$SSH_DIR"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
    echo -e "${GREEN}Created $AUTH_KEYS_FILE${NC}"

    if grep -qE "^#PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" "$SSHD_CONFIG"
    elif grep -qE "^PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    fi
    echo -e "${GREEN}PasswordAuthentication set to no${NC}"

    if grep -qE "^#PubkeyAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^#PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
    elif grep -qE "^PubkeyAuthentication" "$SSHD_CONFIG"; then
        sed -i "s/^PubkeyAuthentication.*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
    else
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
    fi
    echo -e "${GREEN}PubkeyAuthentication set to yes${NC}"

    systemctl restart ssh sshd
    echo -e "${GREEN}Activated auth with pub key${NC}"
##BBR##
enable_bbr() {
AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control)
CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)

echo -e "Available: $AVAILABLE"
echo -e "Current:   $CURRENT"

if echo "$AVAILABLE" | grep -qw "bbr3"; then
    BEST_BBR="bbr3"
elif echo "$AVAILABLE" | grep -qw "bbr2"; then
    BEST_BBR="bbr2"
elif echo "$AVAILABLE" | grep -qw "bbr"; then
    BEST_BBR="bbr"
else
    echo -e "BBR is not available on this system"
    exit 1
fi

if [ "$CURRENT" = "$BEST_BBR" ]; then
    echo -e "BBR already set to best available version ($BEST_BBR), skipping"
else
    modprobe tcp_bbr 2>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control="$BEST_BBR"
    echo -e "BBR activated: $BEST_BBR"
fi

declare -A PARAMS=(
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="$BEST_BBR"
    ["fs.file-max"]="2097152"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_window_scaling"]="1"
    ["net.core.rmem_max"]="16777216"
    ["net.core.wmem_max"]="16777216"
    ["net.ipv4.tcp_rmem"]="4096 87380 16777216"
    ["net.ipv4.tcp_wmem"]="4096 65536 16777216"
)

for KEY in "${!PARAMS[@]}"; do
    VALUE="${PARAMS[$KEY]}"

    sed -i "/^${KEY}/d" "$SYSCTL_CFG"

    echo "${KEY}=${VALUE}" >> "$SYSCTL_CFG"

    sysctl -w "${KEY}=${VALUE}" > /dev/null 2>&1
done

sysctl -p "$SYSCTL_CFG" > /dev/null

echo -e "All network parameters applied and saved"
}
##IPV6##
PARAMS=(
    "net.ipv6.conf.all.disable_ipv6=1"
    "net.ipv6.conf.default.disable_ipv6=1"
    "net.ipv6.conf.lo.disable_ipv6=1"
)

for PARAM in "${PARAMS[@]}"; do
    KEY="${PARAM%%=*}"
    sed -i "/^${KEY}/d" "$SYSCTL_CFG"
    echo "$PARAM" >> "$SYSCTL_CFG"
    sysctl -w "$PARAM" > /dev/null 2>&1
done

sysctl -p "$SYSCTL_CFG" > /dev/null

if grep -q "ipv6.disable=1" "$GRUB_CONF"; then
    echo "GRUB already configured"
else
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' "$GRUB_CONF"
    update-grub 2>/dev/null
    echo "GRUB updated"
fi

if [ -f "$UFW_CONF" ]; then
    if grep -q "^IPV6=no" "$UFW_CONF"; then
        echo "UFW IPv6 already disabled"
    else
        sed -i "s/^IPV6=.*/IPV6=no/" "$UFW_CONF"
        echo "UFW IPv6 disabled"
        if ufw status | grep -q "Status: active"; then
            ufw reload > /dev/null 2>&1
            echo "UFW reloaded"
        fi
    fi
else
    echo "UFW config not found, skipping"
fi

echo "IPv6 disabled"
}
##RESET UFW AND IPTABLES##
reset_ufw(){
ufw disable
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F && iptables -X && iptables -Z
}
##UFW##
setup_ufw() {
    ufw allow "$NEW_PORT"/tcp
    ufw allow https
    ufw allow from "$UFW_IP" to any port 3000 proto tcp

    echo -e "${GREEN}UFW rules added${NC}"

    ufw --force enable
}
##IPTABLES##
iptables_rules(){
#DDOS
iptables -A INPUT -p tcp --dport "$NEW_PORT" -m state --state NEW -m limit --limit 5/min --limit-burst 10 -j ACCEPT
iptables -A INPUT -p tcp --dport "$NEW_PORT" -m state --state NEW -j DROP
iptables -A INPUT -p tcp --dport 443 -m state --state NEW -m hashlimit \
    --hashlimit-name conn_443 \
    --hashlimit-above 200/min \
    --hashlimit-burst 300 \
    --hashlimit-mode srcip \
	--hashlimit-htable-expire 60000 \
    -j DROP
#SYN FLOOD
iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
iptables -A INPUT -p tcp --syn -m limit --limit 10/s --limit-burst 20 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP
#PORT SCANNING
iptables -A INPUT -m state --state INVALID -j DROP
iptables -N PORT_SCAN
iptables -A PORT_SCAN -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -j RETURN
iptables -A PORT_SCAN -j DROP
iptables -A INPUT -j PORT_SCAN
#ICMP (PING)
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
#SPOOF
iptables -A INPUT -s 0.0.0.0/8 -j DROP
iptables -A INPUT -s 10.0.0.0/8 -j DROP
iptables -A INPUT -s 100.64.0.0/10 -j DROP
iptables -A INPUT -s 127.0.0.0/8 -j DROP
iptables -A INPUT -s 169.254.0.0/16 -j DROP
iptables -A INPUT -s 172.16.0.0/12 -j DROP
iptables -A INPUT -s 192.0.0.0/24 -j DROP
iptables -A INPUT -s 192.0.2.0/24 -j DROP
iptables -A INPUT -s 192.88.99.0/24 -j DROP
iptables -A INPUT -s 192.168.0.0/16 -j DROP
iptables -A INPUT -s 198.18.0.0/15 -j DROP
iptables -A INPUT -s 198.51.100.0/24 -j DROP
iptables -A INPUT -s 203.0.113.0/24 -j DROP
iptables -A INPUT -s 224.0.0.0/4 -j DROP
iptables -A INPUT -s 255.255.255.255 -j DROP
#ENABLE ESTABLISHED
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
#SAVE RULES
iptables-save > /etc/iptables/rules.v4
}
##FAIL2BAN
fail2ban() {
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 600
maxretry = 5
banaction = iptables-multiport

[sshd]
enabled = true
port = $NEW_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
findtime = 600
EOF

echo "fail2ban configured"

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban

sleep 2
if systemctl is-active --quiet fail2ban; then
    echo "fail2ban is running"
    fail2ban-client status sshd
else
    echo "fail2ban failed to start"
    journalctl -u fail2ban --no-pager -n 20
    exit 1
fi
}
##MAIN SCRIPT##
enable_root
reboot_required
update
install_based
clean_apt
change_port
create_user
disable_root_login
setup_pubkey_auth
enable_bbr
disable_ipv6_ufw
reset_ufw
setup_ufw
iptables_rules
fail2ban
