TIME_SERVICE=systemd-timesyncd.service
TIME_CONFIG_DIRS=(/etc/systemd /run/systemd)

time_require() {
  local command
  [ "$(uname -s)" = Linux ] || { echo 'Only Linux is supported.' >&2; return 2; }
  for command in systemctl timedatectl date; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; return 2; }
  done
}

time_collect() {
  local properties line key value
  TIME_LOAD='' TIME_ENABLED='' TIME_ACTIVE='' TIME_ZONE='' TIME_SYNC='' TIME_NTP=''
  TIME_SERVER='' TIME_ADDRESS=''
  properties=$(systemctl show "$TIME_SERVICE" --no-pager \
    --property=LoadState --property=UnitFileState --property=ActiveState) || {
    echo 'Cannot query the time service.' >&2; return 2;
  }
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      LoadState) TIME_LOAD=$value ;;
      UnitFileState) TIME_ENABLED=$value ;;
      ActiveState) TIME_ACTIVE=$value ;;
    esac
  done <<< "$properties"
  case "$TIME_LOAD" in
    loaded|masked|not-found) ;;
    *) echo 'Cannot determine the time service state.' >&2; return 2 ;;
  esac
  properties=$(timedatectl show --property=Timezone --property=NTPSynchronized --property=NTP) || {
    echo 'Cannot query the system clock.' >&2; return 2;
  }
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      Timezone) TIME_ZONE=$value ;;
      NTPSynchronized) TIME_SYNC=$value ;;
      NTP) TIME_NTP=$value ;;
    esac
  done <<< "$properties"
  [ -n "$TIME_ZONE" ] && [ -n "$TIME_SYNC" ] && [ -n "$TIME_NTP" ] || {
    echo 'Incomplete clock properties.' >&2; return 2;
  }
  if [ "$TIME_ACTIVE" = active ]; then
    properties=$(timedatectl show-timesync --property=ServerName --property=ServerAddress) || {
      echo 'Cannot query time synchronization details.' >&2; return 2;
    }
    while IFS= read -r line; do
      key=${line%%=*}; value=${line#*=}
      case "$key" in ServerName) TIME_SERVER=$value ;; ServerAddress) TIME_ADDRESS=$value ;; esac
    done <<< "$properties"
  fi
}

time_has_overrides() {
  local base path
  for base in "${TIME_CONFIG_DIRS[@]}"; do
    path="$base/timesyncd.conf"
    if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    path="$base/timesyncd.conf.d"
    if [ -L "$path" ]; then return 0; fi
    for path in "$base/timesyncd.conf.d/"*.conf; do
      if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    done
  done
  return 1
}

time_status() {
  local overrides=no result=0 local_time utc_time
  : "${TIMEZONE:?Configuration must be loaded first}"
  time_collect || return 2
  local_time=$(date '+%Y-%m-%d %H:%M:%S %Z') || return 2
  utc_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC') || return 2
  if time_has_overrides; then overrides=yes; result=1; fi
  [ "$TIME_LOAD" = loaded ] && [ "$TIME_ENABLED" = enabled ] && \
    [ "$TIME_ACTIVE" = active ] && [ "$TIME_ZONE" = "$TIMEZONE" ] && \
    [ "$TIME_NTP" = yes ] && [ "$TIME_SYNC" = yes ] || result=1
  printf 'Local time: %s\nUTC time: %s\nTimezone: %s\nTarget timezone: %s\n' \
    "$local_time" "$utc_time" "$TIME_ZONE" "$TIMEZONE"
  printf 'Local overrides: %s\nService load: %s\nService startup: %s\nService state: %s\n' \
    "$overrides" "$TIME_LOAD" "${TIME_ENABLED:-unknown}" "${TIME_ACTIVE:-unknown}"
  printf 'Time server: %s\nServer address: %s\nNTP enabled: %s\nSynchronized: %s\n' \
    "${TIME_SERVER:-unknown}" "${TIME_ADDRESS:-unknown}" "$TIME_NTP" "$TIME_SYNC"
  if [ "$result" -eq 0 ]; then echo 'Result: healthy'; else echo 'Result: recovery needed'; fi
  return "$result"
}
