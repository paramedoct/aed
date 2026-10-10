TIME_SYNC_MARKER=/run/systemd/timesync/synchronized

recovery_uptime() {
  local uptime rest
  read -r uptime rest < /proc/uptime || { echo 'Cannot read monotonic uptime.' >&2; return 2; }
  printf '%s\n' "${uptime%%.*}"
}

recovery_preflight() {
  local command base path
  for command in rm sleep; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; return 2; }
  done
  recovery_check_services || return 2
  for base in "${TIME_CONFIG_DIRS[@]}"; do
    path="$base/timesyncd.conf"
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      echo "Expected a configuration file, found a directory: $path" >&2; return 2
    fi
    path="$base/timesyncd.conf.d"
    if [ -L "$path" ]; then continue; fi
    if [ -e "$path" ] && [ ! -d "$path" ]; then
      echo "Expected a configuration directory: $path" >&2; return 2
    fi
    for path in "$base/timesyncd.conf.d/"*.conf; do
      if [ -d "$path" ] && [ ! -L "$path" ]; then
        echo "Expected a configuration file, found a directory: $path" >&2; return 2
      fi
    done
  done
  [ ! -d "$TIME_SYNC_MARKER" ] || { echo 'Invalid synchronization marker.' >&2; return 2; }
  recovery_uptime >/dev/null || return 2
}

recovery_check_services() {
  local units unit rest
  time_collect || return 2
  [ "$TIME_LOAD" != not-found ] || { echo 'systemd-timesyncd is not installed.' >&2; return 2; }
  units=$(systemctl list-units --type=service --state=active,activating \
    --all --plain --no-legend --no-pager) || { echo 'Cannot check competing services.' >&2; return 2; }
  while read -r unit rest; do
    case "$unit" in
      chrony.service|chronyd.service|ntp.service|ntpd.service|ntpsec.service|openntpd.service)
        echo "Competing time service is active: $unit" >&2; return 2 ;;
    esac
  done <<< "$units"
}

recovery_reset() {
  local base path
  for base in "${TIME_CONFIG_DIRS[@]}"; do
    path="$base/timesyncd.conf"
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -f -- "$path" || return 1
      printf 'Removed: %s\n' "$path"
    fi
    path="$base/timesyncd.conf.d"
    if [ -L "$path" ]; then
      rm -f -- "$path" || return 1
      printf 'Removed: %s\n' "$path"
      continue
    fi
    for path in "$base/timesyncd.conf.d/"*.conf; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f -- "$path" || return 1
        printf 'Removed: %s\n' "$path"
      fi
    done
  done
}

recovery_wait() {
  local started now
  started=$(recovery_uptime) || return 1
  while :; do
    time_collect || return 1
    if [ -f "$TIME_SYNC_MARKER" ] && [ ! -L "$TIME_SYNC_MARKER" ] && \
      [ "$TIME_SYNC" = yes ] && [ "$TIME_ACTIVE" = active ]; then return 0; fi
    now=$(recovery_uptime) || return 1
    if [ "$((now - started))" -ge "$SYNC_TIMEOUT" ]; then
      echo 'Timed out waiting for a new time synchronization.' >&2; return 1
    fi
    sleep 1 || return 1
  done
}

recovery_run() {
  local result=0
  systemctl stop "$TIME_SERVICE" || { echo 'Failed to stop the time service.' >&2; return 1; }
  recovery_reset || { echo 'Failed to reset local time configuration.' >&2; return 1; }
  timedatectl set-timezone "$TIMEZONE" || { echo 'Failed to apply the timezone.' >&2; return 1; }
  rm -f -- "$TIME_SYNC_MARKER" || { echo 'Failed to clear the previous synchronization marker.' >&2; return 1; }
  systemctl unmask "$TIME_SERVICE" || { echo 'Failed to unmask the time service.' >&2; return 1; }
  systemctl enable "$TIME_SERVICE" || { echo 'Failed to enable the time service.' >&2; return 1; }
  systemctl restart "$TIME_SERVICE" || { echo 'Failed to restart the time service.' >&2; return 1; }
  recovery_wait || result=1
  time_status || result=1
  if [ "$result" -ne 0 ]; then
    echo 'Recovery result: incomplete'
    echo 'Recovery incomplete; applied changes have been retained.' >&2
  else
    echo 'Recovery result: complete'
  fi
  return "$result"
}
