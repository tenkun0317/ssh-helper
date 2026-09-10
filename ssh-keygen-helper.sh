#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [-f]" >&2
  echo "  -f  強制再作成。-h でこのヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

FORCE=0
while getopts "f" opt; do
  case "$opt" in
    f) FORCE=1 ;;
    *) echo "usage: $0 [-f]" >&2; exit 2 ;;
  esac
done

SSHDIR="$HOME/.ssh"
KEY="$SSHDIR/id_ed25519"
PUB="$KEY.pub"

if [ -f "$KEY" ] && [ "$FORCE" -eq 0 ]; then
  echo "exists: $KEY (作り直す場合は -f)"
  ssh-keygen -l -f "$PUB" 2>/dev/null || true
  exit 0
fi

command -v ssh-keygen >/dev/null 2>&1 || { echo "error: ssh-keygen が見つかりません" >&2; exit 2; }
mkdir -p "$SSHDIR"
chmod 700 "$SSHDIR"
if [ -f "$KEY" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  mv "$KEY" "$KEY.bak-$STAMP"
  [ -f "$PUB" ] && mv "$PUB" "$PUB.bak-$STAMP"
  echo "backup: $KEY.bak-$STAMP"
fi
COMMENT="${USER:-user}@$(hostname 2>/dev/null || echo localhost)"
ssh-keygen -t ed25519 -N "" -C "$COMMENT" -f "$KEY"
chmod 600 "$KEY"
chmod 644 "$PUB"
echo "created: $KEY"
ssh-keygen -l -f "$PUB"
