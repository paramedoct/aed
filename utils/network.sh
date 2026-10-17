network_require() {
  command -v nmcli >/dev/null || { echo 'Missing command: nmcli (NetworkManager)' >&2; return 2; }
}

network_validate_command() {
  if [ "$#" -eq 3 ] && [ "$1" = dhcp ] && [ -n "$2" ]; then
    case "$3" in on|off) return 0 ;; esac
  fi
  echo 'Usage: ./network dhcp <connection-uuid> <on|off>' >&2
  return 2
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
  local uuid type addresses
  network_validate_command "$@" || return 2
  uuid=$2
  type=$(nmcli --get-values connection.type connection show uuid "$uuid") || return 2
  case "$type" in
    802-3-ethernet|802-11-wireless) ;;
    *) echo 'Only Ethernet and Wi-Fi profiles are supported.' >&2; return 2 ;;
  esac
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
