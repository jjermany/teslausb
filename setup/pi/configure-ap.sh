#!/bin/bash -eu
# Final configure-ap.sh for Dedicated AP Mode with internal Wi‑Fi (wlan0) as AP.
# When WIFI_ADAPTER=Y is set, this script does the following:
#   - Marks wlan0 as unmanaged so that NM doesn't use it.
#   - Configures wlan0 with a static IP (AP_IP), flushes its existing IP,
#     and forces it into AP mode.
#   - Writes hostapd and dnsmasq configuration files.
#   - Starts hostapd and dnsmasq (using systemd or manually if needed).
#
# The rest of the system (like your client interface) remains untouched.
#
# Required environment variables (in teslausb_setup_variables.conf):
#   export WIFI_ADAPTER=Y
#   export AP_SSID="TESLAUSB_WIFI"
#   export AP_PASS="YourStrongPassword"
#   export AP_IP="192.168.66.1"

function log_progress() {
    echo "configure-ap: $1"
}

# Ensure dedicated mode is requested.
if [ "${WIFI_ADAPTER:-N}" != "Y" ]; then
    log_progress "WIFI_ADAPTER not set to Y; please set WIFI_ADAPTER=Y for dedicated AP mode."
    exit 1
fi

# Check required AP variables.
if [ -z "${AP_SSID+x}" ]; then
    log_progress "AP_SSID not set"
    exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8 )); then
    log_progress "AP_PASS not set, not changed from default, or too short"
    exit 1
fi

IP=${AP_IP:-"192.168.66.1"}
AP_INTERFACE="wlan0"

#############################################
# Dedicated AP Mode: Configure wlan0 as AP
#############################################
log_progress "Dedicated AP adapter mode enabled; configuring $AP_INTERFACE as AP."

# Mark wlan0 as unmanaged so NM doesn't interfere.
log_progress "Setting $AP_INTERFACE as unmanaged..."
nmcli device set "$AP_INTERFACE" managed no || log_progress "Warning: Failed to set $AP_INTERFACE unmanaged."

# Flush any existing IP configuration on wlan0.
log_progress "Flushing existing IP on $AP_INTERFACE..."
ip addr flush dev "$AP_INTERFACE" || true

# Create a static IP configuration file for wlan0.
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/hostapd_ap << EOF
auto $AP_INTERFACE
iface $AP_INTERFACE inet static
    address $IP
    netmask 255.255.255.0
EOF

# Bring up the AP interface.
log_progress "Bringing up $AP_INTERFACE..."
ip link set "$AP_INTERFACE" up || true
if command -v ifup >/dev/null 2>&1; then
    ifup "$AP_INTERFACE" || log_progress "ifup reported that $AP_INTERFACE is already configured, continuing..."
fi

# Wait for the interface to stabilize.
log_progress "Waiting for $AP_INTERFACE to stabilize..."
sleep 5

# Force $AP_INTERFACE into AP mode.
log_progress "Forcing $AP_INTERFACE into AP mode..."
iw dev "$AP_INTERFACE" set type __ap || log_progress "Warning: could not force AP mode on $AP_INTERFACE."

# Verify that $AP_INTERFACE is in AP mode.
log_progress "Verifying $AP_INTERFACE mode..."
iw dev "$AP_INTERFACE" info

#############################################
# Configure hostapd and dnsmasq for wlan0 (AP)
#############################################
# Ensure hostapd directory exists.
mkdir -p /etc/hostapd

# Write hostapd configuration (using 2.4GHz settings).
log_progress "Writing /etc/hostapd/hostapd.conf..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=$AP_INTERFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
EOF

# Point hostapd to our configuration.
cat > /etc/default/hostapd << EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# Write dnsmasq configuration.
log_progress "Writing /etc/dnsmasq.conf..."
cat > /etc/dnsmasq.conf << EOF
interface=$AP_INTERFACE
bind-interfaces
dhcp-range=${IP%.*}.10,${IP%.*}.254,60m
EOF

# Ensure hostapd and dnsmasq are installed.
if ! command -v hostapd >/dev/null 2>&1; then
    log_progress "hostapd not found, installing..."
    apt-get -y --force-yes install hostapd
fi
if ! command -v dnsmasq >/dev/null 2>&1; then
    log_progress "dnsmasq not found, installing..."
    apt-get -y --force-yes install dnsmasq
fi

# Start or restart dnsmasq.
if systemctl list-unit-files | grep -q "^dnsmasq.service"; then
    if systemctl is-active --quiet dnsmasq; then
        log_progress "Restarting dnsmasq..."
        systemctl restart dnsmasq
    else
        log_progress "Starting dnsmasq..."
        systemctl start dnsmasq
    fi
else
    log_progress "dnsmasq.service not found; starting dnsmasq manually..."
    dnsmasq --conf-file=/etc/dnsmasq.conf &
fi

# Start or restart hostapd.
if systemctl list-unit-files | grep -q "^hostapd.service"; then
    if systemctl is-active --quiet hostapd; then
        log_progress "Restarting hostapd..."
        systemctl restart hostapd
    else
        log_progress "Starting hostapd..."
        systemctl start hostapd
    fi
else
    log_progress "hostapd.service not found; starting hostapd manually..."
    hostapd /etc/hostapd/hostapd.conf &
fi

log_progress "AP configured on $AP_INTERFACE (SSID: $AP_SSID, IP: $IP)."
exit 0
