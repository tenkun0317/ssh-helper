#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [status]" >&2
  echo "  statusで表示のみ。-h でこのヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

SSHDIR="$HOME/.ssh"
STATUS_ONLY=0
[ "${1:-}" = "status" ] && STATUS_ONLY=1

running() {
  [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1
}

if running; then
  echo "agent: running ($SSH_AUTH_SOCK)"
else
  echo "agent: not running"
  if [ "$STATUS_ONLY" -eq 1 ]; then exit 1; fi
  echo "起動します。以下をシェルの起動ファイルに足すと永続化できます:"
  echo "  eval \$(ssh-agent -s) >/dev/null"
  eval "$(ssh-agent -s)" >/dev/null
  echo "agent: started ($SSH_AUTH_SOCK)"
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
  ssh-add -l
  exit 0
fi

for k in "$SSHDIR/id_ed25519" "$SSHDIR/id_rsa"; do
  [ -f "$k" ] || continue
  fp="$(ssh-keygen -l -f "$k.pub" 2>/dev/null | awk '{print $2}')"
  if [ -n "$fp" ] && ssh-add -l 2>/dev/null | grep -q "$fp"; then
    echo "loaded: $k"
  else
    if ssh-add "$k" 2>/dev/null; then
      echo "added: $k"
    else
      echo "skip (passphrase付きか失敗): $k"
    fi
  fi
done
echo "--- loaded keys ---"
ssh-add -l
