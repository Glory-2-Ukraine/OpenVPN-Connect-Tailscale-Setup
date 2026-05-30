# OpenVPN + Tailscale + WiFi Setup for Raspberry Pi

Automated setup script for a self-healing Raspberry Pi network node with:

- **Primary WiFi** via USB dongle (`wlan1`) — better range, higher priority
- **OpenVPN** (CyberGhost or any provider) routing internet traffic through `tun0`
- **Tailscale** mesh VPN for secure peer-to-peer access across all your nodes
- **Locked DNS** — immune to overwrites from either VPN
- **Watchdog timers** — automatic recovery if WiFi or VPN drops
- **Correct boot order** — everything comes up cleanly after a reboot

---

## Requirements

| Requirement | Notes |
|---|---|
| Raspberry Pi (any model) | Tested on Pi 4 and Pi 5 |
| Raspberry Pi OS (Bookworm/Debian 12) | Or any Debian-based distro |
| USB WiFi dongle | Used as primary interface (`wlan1`) |
| OpenVPN `.conf` or `.ovpn` file | From your VPN provider |
| Tailscale account | Free at [tailscale.com](https://tailscale.com) |
| Root / sudo access | Script must run as root |

---

## Quick Start

```bash
# Download the script
curl -O https://raw.githubusercontent.com/Glory-2-Ukraine/OpenVPN-Connect-Tailscale-Setup/main/rpi-network-setup.sh

# Make it executable
chmod +x rpi-network-setup.sh

# Run as root
sudo ./rpi-network-setup.sh
```

The script is fully interactive — it will ask for everything it needs and tell you where to get it.

---

## What the Script Configures

### 1. WiFi
- Scans and displays available networks
- Connects your USB dongle (`wlan1`) to your chosen SSID with metric 100 (highest priority)
- Binds the profile to the dongle's MAC address so it never accidentally applies to onboard WiFi
- Sets onboard WiFi (`wlan0`) to `autoconnect=no` — disabled but available as manual fallback

### 2. OpenVPN
- Copies your `.conf` or `.ovpn` file to `/etc/openvpn/client/`
- Writes a secure auth file if your VPN requires username/password
- Adds resilience settings: `ping 10`, `ping-restart 30`, `persist-tun`, `persist-key`
- Installs a NetworkManager dispatcher that adds a static bypass route for the VPN server IP — **prevents the routing deadlock** that occurs when tun0 and wlan1 go down simultaneously
- Disables `update-resolv-conf` hooks so OpenVPN cannot overwrite your DNS
- Configures systemd to restart OpenVPN automatically on failure (`Restart=always`)

### 3. Tailscale
- Installs Tailscale if not already present
- Authenticates using your auth key with your chosen hostname
- Sets `--accept-dns=false` so Tailscale does not take over `/etc/resolv.conf`
- Configures systemd restart-on-failure

### 4. DNS Lockdown
- Writes `/etc/resolv.conf` with:
  - `100.100.100.100` — Tailscale's resolver (for `.ts.net` hostnames)
  - `8.8.8.8` and `8.8.4.4` — Google DNS fallbacks
- Locks the file with `chattr +i` — neither OpenVPN nor Tailscale can overwrite it

### 5. Watchdog Timers
Two systemd timers run every 60 seconds:

| Timer | What it monitors | What it does |
|---|---|---|
| `wlan1-watchdog` | `wlan1` link state + ping to 8.8.8.8 | Reconnects via NetworkManager if down |
| `tun0-watchdog` | `tun0` interface existence | Restarts OpenVPN service if missing |

Logs are written to `/var/log/wlan1-watchdog.log` and `/var/log/tun0-watchdog.log` and automatically trimmed to 500 lines.

### 6. Boot Order
Systemd overrides ensure services start in the correct order:
```
network-online.target → tailscaled → openvpn@<name>
```

---

## What You Will Need Before Running

### OpenVPN Config File
Download a `.ovpn` or `.conf` file from your VPN provider:

| Provider | Download location |
|---|---|
| CyberGhost | Account → Devices → Manual Setup → OpenVPN |
| NordVPN | [nordvpn.com/ovpn](https://nordvpn.com/ovpn/) |
| ProtonVPN | Account → Downloads → OpenVPN configuration files |
| Mullvad | [mullvad.net/download/openvpn-config](https://mullvad.net/download/openvpn-config) |
| ExpressVPN | Account → Set up ExpressVPN → Manual Config → OpenVPN |

Copy the file to your Pi before running the script:
```bash
scp your-vpn-config.ovpn pi@<pi-ip>:/home/pi/
```

### Tailscale Auth Key
1. Go to [https://login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key**
3. Settings: Reusable = No, Expiry = 1 day, Ephemeral = No, Tags = optional
4. Copy the key — it starts with `tskey-auth-...`

> **Note:** Auth keys expire. Generate one immediately before running the script.

---

## Architecture

```
Internet
    │
    ▼
[MyOptimum WiFi AP]
    │
    ▼
wlan1 (USB dongle) ──── primary, metric 100
wlan0 (onboard)    ──── disabled, manual fallback only
    │
    ▼
tun0 (OpenVPN/CyberGhost) ──── routes 0.0.0.0/1 + 128.0.0.0/1
    │
    ├── Internet traffic exits via VPN exit IP
    │
tailscale0 ──── mesh VPN, direct peer connections
    │
    └── Peer access to other nodes in your Tailnet
```

**DNS resolution order:**
1. `100.100.100.100` — resolves `.ts.net` hostnames + forwards everything else
2. `8.8.8.8` / `8.8.4.4` — fallback if Tailscale resolver is unreachable

---

## Health Check

After setup, verify everything with:

```bash
# Interfaces and IPs
ip addr show wlan0 wlan1

# Routing table (should show tun0 routes)
ip route show

# DNS config (should be locked)
cat /etc/resolv.conf
lsattr /etc/resolv.conf

# OpenVPN exit IP
curl --interface tun0 -s https://ifconfig.me

# Tailscale peers
sudo tailscale status

# Watchdog timers
systemctl list-timers wlan1-watchdog tun0-watchdog

# DNS resolution
dig google.com
dig <your-hostname>.ts.net
```

---

## Troubleshooting

### wlan1 won't connect
```bash
# Check the dongle is recognized
ip link show wlan1
lsusb

# Scan for your network
sudo iwlist wlan1 scan | grep ESSID

# Check NetworkManager profile
nmcli connection show
nmcli device status
```

### tun0 not coming up
```bash
# Check OpenVPN logs
journalctl -u openvpn@<name> -n 50 --no-pager

# Verify config file
sudo cat /etc/openvpn/client/<name>.conf | grep -v -E 'BEGIN|END|^[A-Za-z0-9+/]{40}'

# Try manually
sudo openvpn --config /etc/openvpn/client/<name>.conf
```

### Tailscale not connecting
```bash
# Check status
sudo tailscale status

# Re-authenticate
sudo tailscale up --authkey=<new-key> --hostname=<name> --accept-dns=false

# Check daemon logs
journalctl -u tailscaled -n 50 --no-pager
```

### DNS getting overwritten
```bash
# Check if still locked
lsattr /etc/resolv.conf   # should show ----i----

# Re-lock if needed
sudo chattr -i /etc/resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 100.100.100.100
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
sudo chattr +i /etc/resolv.conf
```

### Routing deadlock after VPN server drop
This is prevented by the bypass route dispatcher. If it occurs anyway:
```bash
# Check bypass route exists
ip route show | grep <vpn-server-ip>

# Manually trigger dispatcher
sudo /etc/NetworkManager/dispatcher.d/99-vpn-bypass wlan1 up

# Then restart OpenVPN
sudo systemctl restart openvpn@<name>
```

---

## File Locations

| File | Purpose |
|---|---|
| `/etc/openvpn/client/<name>.conf` | OpenVPN configuration |
| `/etc/openvpn/client/<name>.auth` | VPN credentials |
| `/etc/NetworkManager/dispatcher.d/99-vpn-bypass` | Bypass route on wlan1 up |
| `/etc/systemd/system/openvpn@<name>.service.d/override.conf` | OpenVPN restart policy |
| `/etc/systemd/system/tailscaled.service.d/override.conf` | Tailscale restart policy |
| `/usr/local/bin/wlan1-watchdog.sh` | WiFi watchdog script |
| `/usr/local/bin/tun0-watchdog.sh` | VPN watchdog script |
| `/etc/systemd/system/wlan1-watchdog.timer` | WiFi watchdog timer |
| `/etc/systemd/system/tun0-watchdog.timer` | VPN watchdog timer |
| `/var/log/rpi-network-setup.log` | Setup log |
| `/var/log/wlan1-watchdog.log` | WiFi watchdog log |
| `/var/log/tun0-watchdog.log` | VPN watchdog log |

---

## Re-running on an Existing Machine

The script is safe to re-run. It:
- Removes and recreates the NetworkManager profile cleanly
- Does not duplicate settings already present in the OpenVPN config
- Unlocks `resolv.conf` before rewriting, then re-locks it
- Overwrites watchdog scripts with the latest version

---

## License

MIT License — use freely, modify as needed.

---

*Part of the [Glory-2-Ukraine](https://github.com/Glory-2-Ukraine) infrastructure toolkit.*
