#!/bin/bash
##alpha0.1.2
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

    if [ "$SKIP_ENTER" != "true" ]; then
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
    fi
}

##CLEAN APT##
clean_apt(){
    local SKIP_ENTER="$1"

    echo -e "${GREEN}Cleaning apt...${NC}"
    apt autoremove -y
    apt clean
    echo -e "${GREEN}Successful${NC}"

    if [ "$SKIP_ENTER" != "true" ]; then
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
    fi
}

##INSTALL BASED APPS##
install_based(){
    update true
    echo -e "${GREEN}Installing apt...${NC}"
    apt-get install ufw -y
    apt-get install -yqq --no-install-recommends ca-certificates
    apt-get install fail2ban -y
    clean_apt true
    reboot_required
    echo -e "${GREEN}Successful${NC}"
    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##SSH PORT##
change_port() {
    if grep -qE "^#Port " "$SSHD_CONFIG"; then
        CURRENT_PORT=$(grep -E "^#Port " "$SSHD_CONFIG" | awk '{print $2}')
        echo -e "${YELLOW}Port is commented (current value: $CURRENT_PORT)${NC}"
        read -rp "$(echo -e "${GREEN}Uncomment and set new port? (y/n):${NC} ")" ANSWER
        if [[ "$ANSWER" =~ ^[nN]$ ]]; then
            echo -e "${YELLOW}Skipping${NC}"
            return 0
        elif ! [[ "$ANSWER" =~ ^[yY]$ ]]; then
            echo -e "${YELLOW}Invalid input${NC}"
            return 2
        fi
    elif grep -qE "^Port " "$SSHD_CONFIG"; then
        CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" | awk '{print $2}')
        echo -e "${GREEN}Current port: $CURRENT_PORT${NC}"
    else
        echo -e "${YELLOW}Port not found in $SSHD_CONFIG${NC}"
    fi

    read -rp "$(echo -e "${GREEN}Enter new port:${NC} ")" NEW_PORT

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        echo -e "${RED}Invalid port. Must be between 1 and 65535${NC}"
        return 1
    fi

    if [ "$NEW_PORT" = "$CURRENT_PORT" ]; then
        echo -e "${YELLOW}Port is already set to $NEW_PORT, skipping${NC}"
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
        return 0
    fi

    sed -i "s/^#\?Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
    echo -e "$TEXT_PORT_CHANGED"
    systemctl restart ssh sshd

    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##CREATE NEW USER AND ADD TO SUDO##
create_user() {
    read -rp "$(echo -e "${GREEN}Enter username:${NC} ")" USERNAME

    if id "$USERNAME" &>/dev/null; then
        echo -e "${YELLOW}User $USERNAME already exists${NC}"
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
        return 0
    fi

    read -rsp "$(echo -e "${GREEN}Enter password:${NC} ")" PASSWORD
    echo ""

    adduser --gecos "" "$USERNAME" <<EOF
$PASSWORD
$PASSWORD
EOF
    usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | tee /etc/sudoers.d/$USERNAME > /dev/null
    echo -e "${GREEN}User $USERNAME created and added to sudo${NC}"
    echo -e "${YELLOW}Login:    $USERNAME\nPassword: $PASSWORD"
    echo -e "${RED}Need to change profile -> 'su $USERNAME' and -> 'cd'${NC}"
    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##DISABLE ROOT##
disable_root_login() {
    if grep -qE "^PermitRootLogin no" "$SSHD_CONFIG"; then
        echo -e "${YELLOW}Root login already disabled${NC} "
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
        return 0
    elif grep -qE "^#PermitRootLogin" "$SSHD_CONFIG"; then
        sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" "$SSHD_CONFIG"
    elif grep -qE "^PermitRootLogin yes" "$SSHD_CONFIG"; then
        sed -i "s/^PermitRootLogin yes.*/PermitRootLogin no/" "$SSHD_CONFIG"
    else
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    fi

    systemctl restart ssh sshd 2>/dev/null
    echo -e "${YELLOW}Root login disabled${NC}"

    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##CREATE PUB KEY AND ACTIVATE##
setup_pubkey_auth() {
    read -rp "$(echo -e "${GREEN}Enter username:${NC} ")" USERNAME
    if ! id "$USERNAME" &>/dev/null; then
        echo -e "${RED}User $USERNAME not found${NC}"
        read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
        return 1
    fi
    SSH_DIR="/home/$USERNAME/.ssh"
    AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"

    if [ -d "/etc/ssh/sshd_config.d" ]; then
        rm -rf /etc/ssh/sshd_config.d
        mkdir /etc/ssh/sshd_config.d
        chmod 000 /etc/ssh/sshd_config.d
        echo -e "${GREEN}Removed and locked /etc/ssh/sshd_config.d${NC}"
    fi

    if grep -qE "^PasswordAuthentication no" "$SSHD_CONFIG" && grep -qE "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
        echo -e "${YELLOW}PubkeyAuthentication already configured${NC}"
        read -rp "$(echo -e "${GREEN}Change authorized_keys? (y/n):${NC} ")" ANSWER
        if [[ "$ANSWER" =~ ^[nN]$ ]]; then
            echo -e "${YELLOW}Skipping${NC}"
            return 0
        elif ! [[ "$ANSWER" =~ ^[yY]$ ]]; then
            echo -e "${RED}Invalid input${NC}"
            return 2
        fi
    fi

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

    systemctl restart ssh sshd 2>/dev/null
    echo -e "${GREEN}Activated auth with pub key${NC}"

    read -rp "$(echo -e "${GREEN}Reboot now? (y/n):${NC} ")" ANSWER
    case "$ANSWER" in
        [yY]*)
            echo -e "${GREEN}Rebooting...${NC}"
            reboot
            ;;
        [nN]*)
            read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
            return 0
            ;;
        *)
            echo -e "${RED}Invalid input${NC}"
            return 2
            ;;
    esac
}
##BBR##
enable_bbr() {
    echo -e "${GREEN}Enable BBR${NC}"

    add_if_missing() {
        local LINE="$1"
        local KEY=$(echo "$LINE" | awk -F'=' '{print $1}' | tr -d ' ')
        if grep -q "^$KEY" "$SYSCTL_CFG"; then
            echo -e "${YELLOW}Exists: $LINE${NC}"
        else
            echo "$LINE" >> "$SYSCTL_CFG"
            echo -e "${GREEN}Added: $LINE${NC}"
        fi
    }

    add_if_missing "net.core.default_qdisc=fq"
    add_if_missing "net.ipv4.tcp_congestion_control=bbr"
    add_if_missing "fs.file-max=2097152"
    add_if_missing "net.ipv4.tcp_timestamps = 1"
    add_if_missing "net.ipv4.tcp_sack = 1"
    add_if_missing "net.ipv4.tcp_window_scaling = 1"
    add_if_missing "net.core.rmem_max = 16777216"
    add_if_missing "net.core.wmem_max = 16777216"
    add_if_missing "net.ipv4.tcp_rmem = 4096 87380 16777216"
    add_if_missing "net.ipv4.tcp_wmem = 4096 65536 16777216"

    sysctl -p > /dev/null

    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##DOMAIN##
check_domain() {
    read -rp "$(echo -e "${GREEN}Enter the VPS domain:${NC} ")" DOMAIN

    VPS_IP=$(hostname -I | awk '{print $1}')
    DOMAIN_IP=$(dig +short "$DOMAIN" A | tail -1)

    echo -e "${GREEN}IP server : $VPS_IP${NC}"
    echo -e "${GREEN}IP domain : $DOMAIN_IP${NC}"

    if [ "$VPS_IP" = "$DOMAIN_IP" ]; then
        echo -e "${GREEN}Domain $DOMAIN is tied to VPS${NC}"
        return 0
    else
        echo -e "${RED}Domain $DOMAIN is not tied to VPS${NC}"
        read -rp "$(echo -e "${GREEN}Choose an action: (1) Continue  (2) Try again  (3) Exit:${NC} ")" CHOICE
        case "$CHOICE" in
            1)
                echo -e "${RED}Continue without domain${NC}"
                return 0
                ;;
            2)
                check_domain
                ;;
            3)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    fi

    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##IPV6##
disable_ipv6_ufw() {
    if [ ! -f "$UFW_CONF" ]; then
        echo -e "${RED}Error: file $UFW_CONF not found${NC}"
        return 1
    fi

    if grep -q "^IPV6=yes" "$UFW_CONF"; then
        sed -i 's/^IPV6=yes/IPV6=no/' "$UFW_CONF"
        echo -e "${GREEN}Done: IPV6 is disabled${NC}"
    else
        echo -e "${YELLOW}IPV6 is already disabled${NC}"
    fi

    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##RESET UFW AND IPTABLES##
reset_ufw(){
ufw disable
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
iptables -F
iptables -X
iptables -Z
read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##UFW##
setup_ufw() {
    read -rp "$(echo -e "${GREEN}Enter SSH port:${NC} ")" UFW_SSH_PORT
    read -rp "$(echo -e "${GREEN}Enter allowed IP for port 3000:${NC} ")" UFW_IP

    ufw allow "$UFW_SSH_PORT"/tcp
    ufw allow https
    ufw allow from "$UFW_IP" to any port 3000 proto tcp

    echo -e "${GREEN}UFW rules added${NC}"
    read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##IPTABLES##
iptables_rules(){
#Защита от DDoS - лимит новых соединений
iptables -A INPUT -p tcp --dport $UFW_SSH_PORT -m state --state NEW -m limit --limit 10/min --limit-burst 20 -j ACCEPT
iptables -A INPUT -p tcp --dport $UFW_SSH_PORT -m state --state NEW -j DROP
iptables -A INPUT -p tcp --dport 443 -m state --state NEW -m limit --limit 50/min --limit-burst 100 -j ACCEPT
#Защита от SYN flood
iptables -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
#Защита от port scanning
iptables -A INPUT -m state --state INVALID -j DROP
iptables -N PORT_SCAN
iptables -A PORT_SCAN -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -j RETURN
iptables -A PORT_SCAN -j DROP
#Блокировка ICMP (ping)
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
#Защита от спуфинга
iptables -A INPUT -s 10.0.0.0/8 -j DROP
iptables -A INPUT -s 172.16.0.0/12 -j DROP
iptables -A INPUT -s 192.168.0.0/16 -j DROP
iptables -A INPUT -s 169.254.0.0/16 -j DROP
iptables -A INPUT -s 224.0.0.0/4 -j DROP
iptables -A INPUT -s 255.255.255.255 -j DROP
iptables -A INPUT -s 127.0.0.0/8 ! -i lo -j DROP
#Разрешаем established соединения
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
#Ограничение скорости 200 мбит
iptables -A INPUT -m hashlimit \
--hashlimit-name conn_rate_limit \
--hashlimit-above 200mb/s \
--hashlimit-mode srcip \
--hashlimit-burst 300mb \
-j DROP
#Сохраняем правила iptables
if command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
fi
#Включаем ufw
ufw --force enable
#Включаем защиту в sysctl
add_if_missing() {
    local LINE="$1"
    local KEY=$(echo "$LINE" | awk -F'=' '{print $1}' | tr -d ' ')
    if ! grep -qE "^$KEY" /etc/sysctl.conf; then
        echo "$LINE" >> /etc/sysctl.conf
    fi
}

add_if_missing "net.ipv4.tcp_syncookies = 1"
add_if_missing "net.ipv4.conf.all.rp_filter = 1"
add_if_missing "net.ipv4.conf.default.rp_filter = 1"
add_if_missing "net.ipv4.icmp_echo_ignore_all = 1"
add_if_missing "net.ipv4.icmp_echo_ignore_broadcasts = 1"
add_if_missing "net.ipv4.conf.all.accept_redirects = 0"
add_if_missing "net.ipv4.conf.all.send_redirects = 0"
add_if_missing "net.ipv4.conf.all.accept_source_route = 0"
add_if_missing "net.ipv4.tcp_max_syn_backlog = 2048"
add_if_missing "net.ipv4.tcp_synack_retries = 2"
add_if_missing "net.ipv4.tcp_syn_retries = 5"
sysctl -p > /dev/null

ufw status

read -rp "$(echo -e "${GREEN}Press any key to continue...${NC}")" -n 1
}
##MAIN MENU##
menu() {
    clear
    echo ""
    echo -e "${GREEN}===== MENU =====${NC}"
    echo -e "${GREEN}1.  Update system${NC}"
    echo -e "${GREEN}2.  Clean apt${NC}"
    echo -e "${GREEN}3.  Install base packages${NC}"
    echo -e "${GREEN}4.  Change SSH port${NC}"
    echo -e "${GREEN}5.  Create user${NC}"
    echo -e "${GREEN}6.  Disable root login${NC}"
    echo -e "${GREEN}7.  Setup pubkey auth${NC}"
    echo -e "${GREEN}8.  Enable BBR${NC}"
    echo -e "${GREEN}9.  Check domain${NC}"
    echo -e "${GREEN}10. Disable IPv6 UFW${NC}"
    echo -e "${GREEN}11. Reset UFW and iptables${NC}"
    echo -e "${GREEN}12. Setup UFW rules${NC}"
    echo -e "${GREEN}13. Setup iptables rules${NC}"
    echo -e "${RED}0.  Exit${NC}"
    echo ""
    read -rp "$(echo -e "${GREEN}Choose:${NC} ")" CHOICE
    case "$CHOICE" in
        1)  clear; update ;;
        2)  clear; clean_apt ;;
        3)  clear; install_based ;;
        4)  clear; change_port ;;
        5)  clear; create_user ;;
        6)  clear; disable_root_login ;;
        7)  clear; setup_pubkey_auth ;;
        8)  clear; enable_bbr ;;
        9)  clear; check_domain ;;
        10) clear; disable_ipv6_ufw ;;
        11) clear; reset_ufw ;;
        12) clear; setup_ufw ;;
        13) clear; iptables_rules ;;
        0)
            echo -e "${RED}Exit${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            ;;
    esac
    menu
}

enable_root
reboot_required
menu
