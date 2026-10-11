network_require() {
  command -v nmcli >/dev/null || { echo 'Missing command: nmcli (NetworkManager)' >&2; return 2; }
}

network_collect() {
  local connections active uuid type method
  NETWORK_UUIDS=() NETWORK_METHODS=() NETWORK_ACTIVE=()
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
    printf 'Connection: %s\nActive: %s\nIPv4 method: %s\n' \
      "${NETWORK_UUIDS[index]}" "${NETWORK_ACTIVE[index]}" "${NETWORK_METHODS[index]}"
    [ "${NETWORK_METHODS[index]}" != manual ] || result=1
  done
  if [ "$result" -eq 0 ]; then
    echo 'Network result: no manual IPv4 configuration'
  else
    echo 'Network result: recovery needed'
  fi
  return "$result"
}

network_recover() {
  local index uuid result=0
  network_collect || return 2
  for ((index = 0; index < NETWORK_COUNT; index++)); do
    [ "${NETWORK_METHODS[index]}" = manual ] || continue
    uuid=${NETWORK_UUIDS[index]}
    nmcli connection modify uuid "$uuid" \
      ipv4.method auto ipv4.addresses '' ipv4.gateway '' \
      ipv4.dns '' ipv4.dns-search '' ipv4.routes '' \
      ipv4.ignore-auto-dns no ipv4.ignore-auto-routes no ipv4.never-default no || {
      echo "Failed to reset IPv4 configuration: $uuid" >&2; result=1; continue;
    }
    printf 'Restored automatic IPv4 configuration: %s\n' "$uuid"
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
