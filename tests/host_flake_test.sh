#!/bin/sh
# In-memory tests for lib/host_flake.sh.
# No Nix evaluation, no host filesystem mutation, no network.
set -u

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$root/lib/host_flake.sh"

failures=0
checks=0

expect() {
  label=$1
  hostname=$2
  want_line=$3
  want_rc=$4
  checks=$((checks + 1))

  got_line=$(host_flake_resolve "$hostname") && got_rc=0 || got_rc=$?
  if [ "$got_line" != "$want_line" ] || [ "$got_rc" != "$want_rc" ]; then
    printf 'FAIL %s\n  hostname=%s\n  got  line=%s rc=%s\n  want line=%s rc=%s\n' \
      "$label" "$hostname" "$got_line" "$got_rc" "$want_line" "$want_rc" >&2
    failures=$((failures + 1))
  fi
}

# Aliases copied from the pre-extraction Makefile. Case-sensitive.
expect sam_nixos sam_nixos 'ok sam-main' 0
expect samnixos samnixos 'ok sam-main' 0
expect sam-main sam-main 'ok sam-main' 0
expect sam_main sam_main 'ok sam-main' 0
expect framework13 framework13 'ok framework13' 0
expect AI_Server AI_Server 'ok AIServer' 0
expect AIServer AIServer 'ok AIServer' 0
expect ai_server ai_server 'ok AIServer' 0
expect queennas queennas 'ok dad_nas' 0
expect dad_nas dad_nas 'ok dad_nas' 0
expect asus-rog-1070 asus-rog-1070 'ok asus_rog_1070' 0
expect asus_rog_1070 asus_rog_1070 'ok asus_rog_1070' 0

# Padding is not part of the hostname. Whitespace-only is empty, not unknown.
expect trim-spaces '  framework13  ' 'ok framework13' 0
expect trim-tab "$(printf '\tqueennas\t')" 'ok dad_nas' 0
expect trim-cr "$(printf 'sam_nixos\r')" 'ok sam-main' 0
expect empty '' 'deny empty' 1
expect spaces '   ' 'deny empty' 1
expect tab-only "$(printf '\t')" 'deny empty' 1

# Fail closed. These are real names in the fleet that are not switch targets.
expect lowercase-aiserver aiserver 'deny unknown' 1
expect mixed-sam sam_NixOS 'deny unknown' 1
expect spark spark-48e5 'deny unknown' 1
expect incus-template incus_cloud 'deny unknown' 1
expect path-like '../etc/hostname' 'deny unknown' 1
expect star '*' 'deny unknown' 1

# Caller environment is not an input.
checks=$((checks + 1))
got_line=$(HOSTNAME=queennas PWD=/etc host_flake_resolve framework13) && got_rc=0 || got_rc=$?
if [ "$got_line" != 'ok framework13' ] || [ "$got_rc" != 0 ]; then
  printf 'FAIL ignores env\n  got line=%s rc=%s\n' "$got_line" "$got_rc" >&2
  failures=$((failures + 1))
fi

# Exactly one line, so a caller cannot mistake a log line for success.
checks=$((checks + 1))
lines=$(host_flake_resolve sam_main | wc -l | tr -d ' ')
if [ "$lines" != 1 ]; then
  printf 'FAIL single line: got %s\n' "$lines" >&2
  failures=$((failures + 1))
fi

# Makefile edge: command-line HOSTNAME_INPUT skips /etc/hostname.
# current-host only prints the mapping; it does not rebuild.
if ! command -v make >/dev/null 2>&1; then
  checks=$((checks + 1))
  printf 'FAIL make is not available for the edge check\n' >&2
  failures=$((failures + 1))
else
  checks=$((checks + 1))
  out=$(make -C "$root" -s current-host HOSTNAME_INPUT=queennas 2>&1) && edge_rc=0 || edge_rc=$?
  case $edge_rc:$out in
    0:*'queennas → flake: .#dad_nas'*) ;;
    *)
      printf 'FAIL make ok edge rc=%s out=%s\n' "$edge_rc" "$out" >&2
      failures=$((failures + 1))
      ;;
  esac

  checks=$((checks + 1))
  out=$(make -C "$root" -s current-host HOSTNAME_INPUT='  AI_Server  ' 2>&1) && edge_rc=0 || edge_rc=$?
  case $edge_rc:$out in
    0:*'.#AIServer'*) ;;
    *)
      printf 'FAIL make trim edge rc=%s out=%s\n' "$edge_rc" "$out" >&2
      failures=$((failures + 1))
      ;;
  esac

  checks=$((checks + 1))
  out=$(make -C "$root" -s current-host HOSTNAME_INPUT=incus_cloud 2>&1) && edge_rc=0 || edge_rc=$?
  case $edge_rc:$out in
    0:*)
      printf 'FAIL make deny edge unexpectedly succeeded: %s\n' "$out" >&2
      failures=$((failures + 1))
      ;;
    *:*)
      case $out in
        *'deny unknown'*) ;;
        *)
          printf 'FAIL make deny edge rc=%s out=%s\n' "$edge_rc" "$out" >&2
          failures=$((failures + 1))
          ;;
      esac
      ;;
  esac
fi

if [ "$failures" -ne 0 ]; then
  printf '%s failed, %s checks\n' "$failures" "$checks" >&2
  exit 1
fi

printf '%s checks passed\n' "$checks"
exit 0
