network_require() {
  command -v nmcli >/dev/null || { echo 'Missing command: nmcli (NetworkManager)' >&2; return 2; }
}

network_validate_ipv4() {
  local address octet
  local -a octets
  address=$1
  case "$address" in
    ''|*[!0-9.]*|.*|*.|*..*) echo "Invalid IPv4 address: $address" >&2; return 2 ;;
  esac
  IFS=. read -r -a octets <<< "$address"
  [ "${#octets[@]}" -eq 4 ] || { echo "Invalid IPv4 address: $address" >&2; return 2; }
  for octet in "${octets[@]}"; do
    if [ "${#octet}" -gt 3 ] || [ "$((10#$octet))" -gt 255 ]; then
      echo "Invalid IPv4 address: $address" >&2; return 2
    fi
    case "$octet" in 0?*) echo "Ambiguous IPv4 octet: $octet" >&2; return 2 ;; esac
  done
}

network_mask_prefix() {
  local mask octet bit prefix=0 zero_seen=no
  local -a octets
  mask=$1
  network_validate_ipv4 "$mask" || return 2
  IFS=. read -r -a octets <<< "$mask"
  for octet in "${octets[@]}"; do
    for ((bit = 7; bit >= 0; bit--)); do
      if [ "$(( (10#$octet >> bit) & 1 ))" -eq 1 ]; then
        [ "$zero_seen" = no ] || { echo "Non-contiguous subnet mask: $mask" >&2; return 2; }
        prefix=$((prefix + 1))
      else
        zero_seen=yes
      fi
    done
  done
  [ "$prefix" -gt 0 ] || { echo 'A static IPv4 address requires a nonzero prefix.' >&2; return 2; }
  printf '%s\n' "$prefix"
}

network_recipe_validate() {
  local server rest
  case "$CONNECTION_UUID" in
    *[!a-fA-F0-9-]*) echo 'Set a valid CONNECTION_UUID in aed.conf.' >&2; return 2 ;;
  esac
  case "$DHCP" in on|off) ;; *) echo 'DHCP must be on or off.' >&2; return 2 ;; esac
  if [ -z "$CONNECTION_UUID" ]; then
    [ "$DHCP" = on ] && [ -z "$ADDRESS" ] && [ -z "$SUBNET_MASK" ] && \
      [ -z "$GATEWAY" ] && [ "$DNS" = auto ] || {
        echo 'Set CONNECTION_UUID for network settings in aed.conf.' >&2; return 2;
      }
    return 0
  fi
  if [ "$DHCP" = on ]; then
    [ -z "$ADDRESS" ] && [ -z "$SUBNET_MASK" ] && [ -z "$GATEWAY" ] || {
      echo 'ADDRESS, SUBNET_MASK and GATEWAY must be empty when DHCP is on.' >&2; return 2;
    }
  else
    network_validate_ipv4 "$ADDRESS" || return 2
    NETWORK_PREFIX=$(network_mask_prefix "$SUBNET_MASK") || return 2
    if [ "$GATEWAY" != none ]; then network_validate_ipv4 "$GATEWAY" || return 2; fi
  fi
  case "$DNS" in
    auto)
      [ "$DHCP" = on ] || { echo 'DNS=auto requires DHCP=on.' >&2; return 2; }
      ;;
    none) ;;
    '') echo 'DNS must be auto, none or comma-separated IPv4 servers.' >&2; return 2 ;;
    *)
      rest=$DNS
      while :; do
        server=${rest%%,*}
        network_validate_ipv4 "$server" || return 2
        [ "$rest" != "$server" ] || break
        rest=${rest#*,}
      done
      ;;
  esac
}

network_apply() {
  local active
  active=$(nmcli --get-values UUID connection show --active) || return 2
  nmcli connection modify uuid "$CONNECTION_UUID" "$@" || {
    echo "Failed to save network configuration: $CONNECTION_UUID" >&2; return 1;
  }
  printf 'Saved network configuration: %s\n' "$CONNECTION_UUID"
  case $'\n'"$active"$'\n' in
    *$'\n'"$CONNECTION_UUID"$'\n'*)
      nmcli --wait 60 connection up uuid "$CONNECTION_UUID" || {
        echo "Failed to reactivate connection; saved configuration retained: $CONNECTION_UUID" >&2
        return 1
      }
      ;;
    *) echo 'Inactive profile; configuration will apply on next activation.' ;;
  esac
}

network_apply_recipe() {
  local type gateway ignore_dns dns
  [ -n "$CONNECTION_UUID" ] || return 0
  type=$(nmcli --get-values connection.type connection show uuid "$CONNECTION_UUID") || return 2
  case "$type" in
    802-3-ethernet|802-11-wireless) ;;
    *) echo 'Only Ethernet and Wi-Fi profiles are supported.' >&2; return 2 ;;
  esac
  dns=$DNS ignore_dns=yes
  [ "$dns" != auto ] || { dns=''; ignore_dns=no; }
  [ "$dns" != none ] || dns=''
  if [ "$DHCP" = on ]; then
    network_apply ipv4.method auto ipv4.addresses '' ipv4.gateway '' \
      ipv4.routes '' ipv4.ignore-auto-routes no ipv4.never-default no \
      ipv4.dns "$dns" ipv4.dns-search '' ipv4.dns-options '' ipv4.dns-priority 0 \
      ipv4.ignore-auto-dns "$ignore_dns"
  else
    gateway=$GATEWAY
    [ "$gateway" != none ] || gateway=''
    network_apply ipv4.method manual ipv4.addresses "$ADDRESS/$NETWORK_PREFIX" \
      ipv4.gateway "$gateway" ipv4.routes '' ipv4.ignore-auto-routes no \
      ipv4.never-default no ipv4.dns "$dns" ipv4.dns-search '' \
      ipv4.dns-options '' ipv4.dns-priority 0 ipv4.ignore-auto-dns "$ignore_dns"
  fi
}

network_collect() {
  local connections active uuid type method
  NETWORK_UUIDS=() NETWORK_METHODS=() NETWORK_ACTIVE=()
  NETWORK_ADDRESSES=() NETWORK_GATEWAYS=() NETWORK_DNS=() NETWORK_IGNORE_AUTO_DNS=()
  NETWORK_APPLIED_ADDRESSES=() NETWORK_APPLIED_GATEWAYS=() NETWORK_APPLIED_DNS=()
  NETWORK_COUNT=0
  connections=$(nmcli --get-values UUID connection show) || {
    echo 'Cannot query NetworkManager profiles.' >&2; return 2;
  }
  active=$(nmcli --get-values UUID connection show --active) || {
    echo 'Cannot query active NetworkManager connections.' >&2; return 2;
  }
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    type=$(nmcli --get-values connection.type connection show uuid "$uuid") || return 2
    case "$type" in 802-3-ethernet|802-11-wireless) ;; *) continue ;; esac
    method=$(nmcli --get-values ipv4.method connection show uuid "$uuid") || return 2
    [ -n "$method" ] || { echo "Missing IPv4 method: $uuid" >&2; return 2; }
    NETWORK_UUIDS[NETWORK_COUNT]=$uuid
    NETWORK_METHODS[NETWORK_COUNT]=$method
    NETWORK_ADDRESSES[NETWORK_COUNT]=$(nmcli --get-values ipv4.addresses connection show uuid "$uuid") || return 2
    NETWORK_GATEWAYS[NETWORK_COUNT]=$(nmcli --get-values ipv4.gateway connection show uuid "$uuid") || return 2
    NETWORK_DNS[NETWORK_COUNT]=$(nmcli --get-values ipv4.dns connection show uuid "$uuid") || return 2
    NETWORK_IGNORE_AUTO_DNS[NETWORK_COUNT]=$(nmcli --get-values ipv4.ignore-auto-dns connection show uuid "$uuid") || return 2
    case $'\n'"$active"$'\n' in
      *$'\n'"$uuid"$'\n'*)
        NETWORK_ACTIVE[NETWORK_COUNT]=yes
        NETWORK_APPLIED_ADDRESSES[NETWORK_COUNT]=$(nmcli --get-values IP4.ADDRESS connection show uuid "$uuid") || return 2
        NETWORK_APPLIED_GATEWAYS[NETWORK_COUNT]=$(nmcli --get-values IP4.GATEWAY connection show uuid "$uuid") || return 2
        NETWORK_APPLIED_DNS[NETWORK_COUNT]=$(nmcli --get-values IP4.DNS connection show uuid "$uuid") || return 2
        ;;
      *)
        NETWORK_ACTIVE[NETWORK_COUNT]=no
        NETWORK_APPLIED_ADDRESSES[NETWORK_COUNT]=''
        NETWORK_APPLIED_GATEWAYS[NETWORK_COUNT]=''
        NETWORK_APPLIED_DNS[NETWORK_COUNT]=''
        ;;
    esac
    NETWORK_COUNT=$((NETWORK_COUNT + 1))
  done <<< "$connections"
}

network_status() {
  local index
  network_collect || return 2
  echo 'Network manager: NetworkManager'
  for ((index = 0; index < NETWORK_COUNT; index++)); do
    printf 'Connection: %s\nActive: %s\nIPv4 method: %s\nConfigured IPv4 addresses: %s\n' \
      "${NETWORK_UUIDS[index]}" "${NETWORK_ACTIVE[index]}" \
      "${NETWORK_METHODS[index]}" "${NETWORK_ADDRESSES[index]}"
    printf 'Configured IPv4 gateway: %s\nConfigured IPv4 DNS: %s\nIgnore automatic DNS: %s\n' \
      "${NETWORK_GATEWAYS[index]}" "${NETWORK_DNS[index]}" \
      "${NETWORK_IGNORE_AUTO_DNS[index]}"
    if [ "${NETWORK_ACTIVE[index]}" = yes ]; then
      printf 'Applied IPv4 addresses: %s\nApplied IPv4 gateway: %s\nApplied IPv4 DNS: %s\n' \
        "${NETWORK_APPLIED_ADDRESSES[index]}" "${NETWORK_APPLIED_GATEWAYS[index]}" \
        "${NETWORK_APPLIED_DNS[index]}"
    fi
  done
}
