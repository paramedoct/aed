network_require() {
  command -v nmcli >/dev/null || { echo 'Missing command: nmcli (NetworkManager)' >&2; return 2; }
}

network_recipe_load() {
  local file line key value seen=':' server rest
  file=$1
  [ -r "$file" ] || { echo "Cannot read network recipe: $file" >&2; return 2; }
  CONNECTION_UUID='' DHCP='' ADDRESS='' SUBNET_MASK='' GATEWAY='' DNS=''
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) echo "Invalid network recipe line: $line" >&2; return 2 ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      CONNECTION_UUID|DHCP|ADDRESS|SUBNET_MASK|GATEWAY|DNS) ;;
      *) echo "Unknown network recipe key: $key" >&2; return 2 ;;
    esac
    case "$seen" in *":$key:"*) echo "Duplicate network recipe key: $key" >&2; return 2 ;; esac
    seen="$seen$key:"
    printf -v "$key" '%s' "$value"
  done < "$file"
  for key in CONNECTION_UUID DHCP ADDRESS SUBNET_MASK GATEWAY DNS; do
    case "$seen" in *":$key:"*) ;; *) echo "Missing network recipe key: $key" >&2; return 2 ;; esac
  done
  case "$CONNECTION_UUID" in
    ''|*[!a-fA-F0-9-]*) echo 'Invalid CONNECTION_UUID.' >&2; return 2 ;;
  esac
  case "$DHCP" in on|off) ;; *) echo 'DHCP must be on or off.' >&2; return 2 ;; esac
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

network_apply() {
  local uuid active
  uuid=$1
  shift
  active=$(nmcli --get-values UUID connection show --active) || return 2
  nmcli connection modify uuid "$uuid" "$@" || {
    echo "Failed to save network configuration: $uuid" >&2; return 1;
  }
  printf 'Saved network configuration: %s\n' "$uuid"
  case $'\n'"$active"$'\n' in
    *$'\n'"$uuid"$'\n'*)
      nmcli --wait 60 connection up uuid "$uuid" || {
        echo "Failed to reactivate connection; saved configuration retained: $uuid" >&2
        return 1
      }
      ;;
    *) echo 'Inactive profile; configuration will apply on next activation.' ;;
  esac
}

network_configure() {
  local type gateway ignore_dns dns
  type=$(nmcli --get-values connection.type connection show uuid "$CONNECTION_UUID") || return 2
  case "$type" in
    802-3-ethernet|802-11-wireless) ;;
    *) echo 'Only Ethernet and Wi-Fi profiles are supported.' >&2; return 2 ;;
  esac
  dns=$DNS ignore_dns=yes
  [ "$dns" != auto ] || { dns=''; ignore_dns=no; }
  [ "$dns" != none ] || dns=''
  if [ "$DHCP" = on ]; then
    network_apply "$CONNECTION_UUID" ipv4.method auto ipv4.addresses '' ipv4.gateway '' \
      ipv4.routes '' ipv4.ignore-auto-routes no ipv4.never-default no \
      ipv4.dns "$dns" ipv4.dns-search '' ipv4.dns-options '' ipv4.dns-priority 0 \
      ipv4.ignore-auto-dns "$ignore_dns"
  else
    gateway=$GATEWAY
    [ "$gateway" != none ] || gateway=''
    network_apply "$CONNECTION_UUID" ipv4.method manual \
      ipv4.addresses "$ADDRESS/$NETWORK_PREFIX" ipv4.gateway "$gateway" \
      ipv4.routes '' ipv4.ignore-auto-routes no ipv4.never-default no \
      ipv4.dns "$dns" ipv4.dns-search '' ipv4.dns-options '' ipv4.dns-priority 0 \
      ipv4.ignore-auto-dns "$ignore_dns"
  fi
}

network_collect_dns() {
  local uuid property value
  uuid=$1
  NETWORK_DNS_OVERRIDE=no
  for property in dns dns-search dns-options dns-priority ignore-auto-dns; do
    value=$(nmcli --get-values "ipv4.$property" connection show uuid "$uuid") || {
      echo "Cannot query IPv4 DNS configuration: $uuid" >&2; return 2;
    }
    case "$property:$value" in
      dns:|dns-search:|dns-options:|dns-priority:0|ignore-auto-dns:no) ;;
      *) NETWORK_DNS_OVERRIDE=yes ;;
    esac
  done
}

network_collect() {
  local connections active uuid type method
  NETWORK_UUIDS=() NETWORK_METHODS=() NETWORK_ACTIVE=() NETWORK_DNS=()
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
    NETWORK_DNS[NETWORK_COUNT]=no
    case "$method" in
      auto|manual)
        network_collect_dns "$uuid" || return 2
        NETWORK_DNS[NETWORK_COUNT]=$NETWORK_DNS_OVERRIDE
        ;;
    esac
    case $'\n'"$active"$'\n' in
      *$'\n'"$uuid"$'\n'*) NETWORK_ACTIVE[NETWORK_COUNT]=yes ;;
      *) NETWORK_ACTIVE[NETWORK_COUNT]=no ;;
    esac
    NETWORK_COUNT=$((NETWORK_COUNT + 1))
  done <<< "$connections"
}

network_status() {
  local index result=0
  network_collect || return 2
  echo 'Network manager: NetworkManager'
  for ((index = 0; index < NETWORK_COUNT; index++)); do
    printf 'Connection: %s\nActive: %s\nIPv4 method: %s\nIPv4 DNS overrides: %s\n' \
      "${NETWORK_UUIDS[index]}" "${NETWORK_ACTIVE[index]}" "${NETWORK_METHODS[index]}" \
      "${NETWORK_DNS[index]}"
    [ "${NETWORK_METHODS[index]}" != manual ] || result=1
    [ "${NETWORK_DNS[index]}" != yes ] || result=1
  done
  if [ "$result" -eq 0 ]; then
    echo 'Network result: no manual IPv4 or DNS configuration'
  else
    echo 'Network result: recovery needed'
  fi
  return "$result"
}

network_recover() {
  local index uuid result=0
  local -a settings
  network_collect || return 2
  for ((index = 0; index < NETWORK_COUNT; index++)); do
    if [ "${NETWORK_METHODS[index]}" != manual ] && [ "${NETWORK_DNS[index]}" != yes ]; then
      continue
    fi
    uuid=${NETWORK_UUIDS[index]}
    settings=(ipv4.dns '' ipv4.dns-search '' ipv4.dns-options ''
      ipv4.dns-priority 0 ipv4.ignore-auto-dns no)
    if [ "${NETWORK_METHODS[index]}" = manual ]; then
      settings+=(ipv4.method auto ipv4.addresses '' ipv4.gateway ''
        ipv4.routes '' ipv4.ignore-auto-routes no ipv4.never-default no)
    fi
    nmcli connection modify uuid "$uuid" "${settings[@]}" || {
      echo "Failed to reset IPv4 configuration: $uuid" >&2; result=1; continue;
    }
    printf 'Restored automatic IPv4/DNS configuration: %s\n' "$uuid"
    if [ "${NETWORK_ACTIVE[index]}" = yes ]; then
      nmcli --wait 60 connection up uuid "$uuid" || {
        echo "Failed to reactivate connection; automatic configuration retained: $uuid" >&2
        result=1
      }
    fi
  done
  network_status || result=1
  return "$result"
}
