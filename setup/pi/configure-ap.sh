#!/bin/bash -eu

# Based on: https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

if [ -z "${AP_SSID+x}" ]
then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8))
then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

# Determine the primary interface for AP
if ip link show wlan1 &> /dev/null; then
  WLAN="wlan1"
else
  WLAN="wlan0"
fi

function nm_get_wifi_client_device () {
  for i in {1..5}
  do
    WLAN_ACTIVE="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN_ACTIVE" ]
    then
      break;
    fi
    log_progress "Waiting for wifi interface to come back up"
    sleep 5
  done

  [ -n "$WLAN_ACTIVE" ] && return 0

  log_progress "Couldn't determine wifi client device"
  nmcli c show
  return 1
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  if ! iw dev ap0 info &> /dev/null
  then
    # Create additional virtual interface for the WiFi device
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  # Disable power saving mode on both interfaces
  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  # Set up access point on the virtual interface using NetworkManager
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1

  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$WLAN" ]
then
  iw dev $WLAN interface add ap0 type __ap
  iw "$WLAN" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi

EOF
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
}

if systemctl --quiet is-enabled NetworkManager.service
then
  apt-get -y install iw || return 1
  if ! nm_add_ap
  then
    log_progress "Retrying after restarting Network Manager"
    systemctl restart NetworkManager.service
    if ! nm_add_ap
    then
      log_progress "STOP: Failed to configure AP"
      exit 1
    fi
  fi
  log_progress "AP configured"
  exit 0
fi

log_progress "Configuring AP '$AP_SSID' on $WLAN with IP $IP"

# Ensure the correct MAC address is used
MAC="$(cat /sys/class/net/$WLAN/address)"

cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy1", \
RUN+="/sbin/iw phy phy1 interface add ap0 type __ap", \
RUN+="/bin/ip link set ap0 address $MAC"
EOF

udevadm control --reload-rules && udevadm trigger

log_progress "AP mode setup complete"
