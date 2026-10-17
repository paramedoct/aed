network_require() {
  command -v nmcli >/dev/null || { echo 'Missing command: nmcli (NetworkManager)' >&2; return 2; }
}

network_validate_command() {
  local server
  if [ "$#" -eq 3 ] && [ "$1" = dhcp ] && [ -n "$2" ]; then
    case "$3" in on|off) return 0 ;; esac
  fi
  if [ "$#" -eq 5 ] && [ "$1" = manual ] && [ -n "$2" ]; then
    network_validate_ipv4 "$3" || return 2
    network_mask_prefix "$4" >/dev/null || return 2
    if [ "$5" != none ]; then network_validate_ipv4 "$5" || return 2; fi
    return 0
  fi
  if [ "$#" -ge 3 ] && [ "$1" = dns ] && [ -n "$2" ]; then
    if [ "$#" -eq 3 ] && [ "$3" = auto ]; then return 0; fi
    shift 2
    for server in "$@"; do network_validate_ipv4 "$server" || return 2; done
    return 0
  fi
  echo 'Usage: ./network dhcp <connection-uuid> <on|off>' >&2
  echo '       ./network manual <connection-uuid> <ipv4> <subnet-mask> <gateway|none>' >&2
  echo '       ./network dns <connection-uuid> <auto|ipv4-server [ipv4-server ...]>' >&2
  return 2
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
  local uuid type addresses prefix gateway servers server
  network_validate_command "$@" || return 2
  uuid=$2
  type=$(nmcli --get-values connection.type connection show uuid "$uuid") || return 2
  case "$type" in
    802-3-ethernet|802-11-wireless) ;;
    *) echo 'Only Ethernet and Wi-Fi profiles are supported.' >&2; return 2 ;;
  esac
  if [ "$1" = dns ]; then
    if [ "$3" = auto ]; then
      network_apply "$uuid" ipv4.dns '' ipv4.dns-search '' ipv4.dns-options '' \
        ipv4.dns-priority 0 ipv4.ignore-auto-dns no
    else
      shift 2
      servers=''
      for server in "$@"; do servers="${servers:+$servers,}$server"; done
      network_apply "$uuid" ipv4.dns "$servers" ipv4.ignore-auto-dns yes
    fi
    return $?
  fi
  if [ "$1" = manual ]; then
    prefix=$(network_mask_prefix "$4") || return 2
    gateway=$5
    [ "$gateway" != none ] || gateway=''
    network_apply "$uuid" ipv4.method manual ipv4.addresses "$3/$prefix" \
      ipv4.gateway "$gateway" ipv4.never-default no
    return $?
  fi
  case "$3" in
    on)
      network_apply "$uuid" ipv4.method auto ipv4.addresses '' ipv4.gateway '' \
        ipv4.routes '' ipv4.ignore-auto-routes no ipv4.never-default no
      ;;
    off)
      addresses=$(nmcli --get-values ipv4.addresses connection show uuid "$uuid") || return 2
      [ -n "$addresses" ] || {
        echo 'DHCP off requires a saved static IPv4 address; configure manual IPv4 first.' >&2
        return 2
      }
      network_apply "$uuid" ipv4.method manual
      ;;
  esac
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
