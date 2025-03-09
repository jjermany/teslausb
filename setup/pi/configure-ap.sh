#!/bin/bash -eu

# based on https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

function log_progress() {
  if declare -F setup_progress > /dev/null; then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

if [ -z "${AP_SSID+x}" ]; then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8)); then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

function nm_get_wifi_client_device() {
  for i in {1..5}; do
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN" ]; then
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

function nm_add_ap() {
  nm_get_wifi_client_device || return 1

  # Delete any existing AP connection profile
  nmcli connection delete TESLAUSB_AP &> /dev/null || true

  # Create the AP connection profile using the internal adapter (wlan0)
  nmcli con add type wifi ifname "$WLAN" mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1

  # Activate the AP connection profile
  nmcli con up TESLAUSB_AP || return 1
}

if systemctl --quiet is-enabled NetworkManager.service; then
  # force-install iw because otherwise it will get autoremoved when
  # alsa-utils is removed later
  apt-get -y --force-yes install iw || return 1
  if ! nm_add_ap; then
    # Network Manager won't allow adding connections when started with a
    # read-only root fs, even if the root fs is not writeable, so try
    # again after restarting Network Manager
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
