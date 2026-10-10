#!/usr/bin/env bash

config_load() {
  local file line key value seen_timezone=0 seen_timeout=0
  file=$1
  [ -r "$file" ] || { echo "Cannot read configuration: $file" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) echo 'Invalid configuration line.' >&2; return 2 ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      TIMEZONE)
        [ "$seen_timezone" -eq 0 ] || { echo 'Duplicate TIMEZONE.' >&2; return 2; }
        TIMEZONE=$value
        seen_timezone=1
        ;;
      SYNC_TIMEOUT)
        [ "$seen_timeout" -eq 0 ] || { echo 'Duplicate SYNC_TIMEOUT.' >&2; return 2; }
        SYNC_TIMEOUT=$value
        seen_timeout=1
        ;;
      *) echo "Unknown configuration key: $key" >&2; return 2 ;;
    esac
  done < "$file"
  [ "$seen_timezone" -eq 1 ] && [ "$seen_timeout" -eq 1 ] || {
    echo 'TIMEZONE and SYNC_TIMEOUT are required.' >&2; return 2;
  }
  case "$TIMEZONE" in ''|/*|*..*|*[!a-zA-Z0-9_+/-]*) echo 'Invalid TIMEZONE.' >&2; return 2 ;; esac
  [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || { echo 'Unknown TIMEZONE.' >&2; return 2; }
  case "$SYNC_TIMEOUT" in ''|*[!0-9]*) echo 'Invalid SYNC_TIMEOUT.' >&2; return 2 ;; esac
  [ "${#SYNC_TIMEOUT}" -le 4 ] || { echo 'SYNC_TIMEOUT must be between 1 and 3600.' >&2; return 2; }
  SYNC_TIMEOUT=$((10#$SYNC_TIMEOUT))
  [ "$SYNC_TIMEOUT" -ge 1 ] && [ "$SYNC_TIMEOUT" -le 3600 ] || {
    echo 'SYNC_TIMEOUT must be between 1 and 3600.' >&2; return 2;
  }
}
