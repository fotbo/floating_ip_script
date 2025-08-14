#!/bin/bash
SCRIPT_PATH=$(dirname "$(readlink -e "$BASH_SOURCE")")
SCRIPT_NAME=$(basename "$BASH_SOURCE")
SERVICE_NAME="custom-routes"
echo "SCRIPT_PATH=$SCRIPT_PATH"
echo "SCRIPT_NAME=$SCRIPT_NAME"
echo "-------------------------------------------"

# --- helpers  block -------

# ===== backups registry =====
BACKUP_LIST="/var/lib/custom-routes-backups.list"
mkdir -p /var/lib
touch "$BACKUP_LIST"

backup_file() {
    local file="$1"
    [ -z "$file" ] && return 0
    [ ! -f "$file" ] && return 0
    if ! grep -Fxq "$file" "$BACKUP_LIST"; then
        cp -a "$file" "$file.customroutes.bak"
        echo "$file" >> "$BACKUP_LIST"
        echo "[*] Backup created: $file.customroutes.bak"
    fi
}

restore_backups() {
    if [ ! -s "$BACKUP_LIST" ]; then
        echo "No backups to restore."
        return 0
    fi
    while read -r file; do
        [ -z "$file" ] && continue
        if [ -f "$file.customroutes.bak" ]; then
            mv -f "$file.customroutes.bak" "$file"
            echo "[*] Restored $file"
        fi
    done < "$BACKUP_LIST"
    # очистим список
    : > "$BACKUP_LIST"

    # применим конфиги после восстановления
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        nmcli con reload || true
        # мягкая перезагрузка NM полезна, но не обязательна:
        # systemctl reload NetworkManager || true
    fi
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        netplan apply || true
    fi
}

disable_dhcp_default_route() {
    local IFACE="$1"
    [ -z "$IFACE" ] && { echo "[!] disable_dhcp_default_route: iface is empty"; return 1; }

    # детект окружения
    is_networkmanager() { systemctl is-active NetworkManager &>/dev/null; }
    is_netplan() { [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; }
    is_ifupdown() { [ -f /etc/network/interfaces ]; }

    if is_networkmanager; then
        echo "[*] NM: disabling default-route from DHCP on $IFACE"
        # найдём connection для устройства
        local CONN PROF
        CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$IFACE" '$2==dev{print $1}')
        if [ -z "$CONN" ]; then
            CONN=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$IFACE" '$2==dev{print $1}' | head -n1)
        fi
        if [ -z "$CONN" ]; then
            echo "[!] NM: cannot find connection for device $IFACE"
            return 1
        fi

        # подстрахуемся бэкапом keyfile, если найдём его
        PROF=$(grep -lE "(^interface-name=$IFACE$|^id=$CONN$)" /etc/NetworkManager/system-connections/* 2>/dev/null | head -n1)
        [ -n "$PROF" ] && backup_file "$PROF"

        # вносим изменения через nmcli
        nmcli connection modify "$CONN" ipv4.never-default yes
        nmcli connection modify "$CONN" ipv4.ignore-auto-routes yes

        nmcli con reload
        nmcli con down "$CONN" || true
        nmcli con up "$CONN" || true
        return 0
    fi

    if is_netplan; then
        echo "[*] Netplan: disabling default-route from DHCP on $IFACE"
        local NETPLAN
        for NETPLAN in /etc/netplan/*.yaml; do
            # ищем секцию интерфейса и dhcp4: true
            if grep -A12 -E "^[[:space:]]+$IFACE:" "$NETPLAN" | grep -q 'dhcp4:[[:space:]]*true'; then
                backup_file "$NETPLAN"

                # уже есть use-routes?
                if grep -A16 -E "^[[:space:]]+$IFACE:" "$NETPLAN" | grep -q 'use-routes:[[:space:]]*false'; then
                    echo "    already patched: $NETPLAN ($IFACE)"
                    continue
                fi

                # номер строки с dhcp4: true в секции IFACE
                local LINE
                LINE=$(awk -v ifc="$IFACE" '
                    $0 ~ "^[[:space:]]" ifc ":" {hit=1}
                    hit && $0 ~ /^[[:space:]]*dhcp4:[[:space:]]*true/ {print NR; exit}
                ' "$NETPLAN")

                if [ -n "$LINE" ]; then
                    # посчитаем отступ секции IFACE
                    local CUR_INDENT SPACES tmpfile
                    CUR_INDENT=$(grep -nE "^[[:space:]]+$IFACE:" "$NETPLAN" | head -1 | sed 's/:.*//')
                    CUR_INDENT=$(sed -n "${CUR_INDENT}p" "$NETPLAN" | sed 's/^\( *\).*/\1/' | wc -c)
                    SPACES=$(printf '%*s' "$((CUR_INDENT + 2))" "")

                    # вставка двух строк после строки LINE — через awk и временный файл
                    tmpfile=$(mktemp)
                    awk -v L="$LINE" -v sp="$SPACES" '
                        NR==L { print; print sp "dhcp4-overrides:"; print sp "  use-routes: false"; next }
                        { print }
                    ' "$NETPLAN" > "$tmpfile" && mv "$tmpfile" "$NETPLAN"

                    echo "    patched: $NETPLAN ($IFACE)"
                else
                    echo "    warning: cannot locate \"dhcp4: true\" line under $IFACE in $NETPLAN"
                fi
            fi
        done
        netplan apply || true
        return 0
    fi

    if is_ifupdown; then
        echo "[*] ifupdown: disabling default-route from DHCP on $IFACE"
        local FILE="/etc/network/interfaces"
        if grep -A3 -E "iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" "$FILE" >/dev/null; then
            backup_file "$FILE"
            if ! grep -A3 -E "iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" "$FILE" | grep -q "post-up ip route del default dev $IFACE"; then
                sed -i "/iface[[:space:]]\+$IFACE[[:space:]]\+inet[[:space:]]\+dhcp/a \    post-up ip route del default dev $IFACE" "$FILE"
                echo "    patched: $FILE ($IFACE)"
            else
                echo "    already patched: $FILE ($IFACE)"
            fi
        else
            echo "    iface $IFACE dhcp stanza not found in $FILE"
        fi
        return 0
    fi

    # RedHat-style ifcfg-$IFACE (если NM выключен)
    local RHFILE="/etc/sysconfig/network-scripts/ifcfg-$IFACE"
    if [ -f "$RHFILE" ]; then
        echo "[*] ifcfg: disabling default-route from DHCP on $IFACE"
        backup_file "$RHFILE"
        grep -q '^DEFROUTE=' "$RHFILE" || echo "DEFROUTE=no" >> "$RHFILE"
        grep -q '^PEERROUTES=' "$RHFILE" || echo "PEERROUTES=no" >> "$RHFILE"
        echo "    patched: $RHFILE"
        return 0
    fi

    echo "[!] Unknown network stack for $IFACE; no changes made."
    return 1
}


# --- helper: derive gateway as first host of interface's subnet ---
derive_gateway_from_iface() {
    local IFACE="$1"
    # Let's take the first IPv4 CIDR of this interface
    local CIDR
    CIDR=$(ip -o -f inet addr show dev "$IFACE" | awk '{print $4}' | head -n1)
    [ -z "$CIDR" ] && { echo ""; return 0; }

    local GW=""
    if command -v ipcalc >/dev/null 2>&1; then
        # ipcalc outputs a line like: "HostMin: 185.253.7.1"
        GW=$(ipcalc "$CIDR" 2>/dev/null | awk '/HostMin:/ {print $2}' | head -n1)
        # On some ipcalc the format is different; attempt #2:
        [ -z "$GW" ] && GW=$(ipcalc -n "$CIDR" 2>/dev/null | awk -F= '/^HOSTMIN=/{print $2}' | head -n1)
    fi

    if [ -z "$GW" ] && command -v python3 >/dev/null 2>&1; then
        # Reliable fallback without ipcalc: calculating network+1 via ipaddress
        GW=$(python3 - <<PY
import ipaddress
net = ipaddress.ip_network("$CIDR", strict=False)
print(str(net[1] if net.num_addresses >= 2 else net.network_address))
PY
)
    fi

    # Last rough fallback: .1 in the same /24 (not perfect, but better than nothing)
    if [ -z "$GW" ]; then
        local IP="${CIDR%/*}"
        GW="${IP%.*}.1"
        echo "[warn] ipcalc/python3 not found; using heuristics: $GW" >&2
    fi

    echo "$GW"
}

isPrivateIP() {
    local ip=$1
    # Function of checking whether IP is included in the range of private addresses
    [[ $ip == 10.* || $ip == 172.1[6-9].* || $ip == 172.2[0-9].* || $ip == 172.3[0-1].* || $ip == 192.168.* ]]
}

has_default_any() {
    ip route show default | grep -q '^default '
}

has_default_on_iface() {
    local IF="$1"
    ip route show default dev "$IF" | grep -q '^default '
}

ensure_default_on_iface() {
    local IF="$1"
    local GW="$2"
    # It is always more reliable to replace: if not, it will add; if it is, it will override the required IF/GW
    ip route replace default via "$GW" dev "$IF"
}

# ---  end helpers block ---

# if input = "restore", then restore configs, remove service and stop script
if [ "$1" == "restore" ]; then
    echo "Restoring configs changed by custom-routes..."
    restore_backups

    echo "Disabling and removing service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/$SERVICE_NAME.service"

    echo "Removing installed script copy..."
    sudo rm -f "/usr/local/bin/$SCRIPT_NAME"

    echo "Done. It is recommended to reboot to ensure default routes are reapplied by your network stack."
    exit 0
fi

sleep 5 # Waiting upping interfaces - for as service run


# --  Filtering interfaces ------

# Raw candidates: everyone except the obvious "garbage"
CANDIDATES=$(ip -o link show | awk -F': ' '{print $2}' \
  | grep -Ev '^(lo|docker0|docker[0-9-].*|br.*|veth.*|virbr.*|vnet.*|tun.*|tap.*|wg.*|ppp.*|vti.*|ipip.*|sit.*|gre.*|gretap.*|erspan.*|vxlan.*|geneve.*|macvtap.*|macvlan.*|ipvlan.*|ifb.*|dummy.*|bond.*|team.*|ovs-system|ovs.*|patch-.*|nlmon.*)$' )

# Let's leave only those who have real IPv4
INTERFACES=""
for IF in $CANDIDATES; do
    # The interface must be up and have IPv4
    if [ "$(cat /sys/class/net/$IF/operstate 2>/dev/null)" = "up" ] && \
       ip -o -4 addr show dev "$IF" | awk '{print $4}' | grep -q . ; then
        INTERFACES+="$IF "
    fi
done
INTERFACES=$(echo "$INTERFACES" | xargs)  # trim spases

echo "list of interfaces: $INTERFACES"

# We require at least 2 interfaces with valid IPv4
COUNT=$(wc -w <<< "$INTERFACES")
if [ "$COUNT" -lt 2 ]; then
    echo "Error: found $COUNT upstream interface(s). Expected at least 2."
    echo "Check that both (or more) uplink interfaces are UP and have valid IPv4 addresses."
    exit 1
fi
# -- End  filtering interfaces ------

if [ "$SCRIPT_PATH" != "/usr/local/bin" ]; then
    cp $SCRIPT_PATH/$SCRIPT_NAME /usr/local/bin/$SCRIPT_NAME
    echo "Scrit copied to bin directory"
fi
chmod 755 /usr/local/bin/$SCRIPT_NAME



#  -- main  Cycle--

for INTERFACE in  $INTERFACES
do
echo "------------------------------------------ begin cycle------------------------------------------------"
echo ""
# Getting information about the interface

INTERFACE_IP=$(ip addr show dev $INTERFACE | grep -oP 'inet \K[\d.]+')

echo "IP address of interface  $INTERFACE is: $INTERFACE_IP"

# Extracting numbers from the interface name for the table number
TABLE_NUMBER=$(( $(echo $INTERFACE | tr -dc '0-9') + 1 ))
echo "Route table number is: $TABLE_NUMBER"

# Get the gateway from the interface in the main table
GATEWAY_IP=$(ip route show dev $INTERFACE | grep -i 'default via' | awk '{print $3}')

if [ -z "$GATEWAY_IP" ]; then
    DERIVED_GW=$(derive_gateway_from_iface "$INTERFACE")
    if [ -n "$DERIVED_GW" ]; then
        echo "No explicit default via on $INTERFACE; derived gateway: $DERIVED_GW"
        GATEWAY_IP="$DERIVED_GW"
    else
        echo "[error] Cannot determine gateway for $INTERFACE (no default, no CIDR). Skipping."
        exit 1
        continue
    fi
fi

echo "Gateway_IP is: $GATEWAY_IP"

# Apply rules

RULE_EXISTS=$(ip rule | grep -q "$INTERFACE_IP lookup $TABLE_NUMBER" && echo "1" || echo "0")

echo "Rule_exist is: $RULE_EXISTS"

if [ $RULE_EXISTS -eq 0 ]; then
    ip rule add from $INTERFACE_IP lookup $TABLE_NUMBER
fi

# Create empty routing table with $TABLE_NUMBER 
ip route add table $TABLE_NUMBER  unreachable 5
ip route del table $TABLE_NUMBER  unreachable 5


ROUTE_EXISTS=$(ip route show table $TABLE_NUMBER | grep -q "default via $GATEWAY_IP" && echo "1" || echo "0")

if [ $ROUTE_EXISTS -eq 0 ]; then
    ip route add 0.0.0.0/0 via $GATEWAY_IP table $TABLE_NUMBER
fi

echo "Route exist is: $ROUTE_EXISTS"
echo "table of rules"
ip rule
echo  "routing table number $TABLE_NUMBER"
ip route show table $TABLE_NUMBER

# -- disabling recieve default route on  interfaces
echo " disabling recieve default route on  $INTERFACE "
disable_dhcp_default_route "$INTERFACE" || true

# Remove / ensure default in MAIN table depending on IP class
if isPrivateIP "$INTERFACE_IP"; then #local  interface
    echo "$INTERFACE_IP is private. Try to delete default on $INTERFACE (if present)."
    if has_default_on_iface "$INTERFACE"; then
        ip route del default dev "$INTERFACE" || true
        echo "Default via $INTERFACE removed from main."
    else
        echo "No default bound to $INTERFACE in main — nothing to delete."
    fi
else # public interface
    echo "$INTERFACE_IP is public. Ensuring main default via $INTERFACE ($GATEWAY_IP)."
    if [ -z "$GATEWAY_IP" ]; then
        # in case it wasn't figured out before (Debian 11 case)
        DERIVED_GW=$(derive_gateway_from_iface "$INTERFACE")
        GATEWAY_IP="$DERIVED_GW"
        echo "Derived gateway for $INTERFACE: $GATEWAY_IP"
    fi
    if has_default_on_iface "$INTERFACE"; then
       echo " $INTERFACE already has default route"
    else
        ensure_default_on_iface "$INTERFACE" "$GATEWAY_IP"
        echo "Main default is now via $INTERFACE ($GATEWAY_IP)." 
    fi 
fi

done

#  Create  service of custom routes
#  Check existing service
if [ -e "/etc/systemd/system/$SERVICE_NAME.service" ]; then

    echo "Service $SERVICE_NAME is already configured."
else
    # create service systemd
    SERVICE_CONTENT="[Unit]
Description=Custom Routes Setup
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/$SCRIPT_NAME

[Install]
WantedBy=default.target
"
    echo "$SERVICE_CONTENT" | sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null

    # renew systemd
    sudo systemctl daemon-reload

    # enable autostart
    sudo systemctl enable $SERVICE_NAME

    # start service
    sudo systemctl start $SERVICE_NAME

    echo "Service $SERVICE_NAME has been created and started."
fi
