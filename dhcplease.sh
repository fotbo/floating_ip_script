#!/usr/bin/env bash
# dhcp-lease-left.sh (Debian 11/12, RHEL)
set -euo pipefail

now_epoch() { date +%s; }

fmt_left() {
  local left="$1"
  if (( left < 0 )); then printf "истекла %d сек назад" $((-left)); return; fi
  local d=$(( left/86400 )); local h=$(( (left%86400)/3600 ))
  local m=$(( (left%3600)/60 )); local s=$(( left%60 ))
  (( d>0 )) && printf "%dд %02d:%02d:%02d" "$d" "$h" "$m" "$s" || printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

print_line() {
  local ifname="$1" exp="$2" src="$3"
  local left=$(( exp - $(now_epoch) ))
  printf "%-15s — %-18s (истекает %s) [%s]\n" \
    "$ifname" "$(fmt_left "$left")" "$(date -d @"$exp" '+%F %T')" "$src"
}

have_nm()        { systemctl is-active --quiet NetworkManager 2>/dev/null; }
have_networkd()  { systemctl is-active --quiet systemd-networkd 2>/dev/null; }

# ---------------- NetworkManager ----------------
collect_nm() {
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$2=="connected"{print $1}' | while read -r d; do
    exp="$(nmcli -g DHCP4.OPTION device show "$d" 2>/dev/null | grep -E '^expiry *= *[0-9]+' | tail -n1 | awk -F= '{print $2}' || true)"
    [ -n "${exp:-}" ] && print_line "$d" "$exp" "NM/DHCP4"
  done
}

# ---------------- systemd-networkd ----------------
# В Debian 12 часто есть TIMESTAMP(_USEC) и LIFETIME(_SEC) -> expiry = timestamp + lifetime
expiry_from_networkd_file() {
  local f="$1"
  # 1) прямые поля истечения
  local k v
  for k in LEASE_EXPIRY EXPIRY; do
    v="$(grep -E "^${k}=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return 0; }
  done
  v="$(grep -E '^EXPIRY_USEC=' "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
  [[ "$v" =~ ^[0-9]+$ ]] && { echo $(( v/1000000 )); return 0; }

  # 2) считаем из TIMESTAMP + LIFETIME
  local ts=""
  for k in TIMESTAMP_USEC ACQUIRED_USEC BOUND_USEC; do
    v="$(grep -E "^${k}=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { ts=$(( v/1000000 )); break; }
  done
  if [ -z "$ts" ]; then
    ts="$(grep -E '^TIMESTAMP=' "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=""
  fi
  # если нет явного timestamp — возьмём mtime файла как приблизительный момент acquire
  if [ -z "$ts" ]; then
    ts="$(stat -c %Y "$f" 2>/dev/null || true)"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=""
  fi

  # lifetime
  local life=""
  for k in LIFETIME_SEC LIFETIME; do
    v="$(grep -E "^${k}=" "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { life="$v"; break; }
  done
  if [ -z "$life" ]; then
    v="$(grep -E '^VALID_LIFETIME_USEC=' "$f" 2>/dev/null | tail -n1 | cut -d= -f2 || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && life=$(( v/1000000 ))
  fi

  if [ -n "$ts" ] && [ -n "$life" ]; then
    echo $(( ts + life ))
    return 0
  fi
  return 1
}

collect_networkd() {
  # карта ifindex -> ifname (надёжный парсинг)
  ip -o link show | awk -F': ' '{print $1 ":" $2}' | while IFS=: read -r idx ifname; do
    idx="${idx//[[:space:]]/}"
    ifname="${ifname%@*}"
    for f in "/run/systemd/netif/leases/$idx" "/var/lib/systemd/netif/leases/$idx"; do
      [ -f "$f" ] || continue
      if exp="$(expiry_from_networkd_file "$f")"; then
        print_line "$ifname" "$exp" "networkd"
      else
        printf "%-15s — нет данных об expiry (networkd)\n" "$ifname"
      fi
    done
  done
}

# ---------------- dhclient (Debian/RHEL) ----------------
find_lease_block_for_iface() {
  local ifname="$1" file="$2"
  awk -v IGNORECASE=1 -v IF="$ifname" '
    BEGIN{RS="}"; ORS="}"; keep=""}
    /lease[[:space:]]*\{/ {
      if ($0 ~ "interface[[:space:]]+\"" IF "\"" &&
          $0 ~ "binding state[[:space:]]+(active|renewing|rebinding|bound)") {
        keep=$0
      }
    }
    END{print keep}
  ' "$file"
}

epoch_from_dhclient_block() {
  local block="$1"
  local ts
  ts="$(printf '%s' "$block" | sed -n -E 's#.*expire[[:space:]]+[0-9]+[[:space:]]+([0-9]{4}/[0-9]{2}/[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}).*#\1 \2#p')"
  if [ -n "$ts" ]; then date -d "$ts" +%s 2>/dev/null && return 0; fi
  printf '%s' "$block" | sed -n -E 's/.*expire[[:space:]]+([0-9]{10}).*/\1/p'
}

collect_dhclient() {
  # интерфейсы с динамическим IPv4
  local ifs
  ifs="$(ip -o -4 addr show | grep -w dynamic | awk '{print $2}' | sort -u || true)"
  [ -n "$ifs" ] || ifs="$(ip -o link show up | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' || true)"

  for ifname in $ifs; do
    local epoch="" ep block lf
    # per-if файлы (оба формата имён и пути)
    for lf in "/var/lib/dhcp/dhclient.${ifname}.leases" \
              "/var/lib/dhcp/dhclient-${ifname}.leases" \
              "/var/lib/dhclient/dhclient-${ifname}.leases" \
              "/var/lib/dhcp/dhclient.${ifname}.lease" \
              "/var/lib/dhcp/dhclient-${ifname}.lease" \
              "/var/lib/dhclient/dhclient-${ifname}.lease"
    do
      [ -f "$lf" ] || continue
      block="$(find_lease_block_for_iface "$ifname" "$lf")"
      [ -n "$block" ] || continue
      ep="$(epoch_from_dhclient_block "$block" || true)"
      [[ "$ep" =~ ^[0-9]+$ ]] && epoch="$ep"
    done
    # общий файл — в крайнем случае
    if [ -z "${epoch:-}" ] && [ -f /var/lib/dhcp/dhclient.leases ]; then
      block="$(find_lease_block_for_iface "$ifname" /var/lib/dhcp/dhclient.leases || true)"
      [ -n "$block" ] && ep="$(epoch_from_dhclient_block "$block" || true)" && epoch="$ep"
    fi
    [[ "${epoch:-}" =~ ^[0-9]+$ ]] && print_line "$ifname" "$epoch" "dhclient"
  done
}

main() {
  echo "Интерфейс        — Оставшееся время   (истекает)           [источник]"
  echo "-----------------------------------------------------------------------"
  local any=0
  have_nm        && { collect_nm;        any=1; }
  have_networkd  && { collect_networkd;  any=1; }
  collect_dhclient && any=1
  (( any )) || echo "Источник данных не найден (NM/networkd/dhclient)."
}
main
