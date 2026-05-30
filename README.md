# OpenVPN + Tailscale + Raspberry Pi Connect Setup

Automated setup script for a self-healing Raspberry Pi network node with:

- **Primary WiFi** via USB dongle (`wlan1`) — better range, highest priority
- **OpenVPN** (CyberGhost or any provider) routing internet traffic through `tun0`
- **Tailscale** mesh VPN for secure peer-to-peer access across all your nodes
- **Raspberry Pi Connect** for remote desktop and shell access via browser
- **Locked DNS** — immune to overwrites from any VPN
- **Watchdog timers** — automatic recovery if WiFi, VPN, or Connect drops
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
| Raspberry Pi ID | Free at [id.raspberrypi.com](https://id.raspberrypi.com) |
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

The script is fully interactive — it asks for everything it needs and tells you where to get it.

---

## What the Script Configures

### 1. WiFi
- Scans and displays available networks
- Connects your USB dongle (`wlan1`) to your chosen SSID at metric 100 (highest priority)
- Binds the profile to the dongle's MAC address so it never accidentally applies to onboard WiFi
- Sets onboard WiFi (`wlan0`) to `autoconnect=no` — disabled but available as manual fallback

### 2. OpenVPN
- Copies your `.conf` or `.ovpn` file to `/etc/openvpn/client/`
- Writes a secure auth file if your VPN requires username/password
- Adds resilience settings: `ping 10`, `ping-restart 30`, `persist-tun`, `persist-key`
- Installs a NetworkManager dispatcher that adds a static bypass route for the VPN server IP — prevents the routing deadlock when tun0 and wlan1 go down simultaneously
- Disables `update-resolv-conf` hooks so OpenVPN cannot overwrite your DNS
- Configures systemd to restart OpenVPN automatically on failure

### 3. Tailscale
- Installs Tailscale if not already present
- Authenticates using your auth key with your chosen hostname
- Sets `--accept-dns=false` so Tailscale does not overwrite `/etc/resolv.conf`
- Configures systemd restart-on-failure
- Works alongside OpenVPN — each operates independently on its own interface

### 4. Raspberry Pi Connect
- Installs `rpi-connect` (full desktop) or `rpi-connect-lite` (headless/shell only)
- Enables and starts the service with restart-on-failure configured
- Installs a watchdog timer that checks and restarts the service every 60 seconds
- Prompts you to run `rpi-connect signin` to link the device to your Raspberry Pi ID
- Operates independently of Tailscale and OpenVPN — uses Raspberry Pi's own relay

### 5. DNS Lockdown
- Writes `/etc/resolv.conf` with:
  - `100.100.100.100` — Tailscale's resolver (for `.ts.net` hostnames)
  - `8.8.8.8` and `8.8.4.4` — Google DNS fallbacks
- Locks the file with `chattr +i` — neither OpenVPN nor Tailscale can overwrite it

### 6. Watchdog Timers
Three systemd timers run every 60 seconds:

| Timer | Monitors | Action on failure |
|---|---|---|
| `wlan1-watchdog` | `wlan1` link state + ping to 8.8.8.8 | Reconnects via NetworkManager |
| `tun0-watchdog` | `tun0` interface existence | Restarts OpenVPN service |
| `rpi-connect-watchdog` | `rpi-connect` service state | Restarts rpi-connect service |

Logs are written to `/var/log/<name>-watchdog.log` and automatically trimmed to 500 lines.

### 7. Boot Order
Systemd overrides ensure services start in the correct sequence:
```
network-online.target → tailscaled → openvpn@<name>
                      → rpi-connect (independent)
```

---

## What You Need Before Running

### OpenVPN Config File
Download a `.ovpn` or `.conf` file from your VPN provider:

| Provider | Download location |
|---|---|
| CyberGhost | Account → Devices → Manual Setup → OpenVPN |
| NordVPN | [nordvpn.com/ovpn](https://nordvpn.com/ovpn/) |
| ProtonVPN | Account → Downloads → OpenVPN configuration files |
| Mullvad | [mullvad.net/download/openvpn-config](https://mullvad.net/download/openvpn-config) |
| ExpressVPN | Account → Set up ExpressVPN → Manual Config → OpenVPN |

Copy the file to your Pi before running:
```bash
scp your-vpn-config.ovpn pi@<pi-ip>:/home/pi/
```

### Tailscale Auth Key
1. Go to [https://login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key**
3. Settings: Reusable = No, Expiry = 1 day, Ephemeral = No
4. Copy the key — it starts with `tskey-auth-...`

> **Note:** Generate the key immediately before running the script — they expire.

### Raspberry Pi ID
1. Go to [https://id.raspberrypi.com](https://id.raspberrypi.com)
2. Create a free account
3. After the script runs, execute `rpi-connect signin` on the Pi and open the printed URL in a browser to link the device

---

## Architecture

```
Internet
    │
    ▼
[WiFi Access Point]
    │
    ├── wlan1 (USB dongle)  ◄── primary, metric 100, MAC-bound
    └── wlan0 (onboard)         disabled, manual fallback only
    │
    ▼
tun0 (OpenVPN)  ──── routes 0.0.0.0/1 + 128.0.0.0/1
    │                 internet traffic exits via VPN
    │
tailscale0  ──── mesh VPN, direct peer-to-peer connections
    │             independent of OpenVPN routing
    │
rpi-connect  ──── browser-based remote access
                  uses Raspberry Pi relay, independent of both VPNs
```

**Remote access comparison:**

| Method | Use case | Requires |
|---|---|---|
| Tailscale | Fast, low-latency access from your other devices | Tailscale on both ends |
| Raspberry Pi Connect | Browser access from anywhere, no client install | Raspberry Pi ID |
| OpenVPN tun0 | Internet privacy / exit node | VPN subscription |

**DNS resolution order:**
1. `100.100.100.100` — resolves `.ts.net` hostnames + forwards everything else
2. `8.8.8.8` / `8.8.4.4` — fallback if Tailscale resolver is unreachable

---

## Raspberry Pi Connect Details

### Headless vs Full Install

| Package | Access type | When to use |
|---|---|---|
| `rpi-connect` | Remote desktop + shell | Pi with display/desktop environment |
| `rpi-connect-lite` | Shell only | Headless Pi (no monitor/desktop) |

The script asks which mode you need during setup.

### Signing In
After the script completes:
```bash
rpi-connect signin
```
This prints a URL. Open it in any browser, sign in with your Raspberry Pi ID, and the device is linked. You can then access it at [https://connect.raspberrypi.com](https://connect.raspberrypi.com) from any browser.

### Useful Commands
```bash
rpi-connect status        # Check connection state and device ID
rpi-connect signin        # Link device to your Raspberry Pi ID
rpi-connect signout       # Unlink this device
journalctl -u rpi-connect -f   # Live service logs
```

---

## Health Check

After setup, verify everything with:

```bash
# Interfaces and IPs
ip addr show wlan0 wlan1

# Routing (should show tun0 routes)
ip route show

# DNS (should be locked)
cat /etc/resolv.conf
lsattr /etc/resolv.conf

# OpenVPN exit IP
curl --interface tun0 -s https://ifconfig.me

# Tailscale peers
sudo tailscale status

# Raspberry Pi Connect
rpi-connect status

# Watchdog timers
systemctl list-timers wlan1-watchdog tun0-watchdog rpi-connect-watchdog

# DNS resolution
dig google.com
dig <your-hostname>.ts.net
```

---

## Troubleshooting

### wlan1 won't connect
```bash
ip link show wlan1          # Is dongle recognized?
lsusb                       # Is USB device present?
sudo iwlist wlan1 scan | grep ESSID   # Can it see your network?
nmcli connection show       # Is the profile there?
nmcli device status         # What state is the device in?
```

### tun0 not coming up
```bash
journalctl -u openvpn@<name> -n 50 --no-pager   # OpenVPN logs
sudo openvpn --config /etc/openvpn/client/<name>.conf  # Test manually
```

### Tailscale not connecting
```bash
sudo tailscale status
sudo tailscale up --authkey=<new-key> --hostname=<name> --accept-dns=false
journalctl -u tailscaled -n 50 --no-pager
```

### Raspberry Pi Connect not working
```bash
rpi-connect status                         # Is it signed in?
rpi-connect signin                         # Re-link if needed
journalctl -u rpi-connect -n 50 --no-pager
systemctl status rpi-connect
```

> **Note:** Raspberry Pi Connect may show as inactive until you complete `rpi-connect signin`. This is normal — the watchdog will keep the service running, but the cloud link requires the sign-in step.

### DNS getting overwritten
```bash
lsattr /etc/resolv.conf     # Should show ----i----
# Re-lock if needed:
sudo chattr -i /etc/resolv.conf
sudo tee /etc/resolv.conf << 'EOF'
nameserver 100.100.100.100
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
sudo chattr +i /etc/resolv.conf
```

### Routing deadlock after VPN server drop
```bash
ip route show | grep <vpn-server-ip>   # Check bypass route exists
sudo /etc/NetworkManager/dispatcher.d/99-vpn-bypass wlan1 up  # Re-trigger
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
| `/etc/systemd/system/rpi-connect.service.d/override.conf` | rpi-connect restart policy |
| `/usr/local/bin/wlan1-watchdog.sh` | WiFi watchdog script |
| `/usr/local/bin/tun0-watchdog.sh` | VPN watchdog script |
| `/usr/local/bin/rpi-connect-watchdog.sh` | Connect watchdog script |
| `/etc/systemd/system/wlan1-watchdog.timer` | WiFi watchdog timer |
| `/etc/systemd/system/tun0-watchdog.timer` | VPN watchdog timer |
| `/etc/systemd/system/rpi-connect-watchdog.timer` | Connect watchdog timer |
| `/var/log/rpi-network-setup.log` | Setup log |
| `/var/log/wlan1-watchdog.log` | WiFi watchdog log |
| `/var/log/tun0-watchdog.log` | VPN watchdog log |
| `/var/log/rpi-connect-watchdog.log` | Connect watchdog log |

---

## Re-running on an Existing Machine

The script is safe to re-run. It removes and recreates NetworkManager profiles cleanly, avoids duplicating OpenVPN settings, unlocks and re-locks `resolv.conf`, and overwrites watchdog scripts with the latest version.

---

## License

MIT License — use freely, modify as needed.

---

*Part of the [Glory-2-Ukraine](https://github.com/Glory-2-Ukraine) infrastructure toolkit.*
