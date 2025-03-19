#!/bin/bash -eu
# Revised configure-ap.sh without AP_IFACE.
# When WIFI_ADAPTER=Y, the script will assume:
#   - Client device is wlan1.
#   - AP interface is wlan0 (used exclusively for AP mode, not joining any networks).
# Otherwise, it falls back to creating a virtual interface named ap0 on the active client.

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

# Function to determine the Wi-Fi client device.
# If WIFI_ADAPTER=Y then we assume client is wlan1.
function nm_get_wifi_client_device () {
  if [ "${WIFI_ADAPTER:-N}" = "Y" ]; then
    WLAN="wlan1"
    return 0
  fi

  for i in {1..5}; do
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -d: -f2)"
    if [ -n "$WLAN" ]; then
      break
    fi
    log_progress "Waiting for wifi interface to come back up"
    sleep 5
  done

  if [ -n "$WLAN" ]; then
    return 0
  else
    log_progress "Couldn't determine wifi client device"
    nmcli c show
    return 1
  fi
}

# Function to add the AP connection via NetworkManager.
function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  # Determine the AP interface.
  # If WIFI_ADAPTER=Y then we use wlan0 as the dedicated AP interface.
  if [ "${WIFI_ADAPTER:-N}" = "Y" ]; then
    AP_INTERFACE="wlan0"
    if ! iw dev "$AP_INTERFACE" info &> /dev/null; then
      log_progress "AP interface $AP_INTERFACE not available. Ensure it exists and is free."
      return 1
    fi
  else
    AP_INTERFACE="ap0"
    if ! iw dev "$AP_INTERFACE" info &> /dev/null; then
      # No dedicated AP interface; create a virtual interface on the client device.
      iw dev "$WLAN" interface add ap0 type __ap || return 1
      AP_INTERFACE="ap0"
    fi
  fi

  # Turn off power saving on both the client and AP interfaces.
  iw "$WLAN" set power_save off || return 1
  iw "$AP_INTERFACE" set power_save off || return 1

  # Delete any existing TESLAUSB_AP connection and create a new one using the chosen AP interface.
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname "$AP_INTERFACE" mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless.band a || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless.channel 36 || return 1

  # Create an if-up script.
  if [ "${WIFI_ADAPTER:-N}" = "Y" ]; then
    # With dedicated adapter mode, simply bring up the AP connection when the client (wlan1) comes up.
    cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash
if [ "\$IFACE" = "wlan1" ]; then
  nmcli con up TESLAUSB_AP
fi
EOF
  else
    # Otherwise, recreate the virtual AP interface when the client device comes up.
    cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash
if [ "\$IFACE" = "$WLAN" ]; then
  iw dev $WLAN interface add ${AP_INTERFACE} type __ap
  iw "$WLAN" set power_save off
  iw ${AP_INTERFACE} set power_save off
  nmcli con up TESLAUSB_AP
fi
EOF
  fi
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1

  return 0
}

if systemctl --quiet is-enabled NetworkManager.service; then
  # Ensure iw is installed.
  apt-get -y --force-yes install iw || return 1
  if ! nm_add_ap; then
    log_progress "Retrying after restarting Network Manager"
    systemctl restart NetworkManager.service
    if ! nm_add_ap; then
      log_progress "STOP: Failed to configure AP"
      exit 1
    fi
  fi
  log_progress "AP configured"
  exit 0
fi

# Fallback branch: if NetworkManager is not enabled, use hostapd/dnsmasq.
if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]; then
  log_progress "No wpa_supplicant, skipping AP setup."
  exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf; then
  IP=${AP_IP:-"192.168.66.1"}
  NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')

  log_progress "installing dnsmasq and hostapd"
  apt-get -y --force-yes install dnsmasq hostapd

  log_progress "configuring AP '$AP_SSID' with IP $IP"
  MAC="$(cat /sys/class/net/${AP_INTERFACE}/address)"
  cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
	SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy0", \
	RUN+="/sbin/iw phy phy0 interface add ${AP_INTERFACE} type __ap", \
	RUN+="/bin/ip link set ${AP_INTERFACE} address $MAC"
EOF

  cat <<- EOF > /etc/dnsmasq.conf
	interface=lo,${AP_INTERFACE}
	no-dhcp-interface=lo,wlan1
	bind-interfaces
	bogus-priv
	dhcp-range=${NET}.10,${NET}.254,12h
	dhcp-option=3
EOF

  cat <<- EOF > /etc/hostapd/hostapd.conf
	ctrl_interface=/var/run/hostapd
	ctrl_interface_group=0
	interface=${AP_INTERFACE}
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
	auto ${AP_INTERFACE}
	auto wlan1
	iface lo inet loopback

	allow-hotplug ${AP_INTERFACE}
	iface ${AP_INTERFACE} inet static
	    address ${IP}
	    netmask 255.255.255.0
	    hostapd /etc/hostapd/hostapd.conf

	allow-hotplug wlan1
	iface wlan1 inet manual
	    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
	iface AP1 inet dhcp
EOF

  cat <<- EOF >> /etc/dhcpcd.conf
	# disable wpa_supplicant for the ${AP_INTERFACE} interface
	interface ${AP_INTERFACE}
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
