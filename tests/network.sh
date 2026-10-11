#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=utils/network.sh
source "$ROOT_DIR/utils/network.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

nmcli() {
  local uuid
  case "$*" in
    '--get-values UUID connection show')
      [ "$TEST_MODE" != query-failure ] || return 1
      [ "$TEST_MODE" != empty ] || return 0
      printf '%s\n' wired wifi automatic hotspot vpn
      ;;
    '--get-values UUID connection show --active') printf '%s\n' wired automatic hotspot vpn ;;
    '--get-values connection.type connection show uuid '* )
      case "$6" in wifi|hotspot) echo 802-11-wireless ;; vpn) echo vpn ;; *) echo 802-3-ethernet ;; esac
      ;;
    '--get-values ipv4.method connection show uuid '* )
      uuid=$6
      case "$uuid" in
        automatic) echo auto ;;
        hotspot) echo shared ;;
        *) if [ -f "$TEST_DIR/$uuid" ]; then echo auto; else echo manual; fi ;;
      esac
      ;;
    'connection modify uuid '* )
      printf '%s\n' "$*" >> "$TEST_DIR/calls"
      [ "$TEST_MODE" != modify-failure ] || return 1
      touch "$TEST_DIR/$4"
      ;;
    '--wait 60 connection up uuid '* )
      printf '%s\n' "$*" >> "$TEST_DIR/calls"
      [ "$TEST_MODE" != activation-failure ] || return 1
      ;;
    *) echo "Unexpected command: $*" >&2; return 2 ;;
  esac
}

test_reset() {
  rm -f -- "$TEST_DIR/wired" "$TEST_DIR/wifi" "$TEST_DIR/calls"
  TEST_MODE=$1
}

test_reset success
if network_status > "$TEST_DIR/status"; then
  echo 'Manual profiles must require recovery.' >&2; exit 1
fi
network_recover > "$TEST_DIR/output"
[ -f "$TEST_DIR/wired" ] && [ -f "$TEST_DIR/wifi" ]
[ "$(wc -l < "$TEST_DIR/calls")" -eq 3 ]
grep -q '^--wait 60 connection up uuid wired$' "$TEST_DIR/calls"
grep -q 'ipv4.method auto ipv4.addresses  ipv4.gateway  ipv4.dns  ipv4.dns-search  ipv4.routes  ipv4.ignore-auto-dns no ipv4.ignore-auto-routes no ipv4.never-default no$' "$TEST_DIR/calls"
network_recover > "$TEST_DIR/output"
[ "$(wc -l < "$TEST_DIR/calls")" -eq 3 ]
test_reset empty
network_recover > "$TEST_DIR/output"
[ ! -e "$TEST_DIR/calls" ]
test_reset query-failure
if network_recover > "$TEST_DIR/output" 2>&1; then exit 1; fi
[ ! -e "$TEST_DIR/calls" ]
test_reset modify-failure
if network_recover > "$TEST_DIR/output" 2>&1; then exit 1; fi
if grep -q '^--wait' "$TEST_DIR/calls"; then exit 1; fi
test_reset activation-failure
if network_recover > "$TEST_DIR/output" 2>&1; then exit 1; fi
[ -f "$TEST_DIR/wired" ] && [ -f "$TEST_DIR/wifi" ]
echo 'Network recovery tests passed.'
