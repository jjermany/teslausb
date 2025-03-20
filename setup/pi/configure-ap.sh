#!/bin/bash

set -e

# Load TeslaUSB configuration variables
source /root/teslausb_setup_variables.conf

# Define interfaces
AP_INTERFACE="ap0"
WIFI_INTERFACE="wlan1"
CLIENT_INTERFACE="wlan1"

# Ensure NetworkManager is writable
/bin/remountfs_rw

# Check if wlan1 (external adapter) exists
if ip link show wlan1 > /dev/null 2>&1; then
    echo "[INFO] Detected wlan1. Configuring for best performance."
    
    # Make sure wlan0 is unmanaged so it doesn't interfere with AP mode
    nmcli device set wlan0 managed no

    # Ensure required packages are installed
    dpkg -l | grep -qw dnsmasq || sudo apt install -y dnsmasq
    dpkg -l | grep -qw hostapd || sudo apt install -y hostapd
    dpkg -l | grep -qw iw || sudo apt install -y iw

    # Ensure ap0 interface exists and is in AP mode
    if ! iw dev | grep -q "$AP_INTERFACE"; then
        iw dev wlan0 interface add $AP_INTERFACE type __ap
    fi

    # Remove old AP connection if it exists
    if nmcli connection show | grep -q TESLAUSB_AP; then
        nmcli connection delete TESLAUSB_AP
    fi

    # Ensure wlan1 is used as the primary client connection
    nmcli connection modify preconfigured connection.interface-name wlan1

    # Configure AP network settings
    nmcli connection add type wifi ifname $AP_INTERFACE con-name TESLAUSB_AP ssid "$TESLAUSB_AP_SSID"
    nmcli connection modify TESLAUSB_AP 802-11-wireless.mode ap
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.proto rsn
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.pairwise ccmp
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.group ccmp
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.psk "$TESLAUSB_AP_PASSWORD"
    nmcli connection modify TESLAUSB_AP ipv4.method shared
    nmcli connection modify TESLAUSB_AP ipv4.addresses 192.168.66.1/24
    nmcli connection modify TESLAUSB_AP ipv4.gateway 192.168.66.1
    nmcli connection modify TESLAUSB_AP ipv4.dns "8.8.8.8,1.1.1.1"

    # Ensure AP uses 5GHz if available
    if iw list | grep -q "Band 2"; then
        echo "[INFO] AP supports 5GHz. Configuring AP on 5GHz."
        nmcli connection modify TESLAUSB_AP 802-11-wireless.band a
    else
        echo "[INFO] AP does not support 5GHz. Using 2.4GHz."
        nmcli connection modify TESLAUSB_AP 802-11-wireless.band bg
    fi

    # Ensure the WiFi 6E adapter (wlan1) uses WPA3-SAE security if supported
    if nmcli device wifi list ifname wlan1 | grep -qE "6[0-9]{3} MHz"; then
        nmcli connection modify preconfigured 802-11-wireless-security.key-mgmt sae
        nmcli connection modify preconfigured 802-11-wireless-security.proto rsn
        nmcli connection modify preconfigured 802-11-wireless-security.pmf disable
    fi

    # Restart services to apply changes
    systemctl restart dnsmasq
    systemctl restart hostapd
    systemctl restart NetworkManager

    # Start the AP connection
    nmcli connection up TESLAUSB_AP

    # Start the WiFi client connection
    nmcli connection up preconfigured

    # Verify AP is running
    if ! nmcli device status | grep -q "$AP_INTERFACE.*connected"; then
        echo "[ERROR] AP setup failed. Check logs." >&2
        exit 1
    fi

    echo "TeslaUSB AP setup complete!"
else
    echo "[INFO] wlan1 not detected. Falling back to original TeslaUSB behavior."
    
    # Remove old AP connection if it exists
    if nmcli connection show | grep -q TESLAUSB_AP; then
        nmcli connection delete TESLAUSB_AP
    fi

    # Ensure wlan0 supports 5GHz before setting it as AP
    if iw list | grep -q "Band 2"; then
        echo "[INFO] Internal Wi-Fi supports 5GHz. Configuring AP on 5GHz."
        AP_BAND="a"
    else
        echo "[INFO] Internal Wi-Fi does not support 5GHz. Using 2.4GHz."
        AP_BAND="bg"
    fi

    # Configure AP network settings
    nmcli connection add type wifi ifname wlan0 con-name TESLAUSB_AP ssid "$TESLAUSB_AP_SSID"
    nmcli connection modify TESLAUSB_AP 802-11-wireless.mode ap
    nmcli connection modify TESLAUSB_AP 802-11-wireless.band $AP_BAND
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.proto rsn
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.pairwise ccmp
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.group ccmp
    nmcli connection modify TESLAUSB_AP 802-11-wireless-security.psk "$TESLAUSB_AP_PASSWORD"
    nmcli connection modify TESLAUSB_AP ipv4.method shared
    nmcli connection modify TESLAUSB_AP ipv4.addresses 192.168.66.1/24
    nmcli connection modify TESLAUSB_AP ipv4.gateway 192.168.66.1
    nmcli connection modify TESLAUSB_AP ipv4.dns "8.8.8.8,1.1.1.1"

    # Restart services to apply changes
    systemctl restart dnsmasq
    systemctl restart hostapd
    systemctl restart NetworkManager

    # Start the AP connection
    nmcli connection up TESLAUSB_AP

    # Verify AP is running
    if ! nmcli device status | grep -q "wlan0.*connected"; then
        echo "[ERROR] AP setup failed. Check logs." >&2
        exit 1
    fi

    echo "[INFO] TeslaUSB AP fallback setup complete."
fi
