#!/bin/bash
# disable_dhcp_default_route() tester
BACKUP_LIST="/var/lib/custom-routes-backups.list"
mkdir -p /var/lib
touch "$BACKUP_LIST"

backup_file() {
  local file="$1"
  [ -z "$file" ] && return 0
  [ ! -f "$file" ] && return 0

  local need_copy=0
  grep -Fxq "$file" "$BACKUP_LIST" || need_copy=1
  [ ! -f "$file.customroutes.bak" ] && need_copy=1

  if [ "$need_copy" -eq 1 ]; then
    cp -a "$file" "$file.customroutes.bak"
    grep -Fxq "$file" "$BACKUP_LIST" || echo "$file" >> "$BACKUP_LIST"
    echo "[DEBUG] Backup created: $file.customroutes.bak"
  else
    echo "[DEBUG] Backup already present for: $file"
  fi
}


disable_dhcp_default_route() {
    local IFACE="$1"
    [ -z "$IFACE" ] && { echo "[ERROR] iface is empty"; return 1; }
    echo "[DEBUG] Starting disable_dhcp_default_route for: $IFACE"

    # детект окружения
    is_networkmanager() { command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null; }
    is_netplan() { [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; }
    is_ifupdown() { [ -f /etc/network/interfaces ]; }

    # ===== 1. NetworkManager =====
    if is_networkmanager; then
        echo "[DEBUG] Detected: NetworkManager"
        local CONN PROF
        CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$IFACE" '$2==dev{print $1}')
        [ -z "$CONN" ] && CONN=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$IFACE" '$2==dev{print $1}' | head -n1)
        if [ -z "$CONN" ]; then
            echo "[WARN] Cannot find NM connection for $IFACE"
            return 1
        fi
        PROF=$(grep -lE "(^interface-name=$IFACE$|^id=$CONN$)" /etc/NetworkManager/system-connections/* 2>/dev/null | head -n1)
        [ -n "$PROF" ] && backup_file "$PROF"
        nmcli connection modify "$CONN" ipv4.never-default yes
        nmcli connection modify "$CONN" ipv4.ignore-auto-routes yes
        nmcli con reload
        nmcli con down "$CONN" || true
        nmcli con up "$CONN" || true
        return 0
    fi

    # ===== 2. Netplan =====
    if is_netplan; then
        echo "[DEBUG] Detected: Netplan"
        for NETPLAN in /etc/netplan/*.yaml; do
            echo "[DEBUG] Checking: $NETPLAN for iface $IFACE"

            # 0) есть ли хоть упоминание iface
            if ! grep -qE "^[[:space:]]+$IFACE:[[:space:]]*$" "$NETPLAN"; then
                echo "[DEBUG]   iface $IFACE not found in $NETPLAN"
                continue
            fi

            # 1) найдём номер строки начала секции iface и её отступ
            START_LINE=$(awk -v ifc="$IFACE" '
                $0 ~ ("^[[:space:]]*" ifc ":[[:space:]]*$") { print NR; exit }
            ' "$NETPLAN")
            if [ -z "$START_LINE" ]; then
                echo "[DEBUG]   cannot detect start line for $IFACE"
                continue
            fi
            IFACE_INDENT=$(sed -n "${START_LINE}p" "$NETPLAN" | awk '{match($0,/[^ ]/); print RSTART-1}')
            echo "[DEBUG]   iface start at line $START_LINE (indent=$IFACE_INDENT)"

            # 2) внутри секции: найдём точную строку "dhcp4: true"
            DHCP_LINE=$(awk -v ifc="$IFACE" '
                BEGIN { inblk=0; ind=-1 }
                {
                    if ($0 ~ ("^[[:space:]]*" ifc ":[[:space:]]*$")) { inblk=1; ind=match($0,/[^ ]/)-1; next }
                    if (inblk && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) {
                        cur=match($0,/[^ ]/)-1; if (cur <= ind) inblk=0
                    }
                    if (inblk && $0 ~ /^[[:space:]]*dhcp4:[[:space:]]*true[[:space:]]*$/) { print NR; exit }
                }
            ' "$NETPLAN")
            if [ -z "$DHCP_LINE" ]; then
                echo "[DEBUG]   no 'dhcp4: true' found inside $IFACE block — skip"
                continue
            fi
            echo "[DEBUG]   dhcp4:true at line $DHCP_LINE"

            # 3) уже есть overrides/use-routes:false ?
            if awk -v ifc="$IFACE" '
                BEGIN { inblk=0; ind=-1; seen=0; ok=0 }
                {
                    if ($0 ~ ("^[[:space:]]*" ifc ":[[:space:]]*$")) { inblk=1; ind=match($0,/[^ ]/)-1; next }
                    if (inblk && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) {
                        cur=match($0,/[^ ]/)-1; if (cur <= ind) inblk=0
                    }
                    if (inblk && $0 ~ /^[[:space:]]*dhcp4-overrides:[[:space:]]*$/) seen=1
                    if (inblk && seen && $0 ~ /^[[:space:]]*use-routes:[[:space:]]*false[[:space:]]*$/) { ok=1; print; exit }
                }
                END { exit ok?0:1 }
            ' "$NETPLAN"; then
                echo "[DEBUG]   already has dhcp4-overrides/use-routes:false — skip patch"
                continue
            fi

            # 4) Бэкап и вставка после DHCP_LINE с тем же отступом, что у строки dhcp4
            backup_file "$NETPLAN"
            TMP=$(mktemp)
            DHCP_INDENT=$(sed -n "${DHCP_LINE}p" "$NETPLAN" | awk '{match($0,/[^ ]/); print RSTART-1}')
            PAD=$(printf '%*s' "$DHCP_INDENT" "")

            awk -v ins_after="$DHCP_LINE" -v pad="$PAD" '
                NR==ins_after {
                    print
                    print pad "dhcp4-overrides:"
                    print pad "  use-routes: false"
                    next
                }
                { print }
            ' "$NETPLAN" > "$TMP" && mv "$TMP" "$NETPLAN"

            echo "[DEBUG]   inserted overrides at ~line $((DHCP_LINE+1)) in $NETPLAN"
        done

        netplan apply 2>/dev/null || true   # предупреждение про OVS можно не показывать
        return 0
    fi


    # ===== 3. ifupdown (Debian/Ubuntu классика) =====
    if is_ifupdown; then
        echo "[DEBUG] Detected: ifupdown-compatible"
        # Проверим, есть ли dhclient в работе
        if pgrep -a dhclient | awk -v ifc="$IFACE" '{ if ($NF==ifc) found=1 } END { exit !found }'; then
            # Создаём hook вместо правки /etc/network/interfaces
            local HOOKDIR="/etc/dhcp/dhclient-enter-hooks.d"
            local HOOKFILE="$HOOKDIR/nodf-$IFACE"
            mkdir -p "$HOOKDIR"
            backup_file "$HOOKFILE"
            cat >"$HOOKFILE" <<EOF
#!/bin/sh
[ "\$interface" = "$IFACE" ] || exit 0
unset new_routers
unset new_rfc3442_classless_static_routes
unset new_classless_static_routes
echo "$(date) $interface $reason: new_routers='${new_routers:-<unset>}' new_rfc3442='${new_rfc3442_classless_static_routes:-<unset>}'" >> /var/log/dhclient-hooks.log
echo "$(date) $interface $reason: new_routers='${new_routers:-<unset>}' new_rfc3442='${new_rfc3442_classless_static_routes:-<unset>}' new_classless='${new_classless_static_routes:-<unset>}'" >> /var/log/dhclient-hooks.log
EOF
            chmod +x "$HOOKFILE"
            echo "[DEBUG] Created dhclient hook $HOOKFILE and log of hook see this /var/log/dhclient-hooks.log"
            return 0
        else
            # Fallback: классическая правка /etc/network/interfaces
            local FILE="/etc/network/interfaces"
            if grep -A3 -E "iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" "$FILE" >/dev/null; then
                backup_file "$FILE"
                if ! grep -A3 -E "iface[[:space:]]+$IFACE[[:space:]]+inet[[:space:]]+dhcp" "$FILE" | grep -q "post-up ip route del default dev $IFACE"; then
                    sed -i "/iface[[:space:]]\+$IFACE[[:space:]]\+inet[[:space:]]\+dhcp/a \    post-up ip route del default dev $IFACE" "$FILE"
                    echo "[DEBUG] Patched $FILE ($IFACE)"
                else
                    echo "[DEBUG] Already patched: $FILE ($IFACE)"
                fi
            else
                echo "[WARN] iface $IFACE dhcp stanza not found in $FILE"
            fi
            return 0
        fi
    fi

    # ===== 4. RHEL/CentOS ifcfg-$IFACE =====
    local RHFILE="/etc/sysconfig/network-scripts/ifcfg-$IFACE"
    if [ -f "$RHFILE" ]; then
        echo "[DEBUG] Detected: RHEL ifcfg-$IFACE"
        backup_file "$RHFILE"
        grep -q '^DEFROUTE=' "$RHFILE" || echo "DEFROUTE=no" >> "$RHFILE"
        grep -q '^PEERROUTES=' "$RHFILE" || echo "PEERROUTES=no" >> "$RHFILE"
        echo "[DEBUG] Patched: $RHFILE"
        return 0
    fi

    echo "[DEBUG] Unknown network stack for $IFACE; no changes made."
    return 1
}

# тест запуска: передай имя интерфейса
disable_dhcp_default_route "$1"
