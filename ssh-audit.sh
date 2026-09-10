#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [alias...]" >&2
  echo "  authorized_keysを監査する。-h でこのヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

CFG="$HOME/.ssh/config"
MANAGED="$HOME/.ssh/config.d/managed"
[ -f "$CFG" ] || die "$CFG が見つかりません"
FILES="$CFG"
[ -f "$MANAGED" ] && FILES="$FILES $MANAGED"

LOCAL=""
for spec in "id_ed25519.pub:ed25519" "id_rsa.pub:rsa"; do
  f="$HOME/.ssh/${spec%%:*}"
  label="${spec##*:}"
  if [ -f "$f" ]; then
    fp="$(ssh-keygen -l -f "$f" 2>/dev/null | awk '{print $2}')"
    [ -n "$fp" ] && LOCAL="$LOCAL$fp|$label
"
  fi
done
[ -n "$LOCAL" ] || { echo "error: ローカル公開鍵がありません" >&2; exit 2; }

if [ $# -gt 0 ]; then
  HOSTS="$*"
else
  # shellcheck disable=SC2086
  HOSTS="$(ssh_aliases $FILES)"
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT INT TERM

for h in $HOSTS; do
  echo "== $h =="
  OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" "ssh-keygen -l -f ~/.ssh/authorized_keys" 2>/dev/null)" || {
    echo "  UNREACHABLE"
    continue
  }
  echo "$OUT" | awk '{print $2}' > "$TMPD/seen"
  echo "$OUT" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    fp="$(echo "$line" | awk '{print $2}')"
    rest="$(echo "$line" | cut -d' ' -f3-)"
    if echo "$LOCAL" | grep -q "^$fp|"; then
      label="$(echo "$LOCAL" | grep "^$fp|" | head -n 1 | cut -d'|' -f2)"
      echo "  PRESENT $label $fp $rest"
    else
      echo "  UNKNOWN $fp $rest"
    fi
  done
  echo "$LOCAL" | while IFS='|' read -r fp label; do
    [ -n "$fp" ] || continue
    if ! grep -qxF "$fp" "$TMPD/seen" 2>/dev/null; then
      echo "  MISSING $label $fp"
    fi
  done
done
