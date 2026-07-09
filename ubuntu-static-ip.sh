#!/bin/bash
#
# ubuntu-static-ip.sh
# Correct way to run this script (important):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Ahmedhelal6325/Ubuntu-Tools/main/ubuntu-static-ip.sh)"
#
# Do NOT use the plain pipe form (curl | sudo bash). That consumes stdin
# with the script content itself, so "read" gets no real input and loops
# forever. Using bash -c "$(curl ...)" keeps stdin pointed at your real
# terminal, so prompts work normally.

set -u
MAX_ATTEMPTS=5

# Must run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m[!] Please run this script with sudo.\e[0m"
  exit 1
fi

echo -e "\e[34m====================================================\e[0m"
echo -e "\e[32m         Interactive Static IP Setup Script          \e[0m"
echo -e "\e[34m====================================================\e[0m"

# Make sure we actually have an interactive terminal to read from
if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
    echo -e "\e[31m[!] No interactive input available (no stdin, no /dev/tty).\e[0m"
    echo -e "\e[33m[!] Use the correct run command:\e[0m"
    echo -e "\e[36m    sudo bash -c \"\$(curl -fsSL <raw_script_url>)\"\e[0m"
    exit 1
fi

# Generic input reader with a retry limit and optional regex validation.
# Usage: read_validated "prompt text" "regex" "default value"
read_validated() {
    local prompt="$1" pattern="$2" default="${3:-}"
    local value attempts=0
    while true; do
        read -r -p "$prompt" value
        value=${value:-$default}
        if [ -z "$pattern" ] || [[ $value =~ $pattern ]]; then
            echo "$value"
            return 0
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
            echo -e "\e[31m[-] Too many invalid attempts ($MAX_ATTEMPTS). Stopping.\e[0m" >&2
            exit 1
        fi
        echo -e "\e[31m[-] Invalid value, try again ($attempts/$MAX_ATTEMPTS).\e[0m" >&2
    done
}

# Converts a dotted-decimal netmask (e.g. 255.255.240.0) to CIDR (e.g. 20).
# If the input is already a valid CIDR number (1-32), it's returned as-is.
# Returns non-zero if the input is neither a valid CIDR nor a valid mask.
netmask_to_cidr() {
    local mask="$1"

    # Already plain CIDR (1-32)
    if [[ $mask =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "$mask"
        return 0
    fi

    # Dotted decimal form, e.g. 255.255.240.0
    if [[ $mask =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS=.
        read -r o1 o2 o3 o4 <<< "$mask"
        local bits=0
        for octet in "$o1" "$o2" "$o3" "$o4"; do
            case "$octet" in
                255) bits=$((bits + 8)) ;;
                254) bits=$((bits + 7)) ;;
                252) bits=$((bits + 6)) ;;
                248) bits=$((bits + 5)) ;;
                240) bits=$((bits + 4)) ;;
                224) bits=$((bits + 3)) ;;
                192) bits=$((bits + 2)) ;;
                128) bits=$((bits + 1)) ;;
                0)   bits=$((bits + 0)) ;;
                *) return 1 ;;
            esac
        done
        echo "$bits"
        return 0
    fi

    return 1
}

# Asks for a netmask, accepting either CIDR (24) or dotted decimal
# (255.255.255.0), with a retry limit.
read_netmask() {
    local prompt="$1"
    local value cidr attempts=0
    while true; do
        read -r -p "$prompt" value
        if cidr=$(netmask_to_cidr "$value"); then
            echo "$cidr"
            return 0
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
            echo -e "\e[31m[-] Too many invalid attempts ($MAX_ATTEMPTS). Stopping.\e[0m" >&2
            exit 1
        fi
        echo -e "\e[31m[-] Invalid subnet mask, try again ($attempts/$MAX_ATTEMPTS).\e[0m" >&2
    done
}

# 1. Stop cloud-init from overwriting network config
echo -e "\n\e[33m[*] Disabling cloud-init network management...\e[0m"
mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# 2. Auto-detect the active network interface
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip -br link show | grep -v LO | awk '{print $1}' | head -n1)
fi

# 3. Ask the user for the network details
IFACE=$(read_validated "Network interface [press Enter to use $DEFAULT_IFACE]: " "" "$DEFAULT_IFACE")

IP_REGEX='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
IP=$(read_validated "Enter the new IP address (example: 192.168.1.101): " "$IP_REGEX")

NETMASK=$(read_netmask "Enter the subnet mask, CIDR or dotted (example: 24 or 255.255.255.0): ")

GATEWAY=$(read_validated "Enter the gateway address (example: 192.168.1.1): " "$IP_REGEX")

DNS1=$(read_validated "Enter primary DNS [press Enter to use 8.8.8.8]: " "" "8.8.8.8")
DNS2=$(read_validated "Enter secondary DNS [press Enter to use 1.1.1.1]: " "" "1.1.1.1")

# 4. Back up old netplan files and clean the folder
echo -e "\n\e[33m[*] Backing up old netplan files and preparing the new config...\e[0m"
mkdir -p /etc/netplan/backup_old_yaml/
mv /etc/netplan/*.yaml /etc/netplan/backup_old_yaml/ 2>/dev/null

# 5. Write the new netplan config file
cat <<EOF > /etc/netplan/01-static-managed.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP/$NETMASK
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

# Netplan requires strict permissions on its config files (root-only),
# otherwise it prints "Permissions too open" warnings.
chmod 600 /etc/netplan/01-static-managed.yaml

# 6. Apply the config directly (no confirmation prompt).
#
# Note: earlier versions asked for a y/N confirmation with a timeout as
# a safety net, similar to "netplan try". That was removed on request:
# it doesn't play well with SSH sessions (the prompt can get cut off
# right when the interface changes), so this now just applies directly.
# A backup of the previous config is kept at
# /etc/netplan/backup_old_yaml/ in case you need to revert manually:
#   sudo rm -f /etc/netplan/01-static-managed.yaml
#   sudo mv /etc/netplan/backup_old_yaml/*.yaml /etc/netplan/
#   sudo netplan apply
echo -e "\n\e[32m[*] Applying the new network configuration...\e[0m"
netplan apply
sleep 2

echo -e "\e[34mCurrent IP for $IFACE:\e[0m"
ip addr show "$IFACE" | grep inet
echo -e "\e[32m[OK] Static IP setup complete.\e[0m"
