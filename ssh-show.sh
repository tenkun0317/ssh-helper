#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [-F config] [alias]" >&2
  echo "  -h  このヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

CFGF=""
while getopts "F:" opt; do
  case "$opt" in
    F) CFGF="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

CFG="$HOME/.ssh/config"
MANAGED="$HOME/.ssh/config.d/managed"
[ -f "$CFG" ] || die "$CFG が見つかりません"
FILES="$CFG"
[ -f "$MANAGED" ] && FILES="$FILES $MANAGED"

if [ -n "$CFGF" ]; then
  [ -f "$CFGF" ] || die "$CFGF が見つかりません"
  sshG() { ssh -G -F "$CFGF" "$1"; }
  ALIASES="$(ssh_aliases "$CFGF")"
else
  sshG() { ssh -G "$1"; }
  # shellcheck disable=SC2086
  ALIASES="$(ssh_aliases $FILES)"
fi

pick() {
  echo "$1" | awk -v k="$2" '$1 == k { print $2; exit }'
}

if [ $# -eq 0 ]; then
  printf "%-14s %-28s %s\n" "ALIAS" "USER@HOST" "PROXYJUMP"
  # shellcheck disable=SC2086
  for a in $ALIASES; do
    G="$(sshG "$a" 2>/dev/null)" || { echo "$a: config error"; continue; }
    printf "%-14s %-28s %s\n" "$a" "$(pick "$G" user)@$(pick "$G" hostname)" "$(pick "$G" proxyjump)"
  done
  exit 0
fi

[ $# -eq 1 ] || usage
A="$1"
G="$(sshG "$A" 2>/dev/null)" || { echo "error: $A の解決に失敗" >&2; exit 1; }
for k in hostname user port proxyjump identityfile forwardagent addkeystoagent serveraliveinterval pubkeyauthentication strictHostKeyChecking; do
  echo "$G" | awk -v k="$k" 'tolower($1) == k { printf "%-22s %s\n", $1, substr($0, index($0,$2)) }'
done
