#!/bin/bash -eu

# based on https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

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

# Prefer wlan1 for AP and client, fallback to wlan0 if needed
if ! command -v iw > /dev/null; then
  log_progress "Installing iw"
  apt-get -y --force-yes install iw || return 1
fi

AP_PREF="wlan1"
AP_ALT="wlan0"
if ip link show "$AP_PREF" > /dev/null 2>&1; then
  if iw dev "$AP_PREF" interface add ap0 type __ap &> /dev/null; then
    iw dev ap0 del &> /dev/null
    log_progress "Using $AP_PREF for both AP and client (single device mode)"
    AP_INTERFACE="$AP_PREF"
    CLIENT_INTERFACE="$AP_PREF"
  else
    log_progress "AP mode on $AP_PREF not supported, falling back to $AP_ALT for AP"
    AP_INTERFACE="$AP_ALT"
    CLIENT_INTERFACE="$AP_PREF"
  fi
else
  AP_INTERFACE="$AP_ALT"
  CLIENT_INTERFACE="$AP_ALT"
  log_progress "Only $AP_ALT available, using it for AP and client"
fi

function nm_add_ap () {
  # ensure the Wi-Fi client interface is active
  for i in {1..5}
  do
    if nmcli -t -f DEVICE,STATE dev status | grep -q "^${CLIENT_INTERFACE}:connected$"; then
      break
    fi
    log_progress "Waiting for wifi interface $CLIENT_INTERFACE to come up"
    sleep 5
  done

  if ! nmcli -t -f DEVICE,STATE dev status | grep -q "^${CLIENT_INTERFACE}:connected$"; then
    log_progress "WiFi client interface $CLIENT_INTERFACE is not connected"
    nmcli c show
    return 1
  fi

  # create additional AP interface (ap0) on the preferred device
  if iw dev ap0 info &> /dev/null; then
    iw dev ap0 del || true
  fi
  iw dev "$AP_INTERFACE" interface add ap0 type __ap || return 1

  # disable power saving on both interfaces
  iw "$CLIENT_INTERFACE" set power_save off || return 1
  iw ap0 set power_save off || return 1
  if [ "$AP_INTERFACE" != "$CLIENT_INTERFACE" ]; then
    iw "$AP_INTERFACE" set power_save off || return 1
  fi

  # set up access point using NetworkManager
  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  # don't set band and channel here (if using single device, it will follow client)
  #nmcli con modify TESLAUSB_AP 802-11-wireless.band bg
  #nmcli con modify TESLAUSB_AP 802-11-wireless.channel 6
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1
  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$CLIENT_INTERFACE" ] && [ "$AP_INTERFACE" = "$CLIENT_INTERFACE" ]; then
  iw dev $CLIENT_INTERFACE interface add ap0 type __ap
  iw "$CLIENT_INTERFACE" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi
if [ "\$IFACE" = "$AP_INTERFACE" ] && [ "$AP_INTERFACE" != "$CLIENT_INTERFACE" ]; then
  iw dev $AP_INTERFACE interface add ap0 type __ap
  iw "$AP_INTERFACE" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi

EOF
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
}

if systemctl --quiet is-enabled NetworkManager.service
then
  # ensure NetworkManager is using preferred interface for client
  CURRENT_DEV="$(nmcli -t -f DEVICE,STATE dev status | grep ':connected$' | cut -d: -f1 | grep -E '^wlan0$|^wlan1$')"
  if [ -n "$CURRENT_DEV" ] && [ "$CURRENT_DEV" != "$CLIENT_INTERFACE" ]; then
    CON_NAME="$(nmcli -t -f NAME,DEVICE c show --active | grep "$CURRENT_DEV" | cut -d: -f1)"
    if [ -n "$CON_NAME" ]; then
      log_progress "Switching Wi-Fi connection '$CON_NAME' from $CURRENT_DEV to $CLIENT_INTERFACE"
      if nmcli con up "$CON_NAME" ifname "$CLIENT_INTERFACE"; then
        nmcli device disconnect "$CURRENT_DEV" || true
        log_progress "Wi-Fi connection moved to $CLIENT_INTERFACE"
      else
        log_progress "Failed to connect $CLIENT_INTERFACE to '$CON_NAME', continuing with $CURRENT_DEV"
        AP_INTERFACE="$CURRENT_DEV"
        CLIENT_INTERFACE="$CURRENT_DEV"
      fi
    fi
  fi

  if ! nm_add_ap
  then
    # Network Manager won't allow adding connections when started with a
    # read-only root fs, even if the root fs is now writeable, so try
    # again after restarting Network Manager
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

if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]
then
  log_progress "No wpa_supplicant, skipping AP setup."
  exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf
then
  IP=${AP_IP:-"192.168.66.1"}
  NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')

  # install required packages
  log_progress "installing dnsmasq and hostapd"
  apt-get -y --force-yes install dnsmasq hostapd

  log_progress "configuring AP '$AP_SSID' with IP $IP"
  # create udev rule
  MAC="$(cat /sys/class/net/${AP_INTERFACE}/address)"
  PHY="$(basename "$(readlink /sys/class/net/${AP_INTERFACE}/phy80211)")"
  cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
        SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="$PHY", \
        RUN+="/sbin/iw phy $PHY interface add ap0 type __ap", \
        RUN+="/bin/ip link set ap0 address $MAC"
        EOF

  # configure dnsmasq
  cat <<- EOF > /etc/dnsmasq.conf
        interface=lo,ap0
        no-dhcp-interface=lo,${CLIENT_INTERFACE}
        bind-interfaces
        bogus-priv
        dhcp-range=${NET}.10,${NET}.254,12h
        # don't configure a default route, we're not a router
        dhcp-option=3
        EOF

  # configure hostapd
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

  # define network interfaces. Note use of 'AP1' name, defined in wpa_supplication.conf below
  cat <<- EOF > /etc/network/interfaces
        source-directory /etc/network/interfaces.d

        auto lo
        auto ap0
        auto ${CLIENT_INTERFACE}
        iface lo inet loopback

        allow-hotplug ap0
        iface ap0 inet static
            address ${IP}
            netmask 255.255.255.0
            hostapd /etc/hostapd/hostapd.conf

        allow-hotplug ${CLIENT_INTERFACE}
        iface ${CLIENT_INTERFACE} inet manual
            wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
        iface AP1 inet dhcp
        EOF

  # For bullseye it is apparently necessary to explicitly disable wpa_supplicant for the ap0 interface
  cat <<- EOF >> /etc/dhcpcd.conf
        # disable wpa_supplicant for the ap0 interface
        interface ap0
        nohook wpa_supplicant
        EOF

  if [ ! -L /var/lib/misc ]
  then
    if ! findmnt --mountpoint /mutable
    then
        mount /mutable
    fi
    mkdir -p /mutable/varlib
    mv /var/lib/misc /mutable/varlib
    ln -s /mutable/varlib/misc /var/lib/misc
  fi

  # update the host name to have the AP IP address, otherwise
  # clients connected to the IP will get 127.0.0.1 when looking
  # up the teslausb host name
  sed -i -e "/^127.0.0.1\s*localhost/b; s/^127.0.0.1\(\s*.*\)/$IP\1/" /etc/hosts

  # add ID string to wpa_supplicant
  sed -i -e 's/}/  id_str="AP1"\n}/'  /etc/wpa_supplicant/wpa_supplicant.conf
else
  log_progress "AP mode already configured"
fi
