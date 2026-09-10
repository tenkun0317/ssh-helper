#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0" >&2
  echo "  config内の全ホストを並列に疎通確認する。-h でこのヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

CFG="$HOME/.ssh/config"
MANAGED="$HOME/.ssh/config.d/managed"
[ -f "$CFG" ] || die "$CFG が見つかりません"
FILES="$CFG"
[ -f "$MANAGED" ] && FILES="$FILES $MANAGED"

# shellcheck disable=SC2086
HOSTS="$(ssh_aliases $FILES)"

classify() {
  case "$1" in
    *"Could not resolve hostname"*) echo "DNS解決失敗" ;;
    *"Connection timed out"*) echo "接続タイムアウト" ;;
    *"Connection refused"*) echo "接続拒否" ;;
    *"Permission denied"*) echo "鍵認証失敗(要登録)" ;;
    *"Host key verification failed"*) echo "ホスト鍵未確認" ;;
    *"Connection closed"*|*"closed by remote"*) echo "接続切断" ;;
    *"Operation timed out"*) echo "接続タイムアウト" ;;
    *) echo "その他" ;;
  esac
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT INT TERM

n=0
for h in $HOSTS; do
  case "$h" in
    *[!A-Za-z0-9._-]*) continue ;;
  esac
  n=$((n + 1))
  (
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" "echo OK" >/dev/null 2>"$TMPD/$h.err"; then
      status=0
      echo "OK   $h"
    else
      status=$?
      echo "FAIL $h (reason: $(classify "$(cat "$TMPD/$h.err")"))"
    fi > "$TMPD/$h.out"
    printf '%s' "$status" > "$TMPD/$h.rc"
  ) &
done

wait
[ "$n" -gt 0 ] || { echo "ホストがありません"; exit 2; }

OK=0; NG=0
for h in $HOSTS; do
  case "$h" in
    *[!A-Za-z0-9._-]*) continue ;;
  esac
  cat "$TMPD/$h.out"
  if [ "$(cat "$TMPD/$h.rc")" = "0" ]; then OK=$((OK + 1)); else NG=$((NG + 1)); fi
done
echo "--- $OK OK / $NG FAIL ---"
[ "$NG" -eq 0 ] || exit 1
