#!/bin/bash
##beta0.4
##VARIABLE
REBOOT_REQUIRED="/var/run/reboot-required"
SSHD_CONFIG="/etc/ssh/sshd_config"
SYSCTL_CFG="/etc/sysctl.conf"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
NC="\e[0m"
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
    echo -e "${GREEN}Update apt...${NC}"
    apt update && apt upgrade -y
    reboot_required
    echo -e "${GREEN}Successful${NC}"
}
##INSTALL BASED APPS##
install_based(){
    update
    echo -e "${GREEN}Installing apt...${NC}"
    apt-get install ufw -y
    apt-get install -yqq --no-install-recommends ca-certificates
    apt-get install fail2ban -y
	apt-get install nano -y
    reboot_required
    echo -e "${GREEN}Successful${NC}"
}
##CLEAN APT##
clean_apt(){
    echo -e "${GREEN}Cleaning apt...${NC}"
    apt autoremove -y
    apt clean
    echo -e "${GREEN}Successful${NC}"
}

##SSH PORT##
change_port() {
if grep -qE "^#Port " "$SSHD_CONFIG"; then
    sed -i "s/^#Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
    echo -e "${YELLOW}Port uncommented and set to $NEW_PORT${NC}"

elif grep -qE "^Port " "$SSHD_CONFIG"; then
    CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" | awk '{print $2}')
    if [ "$CURRENT_PORT" = "$NEW_PORT" ]; then
        echo -e "${YELLOW}Port is already set to $NEW_PORT, skipping${NC}"
    else
        sed -i "s/^Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
        echo -e "${GREEN}Port changed from $CURRENT_PORT to $NEW_PORT${NC}"
    fi

else
    echo "Port $NEW_PORT" >> "$SSHD_CONFIG"
    echo -e "${GREEN}Port $NEW_PORT added to $SSHD_CONFIG${NC}"
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

elif grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
    echo -e "${YELLOW}Root login disabled${NC}"

else
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    echo -e "${YELLOW}Root login disabled${NC}"
fi
}
##CREATE PUB KEY AND ACTIVATE##
setup_pubkey_auth() {
    SSH_DIR="/home/$USERNAME/.ssh"
    AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"

    mkdir -p "$SSH_DIR"
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

    echo -e "${GREEN}Activated auth with pub key${NC}"
}
##BBR##
enable_bbr() {

if [ ! -f "$SYSCTL_CFG" ]; then
	touch "$SYSCTL_CFG"
	echo -e "${GREEN}Created $SYSCTL_CFG${NC}"
fi

AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control)
CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control)
echo -e "${YELLOW}Available: $AVAILABLE${NC}"
echo -e "${GREEN}Current:   $CURRENT${NC}"

if echo "$AVAILABLE" | grep -qw "bbr3"; then
    BEST_BBR="bbr3"
elif echo "$AVAILABLE" | grep -qw "bbr2"; then
    BEST_BBR="bbr2"
elif echo "$AVAILABLE" | grep -qw "bbr"; then
    BEST_BBR="bbr"
else
    echo -e "${YELLOW}BBR not available, trying to load module...${NC}"
    if modprobe tcp_bbr 2>/dev/null; then
        AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control)
        if echo "$AVAILABLE" | grep -qw "bbr"; then
            BEST_BBR="bbr"
            echo -e "${GREEN}BBR module loaded successfully${NC}"
        else
            echo -e "${RED}BBR module loaded but still not available${NC}"
            echo -e "${RED}Virtualization type: $(systemd-detect-virt)${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Failed to load BBR module${NC}"
        echo -e "${RED}Virtualization type: $(systemd-detect-virt)${NC}"
        exit 1
    fi
fi

echo "tcp_bbr" >> /etc/modules-load.d/modules.conf 2>/dev/null

if [ "$CURRENT" = "$BEST_BBR" ]; then
    echo -e "${GREEN}BBR already set to best available version ($BEST_BBR), skipping${NC}"
else
    sysctl -w net.ipv4.tcp_congestion_control="$BEST_BBR"
    echo -e "${GREEN}BBR activated: $BEST_BBR${NC}"
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
echo -e "${GREEN}All network parameters applied and saved${NC}"
}
##IPV6##
disable_ipv6_ufw(){
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
    echo -e "${YELLOW}GRUB already configured${NC}"
else
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' "$GRUB_CONF"
    update-grub 2>/dev/null
    echo -e "${GREEN}GRUB updated${NC}"
fi

if [ -f "$UFW_CONF" ]; then
    if grep -q "^IPV6=no" "$UFW_CONF"; then
        echo -e "${YELLOW}UFW IPv6 already disabled${NC}"
    else
        sed -i "s/^IPV6=.*/IPV6=no/" "$UFW_CONF"
        echo -e "${GREEN}UFW IPv6 disabled${NC}"
        if ufw status | grep -q "Status: active"; then
            ufw reload > /dev/null 2>&1
            echo -e "${YELLOW}UFW reloaded${NC}"
        fi
    fi
else
    echo -e "${RED}UFW config not found, skipping${NC}"
fi

echo -e "${GREEN}IPv6 disabled${NC}"
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
    ufw allow 443
    ufw allow from "$ALLOWED_IP" to any port "$ALLOWED_PORT" proto tcp

    echo -e "${GREEN}UFW rules added${NC}"

    ufw --force enable
}
##IPTABLES##
iptables_rules() {
    mkdir -p /etc/iptables
    if ! dpkg -l | grep -q iptables-persistent; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1
        echo -e "${GREEN}IPtables-persistent installed${NC}"
    fi
    #FLUSH
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD
    iptables -t nat -F PREROUTING
    iptables -t nat -F OUTPUT
    iptables -F PORT_SCAN 2>/dev/null || true
    iptables -F DOCKER-USER 2>/dev/null || true
    #DEFAULT
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    #ENABLE ESTABLISHED
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    #DOCKER
    iptables -A INPUT -i docker0 -j ACCEPT
    iptables -A FORWARD -i docker0 -o eth0 -j ACCEPT
    iptables -A FORWARD -i eth0 -o docker0 -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -I DOCKER-USER -j RETURN
    #INVALID
    iptables -A INPUT -m state --state INVALID -j DROP
    #SPOOF
    iptables -A INPUT -s 0.0.0.0/8 -j DROP
    iptables -A INPUT -s 10.0.0.0/8 -j DROP
    iptables -A INPUT -s 100.64.0.0/10 -j DROP
    iptables -A INPUT -s 127.0.0.0/8 -j DROP
    iptables -A INPUT -s 169.254.0.0/16 -j DROP
    iptables -A INPUT -s 172.16.0.0/12 ! -i docker0 -j DROP
    iptables -A INPUT -s 192.0.0.0/24 -j DROP
    iptables -A INPUT -s 192.0.2.0/24 -j DROP
    iptables -A INPUT -s 192.88.99.0/24 -j DROP
    iptables -A INPUT -s 192.168.0.0/16 ! -i docker0 -j DROP
    iptables -A INPUT -s 198.18.0.0/15 -j DROP
    iptables -A INPUT -s 198.51.100.0/24 -j DROP
    iptables -A INPUT -s 203.0.113.0/24 -j DROP
    iptables -A INPUT -s 224.0.0.0/4 -j DROP
    iptables -A INPUT -s 255.255.255.255 -j DROP
    #ICMP (PING)
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
    #WHITELIST IP
    iptables -A INPUT -s "$ALLOWED_IP" -p tcp --dport "$ALLOWED_PORT" -j ACCEPT
    #SSH
    iptables -A INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT
    #HTTPS DDOS
    iptables -A INPUT -p tcp --dport 443 -m state --state NEW -m hashlimit \
        --hashlimit-name conn_443 \
        --hashlimit-above 200/min \
        --hashlimit-burst 300 \
        --hashlimit-mode srcip \
        --hashlimit-htable-expire 60000 \
        -j DROP
    iptables -A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT
	#PORT SCAN
    iptables -N PORT_SCAN 2>/dev/null || true
    iptables -A PORT_SCAN -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -j RETURN
    iptables -A PORT_SCAN -j DROP
    iptables -A INPUT -j PORT_SCAN
    #SAVE RULES
    iptables-save > /etc/iptables/rules.v4
    echo -e "${GREEN}IPtables rules saved${NC}"
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
maxretry = 10
bantime = 86400
findtime = 600
EOF

echo -e "${GREEN}fail2ban configured${NC}"

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban

sleep 2
if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}fail2ban is running${NC}"
    fail2ban-client status sshd
else
    echo -e "${RED}fail2ban failed to start${NC}"
    journalctl -u fail2ban --no-pager -n 20
    exit 1
fi
}
##RESTART SSHD
restart_ssh(){
    systemctl restart sshd
	systemctl restart sshd
	systemctl status ssh
   systemctl status sshd
	echo -e "${GREEN}SSh has been restarted${NC}"
}
##MAIN SCRIPT##
enable_root
reboot_required
update
install_based
clean_apt
change_port
#create_user
#disable_root_login
#setup_pubkey_auth
enable_bbr
disable_ipv6_ufw
reset_ufw
fail2ban
setup_ufw
iptables_rules
restart_ssh
