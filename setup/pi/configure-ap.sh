#!/bin/bash -eu

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

function nm_get_wifi_client_device () {
  for i in {1..5}
  do
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN" ]
    then
      break;
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

  log_progress "Remounting filesystem as writable..."
  mount -o remount,rw /

  if ! iw dev ap0 info &> /dev/null
  then
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  # **NEW: Remove all existing AP connections to avoid duplicates**
  log_progress "Removing existing TESLAUSB_AP connections..."
  for uuid in $(nmcli -t -f UUID,NAME con show | grep TESLAUSB_AP | cut -d: -f1); do
      sudo nmcli connection delete "$uuid"
  done
  sleep 2  # Give NetworkManager time to process deletions

  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1

  # Force 5GHz (WiFi 5) with 20MHz width
  if ! nmcli con modify TESLAUSB_AP 802-11-wireless.band a
  then
    log_progress "Setting 5GHz failed. Restarting NetworkManager and retrying..."
    systemctl restart NetworkManager
    sleep 3
    if ! nmcli con modify TESLAUSB_AP 802-11-wireless.band a
    then
      log_progress "STOP: Failed to configure AP with 5GHz."
      exit 1
    fi
  fi

  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  nmcli con modify TESLAUSB_AP ipv4.addr "${AP_IP:-192.168.66.1}/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
}

if systemctl --quiet is-enabled NetworkManager.service
then
  apt-get -y --force-yes install iw || return 1
  if ! nm_add_ap
  then
    log_progress "Retrying after restarting NetworkManager"
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

if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]
then
  log_progress "No wpa_supplicant, skipping AP setup."
  exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf
then
  IP=${AP_IP:-"192.168.66.1"}
  NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')

  log_progress "Installing dnsmasq and hostapd"
  apt-get -y --force-yes install dnsmasq hostapd

  log_progress "Configuring AP '$AP_SSID' with IP $IP"
  
  cat <<- EOF > /etc/hostapd/hostapd.conf
	ctrl_interface=/var/run/hostapd
	ctrl_interface_group=0
	interface=ap0
	driver=nl80211
	ssid=${AP_SSID}
	hw_mode=a
	channel=40
	wmm_enabled=1
	macaddr_acl=0
	auth_algs=1
	wpa=2
	wpa_passphrase=${AP_PASS}
	wpa_key_mgmt=WPA-PSK
	wpa_pairwise=TKIP CCMP
	rsn_pairwise=CCMP
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
	interface ap0
	nohook wpa_supplicant
	EOF

  log_progress "AP mode configured with fallback hostapd"
fi
