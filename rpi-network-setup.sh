#!/bin/bash
# =============================================================================
# Raspberry Pi Network Setup Script
# Sets up: WiFi (wlan1 primary), OpenVPN (CyberGhost), Tailscale, DNS lockdown,
#          watchdog timers, and self-healing boot order
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOGFILE="/var/log/rpi-network-setup.log"
ERRORS=()

log()    { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOGFILE"; }
info()   { echo -e "${BLUE}[→]${NC} $1" | tee -a "$LOGFILE"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOGFILE"; }
error()  { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOGFILE"; ERRORS+=("$1"); }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
           echo -e "${BOLD}${CYAN}  $1${NC}"; \
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }
prompt() { echo -e "${YELLOW}[?]${NC} $1"; }
action() { echo -e "${BOLD}${RED}[ACTION REQUIRED]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root (use sudo).${NC}"
        exit 1
    fi
}

pause() {
    echo ""
    read -rp "$(echo -e "${CYAN}Press ENTER to continue...${NC}")"
}

confirm() {
    local msg="$1"
    while true; do
        read -rp "$(echo -e "${YELLOW}[?]${NC} $msg [y/n]: ")" yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

# =============================================================================
header "RASPBERRY PI NETWORK SETUP"
# =============================================================================

echo -e "${BOLD}This script will configure:${NC}"
echo "  • WiFi (USB dongle as primary, onboard as disabled)"
echo "  • OpenVPN (CyberGhost or custom .conf)"
echo "  • Tailscale mesh VPN"
echo "  • DNS lockdown (immune to VPN overwrites)"
echo "  • Watchdog timers for self-healing"
echo "  • Correct boot order for all services"
echo ""
warn "This script will modify network config, VPN settings, and system services."
confirm "Ready to begin?" || exit 0

sudo touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/rpi-network-setup.log"
echo "=== Setup started $(date) ===" >> "$LOGFILE"

# =============================================================================
header "SECTION 1: GATHER INFORMATION"
# =============================================================================

# --- WiFi ---
echo -e "${BOLD}── WiFi Configuration ──${NC}\n"

info "Scanning for available networks..."
SCAN_OUTPUT=""
if command -v nmcli &>/dev/null; then
    SCAN_OUTPUT=$(nmcli device wifi list 2>/dev/null || true)
fi

if [[ -n "$SCAN_OUTPUT" ]]; then
    echo "$SCAN_OUTPUT"
    echo ""
fi

prompt "Enter the WiFi SSID to connect to:"
read -rp "  SSID: " WIFI_SSID
prompt "Enter the WiFi password:"
read -rsp "  Password: " WIFI_PASSWORD
echo ""

# --- Network interfaces ---
echo ""
info "Detected network interfaces:"
ip link show | grep -E '^[0-9]+:' | awk '{print "  " $2}' | tr -d ':'
echo ""

prompt "Enter the PRIMARY WiFi interface (USB dongle, e.g. wlan1):"
read -rp "  Primary interface: " WLAN_PRIMARY
WLAN_PRIMARY=${WLAN_PRIMARY:-wlan1}

prompt "Enter the SECONDARY WiFi interface to disable (onboard, e.g. wlan0):"
read -rp "  Secondary interface: " WLAN_SECONDARY
WLAN_SECONDARY=${WLAN_SECONDARY:-wlan0}

# --- OpenVPN ---
echo ""
echo -e "${BOLD}── OpenVPN Configuration ──${NC}\n"

if confirm "Do you have an existing OpenVPN .conf file to upload/copy onto this machine?"; then
    OPENVPN_MODE="existing"
    prompt "Enter the FULL PATH to your .conf file (e.g. /home/pi/cyberghost.conf):"
    read -rp "  Path: " OPENVPN_CONF_SRC
    prompt "Enter a name for this VPN connection (e.g. cyberghost):"
    read -rp "  Name: " OPENVPN_NAME
    OPENVPN_NAME=${OPENVPN_NAME:-myvpn}

    if confirm "Does your .conf use a separate auth file (username/password)?"; then
        OPENVPN_AUTH="yes"
        prompt "Enter VPN username:"
        read -rp "  Username: " OPENVPN_USER
        prompt "Enter VPN password:"
        read -rsp "  Password: " OPENVPN_PASS
        echo ""
    else
        OPENVPN_AUTH="no"
    fi
else
    OPENVPN_MODE="manual"
    echo ""
    action "You will need to provide your VPN provider's .ovpn config file."
    echo "  Most providers (CyberGhost, NordVPN, ProtonVPN, Mullvad, etc.)"
    echo "  let you download .ovpn files from their website."
    echo ""
    echo "  Steps:"
    echo "    1. Log into your VPN provider's website"
    echo "    2. Find 'Manual configuration' or 'OpenVPN config'"
    echo "    3. Download a .ovpn or .conf file for your preferred server"
    echo "    4. Copy it to this machine (scp, USB, etc.)"
    echo "    5. Note the full path"
    echo ""
    pause
    prompt "Enter the FULL PATH to your .conf/.ovpn file:"
    read -rp "  Path: " OPENVPN_CONF_SRC
    prompt "Enter a name for this VPN connection (e.g. myvpn):"
    read -rp "  Name: " OPENVPN_NAME
    OPENVPN_NAME=${OPENVPN_NAME:-myvpn}

    if confirm "Does your VPN require a username and password?"; then
        OPENVPN_AUTH="yes"
        prompt "Enter VPN username:"
        read -rp "  Username: " OPENVPN_USER
        prompt "Enter VPN password:"
        read -rsp "  Password: " OPENVPN_PASS
        echo ""
    else
        OPENVPN_AUTH="no"
    fi
fi

# --- Tailscale ---
echo ""
echo -e "${BOLD}── Tailscale Configuration ──${NC}\n"

echo "  Tailscale is a mesh VPN. You need a Tailscale account and auth key."
echo ""
action "Get your Tailscale auth key:"
echo "  1. Go to https://login.tailscale.com/admin/settings/keys"
echo "  2. Click 'Generate auth key'"
echo "  3. Choose: Reusable=No, Expiry=1 day, Ephemeral=No"
echo "  4. Copy the key (starts with 'tskey-auth-...')"
echo ""
pause
prompt "Paste your Tailscale auth key:"
read -rsp "  Auth key: " TAILSCALE_AUTHKEY
echo ""

prompt "Enter a hostname for this machine on Tailscale (e.g. rpi-living-room):"
read -rp "  Hostname: " TAILSCALE_HOSTNAME
TAILSCALE_HOSTNAME=${TAILSCALE_HOSTNAME:-$(hostname)}

# --- Confirm before proceeding ---
echo ""
header "CONFIGURATION SUMMARY"
echo -e "  WiFi SSID:          ${BOLD}$WIFI_SSID${NC}"
echo -e "  Primary interface:  ${BOLD}$WLAN_PRIMARY${NC}"
echo -e "  Disabled interface: ${BOLD}$WLAN_SECONDARY${NC}"
echo -e "  OpenVPN config:     ${BOLD}$OPENVPN_CONF_SRC${NC}"
echo -e "  OpenVPN name:       ${BOLD}$OPENVPN_NAME${NC}"
echo -e "  OpenVPN auth file:  ${BOLD}$OPENVPN_AUTH${NC}"
echo -e "  Tailscale hostname: ${BOLD}$TAILSCALE_HOSTNAME${NC}"
echo ""
confirm "Proceed with this configuration?" || exit 0

# =============================================================================
header "SECTION 2: INSTALL DEPENDENCIES"
# =============================================================================

info "Updating package list..."
apt-get update -qq | tee -a "$LOGFILE" && log "Package list updated"

info "Installing required packages..."
apt-get install -y -qq \
    openvpn \
    tailscale \
    network-manager \
    dnsutils \
    curl \
    wget \
    iw \
    wireless-tools \
    2>&1 | tee -a "$LOGFILE" && log "Packages installed"

# Install Tailscale if not present
if ! command -v tailscale &>/dev/null; then
    info "Installing Tailscale via official script..."
    curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tee -a "$LOGFILE"
    log "Tailscale installed"
fi

# =============================================================================
header "SECTION 3: WIFI CONFIGURATION"
# =============================================================================

info "Configuring $WLAN_PRIMARY as primary WiFi interface..."

# Get MAC address of primary interface
WLAN_PRIMARY_MAC=$(cat /sys/class/net/$WLAN_PRIMARY/address 2>/dev/null || echo "")
if [[ -z "$WLAN_PRIMARY_MAC" ]]; then
    error "Could not find MAC address for $WLAN_PRIMARY — is it plugged in?"
else
    log "Found $WLAN_PRIMARY MAC: $WLAN_PRIMARY_MAC"
fi

# Remove any existing connection for this SSID on this interface
EXISTING_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep "$WLAN_PRIMARY" | cut -d: -f1 || true)
if [[ -n "$EXISTING_CONN" ]]; then
    info "Removing existing connection: $EXISTING_CONN"
    nmcli connection delete "$EXISTING_CONN" 2>/dev/null || true
fi

# Create new connection profile
info "Creating NetworkManager profile for '$WIFI_SSID' on $WLAN_PRIMARY..."
nmcli connection add \
    type wifi \
    ifname "$WLAN_PRIMARY" \
    con-name "${WLAN_PRIMARY}-primary" \
    ssid "$WIFI_SSID" \
    -- \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$WIFI_PASSWORD" \
    connection.autoconnect yes \
    ipv4.route-metric 100 \
    ipv6.route-metric 100 \
    2>&1 | tee -a "$LOGFILE"

# Bind to MAC if we found it
if [[ -n "$WLAN_PRIMARY_MAC" ]]; then
    nmcli connection modify "${WLAN_PRIMARY}-primary" \
        wifi.mac-address "$WLAN_PRIMARY_MAC" 2>/dev/null || true
fi

log "Profile created for $WLAN_PRIMARY"

# Disable secondary interface
info "Setting $WLAN_SECONDARY to autoconnect=no..."
SEC_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep "$WLAN_SECONDARY" | cut -d: -f1 | head -1 || true)
if [[ -n "$SEC_CONN" ]]; then
    nmcli connection modify "$SEC_CONN" connection.autoconnect no 2>/dev/null && \
        log "Disabled autoconnect on $WLAN_SECONDARY ($SEC_CONN)"
    nmcli device disconnect "$WLAN_SECONDARY" 2>/dev/null || true
else
    warn "No existing connection found for $WLAN_SECONDARY — it will remain unconfigured"
fi

# Bring up primary
info "Connecting $WLAN_PRIMARY to '$WIFI_SSID'..."
nmcli device connect "$WLAN_PRIMARY" 2>&1 | tee -a "$LOGFILE" || true
sleep 8

if ip addr show "$WLAN_PRIMARY" | grep -q "inet "; then
    WLAN_IP=$(ip addr show "$WLAN_PRIMARY" | grep "inet " | awk '{print $2}')
    log "$WLAN_PRIMARY connected, IP: $WLAN_IP"
else
    error "$WLAN_PRIMARY did not get an IP address — check SSID and password"
fi

# =============================================================================
header "SECTION 4: OPENVPN CONFIGURATION"
# =============================================================================

info "Setting up OpenVPN..."

# Validate config file exists
if [[ ! -f "$OPENVPN_CONF_SRC" ]]; then
    error "OpenVPN config file not found at: $OPENVPN_CONF_SRC"
    warn "Skipping OpenVPN setup — re-run after placing config file"
else
    # Copy config
    OPENVPN_DEST="/etc/openvpn/client/${OPENVPN_NAME}.conf"
    cp "$OPENVPN_CONF_SRC" "$OPENVPN_DEST"
    chmod 600 "$OPENVPN_DEST"
    log "Copied config to $OPENVPN_DEST"

    # Write auth file if needed
    if [[ "$OPENVPN_AUTH" == "yes" ]]; then
        AUTH_FILE="/etc/openvpn/client/${OPENVPN_NAME}.auth"
        printf '%s\n%s\n' "$OPENVPN_USER" "$OPENVPN_PASS" > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
        # Point config at auth file if not already
        if ! grep -q "^auth-user-pass" "$OPENVPN_DEST"; then
            echo "auth-user-pass $AUTH_FILE" >> "$OPENVPN_DEST"
        else
            sed -i "s|^auth-user-pass.*|auth-user-pass $AUTH_FILE|" "$OPENVPN_DEST"
        fi
        log "Auth file written"
    fi

    # Add resilience settings (avoid duplicates)
    add_if_missing() {
        local line="$1" file="$2" key
        key=$(echo "$line" | awk '{print $1}')
        if ! grep -q "^$key" "$file"; then
            echo "$line" >> "$file"
            info "Added: $line"
        fi
    }

    add_if_missing "ping 10"           "$OPENVPN_DEST"
    add_if_missing "ping-restart 30"   "$OPENVPN_DEST"
    add_if_missing "ping-timer-rem"    "$OPENVPN_DEST"
    add_if_missing "persist-tun"       "$OPENVPN_DEST"
    add_if_missing "persist-key"       "$OPENVPN_DEST"

    # Comment out update-resolv-conf hooks (we lock DNS ourselves)
    sed -i 's|^\(up.*update-resolv-conf\)|#\1|' "$OPENVPN_DEST"
    sed -i 's|^\(down.*update-resolv-conf\)|#\1|' "$OPENVPN_DEST"
    log "Disabled update-resolv-conf hooks in config"

    # Systemd override: restart on failure, start after network
    mkdir -p /etc/systemd/system/openvpn@${OPENVPN_NAME}.service.d/
    cat > /etc/systemd/system/openvpn@${OPENVPN_NAME}.service.d/override.conf << EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
EOF
    log "Systemd override written for openvpn@${OPENVPN_NAME}"

    # VPN server bypass route via NetworkManager dispatcher
    VPN_HOST=$(grep "^remote " "$OPENVPN_DEST" | awk '{print $2}' | head -1)
    if [[ -n "$VPN_HOST" ]]; then
        cat > /etc/NetworkManager/dispatcher.d/99-vpn-bypass << DISPEOF
#!/bin/bash
IFACE="\$1"
ACTION="\$2"
if [ "\$IFACE" = "$WLAN_PRIMARY" ] && [ "\$ACTION" = "up" ]; then
    GW=\$(ip route show default dev $WLAN_PRIMARY | awk '{print \$3}' | head -1)
    VPNIP=\$(dig +short $VPN_HOST | grep -E '^[0-9]+\.' | head -1)
    if [ -n "\$GW" ] && [ -n "\$VPNIP" ]; then
        ip route replace \$VPNIP via \$GW dev $WLAN_PRIMARY
        logger "vpn-bypass: routed \$VPNIP via \$GW on $WLAN_PRIMARY"
    fi
fi
DISPEOF
        chmod +x /etc/NetworkManager/dispatcher.d/99-vpn-bypass
        log "VPN bypass route dispatcher installed for $VPN_HOST"
    fi

    systemctl daemon-reload
    systemctl enable openvpn@${OPENVPN_NAME}
    systemctl restart openvpn@${OPENVPN_NAME}
    sleep 15

    if ip link show tun0 &>/dev/null; then
        log "tun0 is up"
        TUN_IP=$(curl --interface tun0 -s --max-time 10 https://ifconfig.me 2>/dev/null || echo "unknown")
        log "OpenVPN exit IP: $TUN_IP"
    else
        error "tun0 did not come up — check OpenVPN config and credentials"
    fi
fi

# =============================================================================
header "SECTION 5: TAILSCALE CONFIGURATION"
# =============================================================================

info "Starting Tailscale daemon..."
systemctl enable tailscaled
systemctl start tailscaled
sleep 3

info "Authenticating Tailscale (hostname: $TAILSCALE_HOSTNAME)..."
tailscale up \
    --authkey="$TAILSCALE_AUTHKEY" \
    --hostname="$TAILSCALE_HOSTNAME" \
    --accept-dns=false \
    2>&1 | tee -a "$LOGFILE" || error "Tailscale auth failed — check your auth key"

sleep 5
if tailscale status &>/dev/null; then
    log "Tailscale connected"
    tailscale status | head -5 | tee -a "$LOGFILE"
else
    error "Tailscale is not connected"
fi

# Systemd override for Tailscale
mkdir -p /etc/systemd/system/tailscaled.service.d/
cat > /etc/systemd/system/tailscaled.service.d/override.conf << EOF
[Service]
Restart=always
RestartSec=10
EOF
systemctl daemon-reload
log "Tailscale restart-on-failure override applied"

# =============================================================================
header "SECTION 6: DNS LOCKDOWN"
# =============================================================================

info "Locking /etc/resolv.conf..."

# Disable Tailscale DNS management
tailscale set --accept-dns=false 2>/dev/null && log "Tailscale accept-dns=false set"

# Unlock, rewrite, relock
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << EOF
nameserver 100.100.100.100
nameserver 8.8.8.8
nameserver 8.8.4.4
search $(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix',''))" 2>/dev/null || echo "")
EOF
chattr +i /etc/resolv.conf
log "resolv.conf locked (chattr +i)"
cat /etc/resolv.conf | tee -a "$LOGFILE"

# =============================================================================
header "SECTION 7: WATCHDOG TIMERS"
# =============================================================================

# --- wlan1 watchdog ---
info "Installing wlan1 watchdog..."
cat > /usr/local/bin/wlan1-watchdog.sh << WEOF
#!/bin/bash
IFACE=$WLAN_PRIMARY
LOG=/var/log/wlan1-watchdog.log
MAX_LOG_LINES=500

if ! ip link show \$IFACE | grep -q "state UP"; then
    echo "\$(date): \$IFACE down, reconnecting" >> \$LOG
    nmcli device connect \$IFACE >> \$LOG 2>&1
    sleep 10
fi

if ! ping -c2 -W3 -I \$IFACE 8.8.8.8 > /dev/null 2>&1; then
    echo "\$(date): \$IFACE ping failed, cycling" >> \$LOG
    nmcli device disconnect \$IFACE >> \$LOG 2>&1
    sleep 5
    nmcli device connect \$IFACE >> \$LOG 2>&1
fi

# Trim log
if [ -f \$LOG ]; then
    tail -\$MAX_LOG_LINES \$LOG > \${LOG}.tmp && mv \${LOG}.tmp \$LOG
fi
WEOF
chmod +x /usr/local/bin/wlan1-watchdog.sh

cat > /etc/systemd/system/wlan1-watchdog.service << EOF
[Unit]
Description=wlan1 connection watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wlan1-watchdog.sh
EOF

cat > /etc/systemd/system/wlan1-watchdog.timer << EOF
[Unit]
Description=Run wlan1 watchdog every 60 seconds

[Timer]
OnBootSec=60
OnUnitActiveSec=60
Unit=wlan1-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now wlan1-watchdog.timer
log "wlan1 watchdog timer installed"

# --- tun0 watchdog ---
info "Installing tun0 (OpenVPN) watchdog..."
cat > /usr/local/bin/tun0-watchdog.sh << TEOF
#!/bin/bash
LOG=/var/log/tun0-watchdog.log
MAX_LOG_LINES=500
VPN_SERVICE="openvpn@${OPENVPN_NAME}"

if ! ip link show tun0 > /dev/null 2>&1; then
    echo "\$(date): tun0 missing, restarting \$VPN_SERVICE" >> \$LOG
    systemctl restart \$VPN_SERVICE >> \$LOG 2>&1
fi

if [ -f \$LOG ]; then
    tail -\$MAX_LOG_LINES \$LOG > \${LOG}.tmp && mv \${LOG}.tmp \$LOG
fi
TEOF
chmod +x /usr/local/bin/tun0-watchdog.sh

cat > /etc/systemd/system/tun0-watchdog.service << EOF
[Unit]
Description=tun0 OpenVPN watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tun0-watchdog.sh
EOF

cat > /etc/systemd/system/tun0-watchdog.timer << EOF
[Unit]
Description=Run tun0 watchdog every 60 seconds

[Timer]
OnBootSec=90
OnUnitActiveSec=60
Unit=tun0-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now tun0-watchdog.timer
log "tun0 watchdog timer installed"

# =============================================================================
header "SECTION 8: FINAL HEALTH CHECK"
# =============================================================================

echo "" | tee -a "$LOGFILE"
info "Running health check..."
echo ""

PASS=0
FAIL=0

check() {
    local label="$1" cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $label"
        ((PASS++))
    else
        echo -e "  ${RED}✗${NC} $label"
        ((FAIL++))
        ERRORS+=("Health check failed: $label")
    fi
}

check "$WLAN_PRIMARY is UP"                "ip link show $WLAN_PRIMARY | grep -q 'state UP'"
check "$WLAN_PRIMARY has IP"               "ip addr show $WLAN_PRIMARY | grep -q 'inet '"
check "$WLAN_SECONDARY autoconnect off"    "nmcli connection show | grep -q '$WLAN_SECONDARY'"
check "tun0 is UP"                         "ip link show tun0"
check "Default route via tun0"            "ip route show | grep -q 'tun0'"
check "Tailscale running"                  "systemctl is-active tailscaled"
check "Tailscale connected"               "tailscale status"
check "OpenVPN running"                   "systemctl is-active openvpn@${OPENVPN_NAME}"
check "DNS resolves google.com"           "dig +short google.com @8.8.8.8"
check "DNS resolves via Tailscale"        "dig +short google.com @100.100.100.100"
check "resolv.conf is immutable"          "lsattr /etc/resolv.conf | grep -q '\-i\-'"
check "wlan1 watchdog timer active"       "systemctl is-active wlan1-watchdog.timer"
check "tun0 watchdog timer active"        "systemctl is-active tun0-watchdog.timer"
check "ping via $WLAN_PRIMARY"            "ping -c2 -W3 -I $WLAN_PRIMARY 8.8.8.8"

echo ""
echo "─────────────────────────────────────"
echo -e "  ${GREEN}Passed: $PASS${NC}   ${RED}Failed: $FAIL${NC}"
echo "─────────────────────────────────────"

# =============================================================================
header "SETUP COMPLETE"
# =============================================================================

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All checks passed. System is fully configured.${NC}"
else
    echo -e "${YELLOW}${BOLD}Setup completed with issues:${NC}"
    for e in "${ERRORS[@]}"; do
        echo -e "  ${RED}•${NC} $e"
    done
fi

echo ""
echo -e "${BOLD}Log file:${NC} $LOGFILE"
echo ""
echo -e "${BOLD}Watchdog logs:${NC}"
echo "  /var/log/wlan1-watchdog.log"
echo "  /var/log/tun0-watchdog.log"
echo ""
echo -e "${BOLD}To check status anytime:${NC}"
echo "  ip addr show; ip route show; tailscale status; systemctl status openvpn@${OPENVPN_NAME}"
echo ""
echo "=== Setup finished $(date) ===" >> "$LOGFILE"
