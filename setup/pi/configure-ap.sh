#!/bin/bash -eu
# Final comprehensive configure-ap.sh
# This script handles all scenarios:
# 1. If WIFI_ADAPTER=Y, it uses hostapd/dnsmasq exclusively:
#      - AP interface is wlan0 (used solely as AP).
#      - Client interface is wlan1.
#      - It flushes existing IPs, writes static config, creates necessary directories,
#        and writes hostapd/dnsmasq configuration.
# 2. Otherwise, it falls back to the traditional NetworkManager shared-mode
#    (creating a virtual interface ap0) or final fallback if NM is not enabled.
#
# It also checks if dnsmasq.service exists; if not, it starts dnsmasq manually.

function log_progress () {
    if declare -F setup_progress > /dev/null; then
        setup_progress "configure-ap: $1"
    else
        echo "configure-ap: $1"
    fi
}

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

#############################################
# Dedicated AP Adapter Mode (Hostapd/dnsmasq)
#############################################
if [ "${WIFI_ADAPTER:-N}" = "Y" ]; then
    log_progress "Dedicated AP adapter mode enabled; using hostapd/dnsmasq with wlan0 (AP) and wlan1 (client)."
    
    AP_INTERFACE="wlan0"
    CLIENT_IFACE="wlan1"

    # Flush any existing IP configuration on wlan0 to avoid conflicts.
    log_progress "Flushing existing IP on $AP_INTERFACE..."
    ip addr flush dev "$AP_INTERFACE" || true

    # Create a static IP configuration file for the AP interface.
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
        ifup "$AP_INTERFACE" || log_progress "ifup failed, continuing..."
    fi

    # Ensure the hostapd configuration directory exists.
    mkdir -p /etc/hostapd

    # Write hostapd configuration.
    log_progress "Writing /etc/hostapd/hostapd.conf..."
    cat > /etc/hostapd/hostapd.conf << EOF
interface=$AP_INTERFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=a
channel=36
ieee80211n=1
ieee80211ac=1
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=42
wmm_enabled=1
macaddr_acl=0
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
EOF

    # Point hostapd to the configuration.
    cat > /etc/default/hostapd << EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

    # Write dnsmasq configuration to serve DHCP on the AP interface.
    log_progress "Writing /etc/dnsmasq.conf..."
    cat > /etc/dnsmasq.conf << EOF
interface=$AP_INTERFACE
bind-interfaces
dhcp-range=${IP%.*}.10,${IP%.*}.254,60m
EOF

    # Restart or start dnsmasq.
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

    # Restart or start hostapd.
    if systemctl is-active --quiet hostapd; then
        log_progress "Restarting hostapd..."
        systemctl restart hostapd
    else
        log_progress "Starting hostapd..."
        systemctl start hostapd
    fi

    log_progress "AP configured on $AP_INTERFACE (SSID: $AP_SSID, IP: $IP). Client interface remains on $CLIENT_IFACE."
    exit 0
fi

#########################################
# Fallback: NetworkManager Shared Mode
#########################################
function nm_get_wifi_client_device () {
    for i in {1..5}; do
        WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -d: -f2)"
        if [ -n "$WLAN" ]; then
            break
        fi
        log_progress "Waiting for wifi interface to come back up"
        sleep 5
    done
    [ -n "$WLAN" ] && return 0
    log_progress "Couldn't determine wifi client device"
    nmcli c show
    return 1
}

function nm_add_ap () {
    nm_get_wifi_client_device || return 1
    AP_INTERFACE="ap0"
    if ! iw dev "$AP_INTERFACE" info &> /dev/null; then
        iw dev "$WLAN" interface add ap0 type __ap || return 1
    fi
    iw "$WLAN" set power_save off || return 1
    iw "$AP_INTERFACE" set power_save off || return 1
    nmcli con delete TESLAUSB_AP &> /dev/null || true
    nmcli con add type wifi ifname "$AP_INTERFACE" mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
    nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
    nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
    nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
    nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
    nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
    nmcli con modify TESLAUSB_AP 802-11-wireless.band a || return 1
    nmcli con modify TESLAUSB_AP 802-11-wireless.channel 36 || return 1

    cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash
if [ "\$IFACE" = "$WLAN" ]; then
  iw dev $WLAN interface add ${AP_INTERFACE} type __ap
  iw "$WLAN" set power_save off
  iw ${AP_INTERFACE} set power_save off
  nmcli con up TESLAUSB_AP
fi
EOF
    chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
    return 0
}

if systemctl --quiet is-enabled NetworkManager.service; then
    apt-get -y --force-yes install iw || return 1
    if ! nm_add_ap; then
        log_progress "Retrying after restarting Network Manager"
        systemctl restart NetworkManager.service
        if ! nm_add_ap; then
            log_progress "STOP: Failed to configure AP"
            exit 1
        fi
    fi
    log_progress "AP configured via NetworkManager shared mode"
    exit 0
fi

###############################
# Final Fallback: No NM Enabled
###############################
if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    log_progress "No wpa_supplicant, skipping AP setup."
    exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf; then
    NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')
    log_progress "installing dnsmasq and hostapd"
    apt-get -y --force-yes install dnsmasq hostapd
    log_progress "configuring AP '$AP_SSID' with IP $IP"
    MAC="$(cat /sys/class/net/ap0/address)"
    cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
    SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy0", \\
    RUN+="/sbin/iw phy phy0 interface add ap0 type __ap", \\
    RUN+="/bin/ip link set ap0 address $MAC"
EOF
    cat <<- EOF > /etc/dnsmasq.conf
    interface=lo,ap0
    no-dhcp-interface=lo,wlan0
    bind-interfaces
    bogus-priv
    dhcp-range=${NET}.10,${NET}.254,12h
    dhcp-option=3
EOF
    cat <<- EOF > /etc/hostapd/hostapd.conf
    ctrl_interface=/var/run/hostapd
    ctrl_interface_group=0
    interface=ap0
    driver=nl80211
    ssid=${AP_SSID}
    hw_mode=g
    channel=11
    wmm_enabled=0
    macaddr_acl=0
    auth_algs=1
    wpa=2
    wpa_passphrase=${AP_PASS}
    wpa_key_mgmt=WPA-PSK
    wpa_pairwise=TKIP CCMP
    rsn_pairwise=CCMP
EOF
    cat <<- EOF > /etc/default/hostapd
    DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
    cat <<- EOF > /etc/network/interfaces
    source-directory /etc/network/interfaces.d
    auto lo
    auto ap0
    auto wlan0
    iface lo inet loopback
    allow-hotplug ap0
    iface ap0 inet static
        address ${IP}
        netmask 255.255.255.0
        hostapd /etc/hostapd/hostapd.conf
    allow-hotplug wlan0
    iface wlan0 inet manual
        wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
    iface AP1 inet dhcp
EOF
    cat <<- EOF >> /etc/dhcpcd.conf
    # disable wpa_supplicant for the ap0 interface
    interface ap0
    nohook wpa_supplicant
EOF
    if [ ! -L /var/lib/misc ]; then
        if ! findmnt --mountpoint /mutable; then
            mount /mutable
        fi
        mkdir -p /mutable/varlib
        mv /var/lib/misc /mutable/varlib
        ln -s /mutable/varlib/misc /var/lib/misc
    fi
    sed -i -e "/^127.0.0.1\s*localhost/b; s/^127.0.0.1\(\s*.*\)/$IP\1/" /etc/hosts
    sed -i -e 's/}/  id_str="AP1"\n}/' /etc/wpa_supplicant/wpa_supplicant.conf
else
    log_progress "AP mode already configured"
fi
