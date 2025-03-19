#!/bin/bash -eu
# based on https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/
# Modified to use AP_IFACE for the AP instead of always creating a virtual interface.

function log_progress () {
  if declare -F setup_progress > /dev/null; then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

# Ensure required variables are set.
if [ -z "${AP_SSID+x}" ]; then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8 )); then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

# Function: get the active Wi-Fi client device (exclude the AP interface)
function nm_get_wifi_client_device () {
  for i in {1..5}; do
    # List active wireless connections excluding the one on AP_IFACE (or ap0 if not overridden)
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":${AP_IFACE:-ap0}$" | cut -d: -f2)"
    if [ -n "$WLAN" ]; then
      break;
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

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  # Determine the AP interface to use: if AP_IFACE is set, use that; otherwise default to ap0.
  AP_INTERFACE="${AP_IFACE:-ap0}"

  if ! iw dev "$AP_INTERFACE" info &> /dev/null; then
    if [ -z "${AP_IFACE+x}" ]; then
      # No override set, create a virtual interface on the client device
      iw dev "$WLAN" interface add ap0 type __ap || return 1
      AP_INTERFACE="ap0"
    else
      log_progress "AP interface $AP_INTERFACE not available. Ensure it exists and is free."
      return 1
    fi
  fi

  # Turn off power saving on both interfaces
  iw "$WLAN" set power_save off || return 1
  iw "$AP_INTERFACE" set power_save off || return 1

  # Delete any existing AP connection and create a new one using the chosen AP interface
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname "$AP_INTERFACE" mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1

  # Create an if-up script so that when the client device (WLAN) comes up, the AP is re-added.
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

# Fallback branch: use hostapd/dnsmasq if NetworkManager is not enabled.
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
