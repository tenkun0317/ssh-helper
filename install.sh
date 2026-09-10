#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh" 2>/dev/null || true

usage() {
  echo "usage: $0" >&2
  echo "  PREFIX=~/bin $0 / SSH_HELPER_NO_RC=1 $0 も可。-h でこのヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

SELF="$0"
if command -v readlink >/dev/null 2>&1; then
  while [ -L "$SELF" ]; do
    LINK="$(readlink "$SELF")"
    case "$LINK" in
      /* | [A-Za-z]:[\\/]*) SELF="$LINK" ;;
      *) SELF="$(dirname "$SELF")/$LINK" ;;
    esac
  done
fi
SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
BIN_DIR="${PREFIX:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
for f in ssh-helper register-ssh-key.sh ssh-check.sh revoke-ssh-key.sh ssh-backup.sh; do
  chmod +x "$SRC_DIR/$f"
done
printf '#!/bin/sh\nexec "%s/ssh-helper" "$@"\n' "$SRC_DIR" > "$BIN_DIR/ssh-helper"
chmod +x "$BIN_DIR/ssh-helper"
echo "installed: $BIN_DIR/ssh-helper (calls $SRC_DIR/ssh-helper)"

case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "PATH ok: $BIN_DIR は既に通っています"
    ;;
  *)
    LINE="export PATH=\"$BIN_DIR:\$PATH\""
    if [ -n "${SSH_HELPER_NO_RC:-}" ]; then
      echo "PATHが通っていません。以下を手動で追加してください:"
      echo "  $LINE"
      exit 0
    fi
    SHELL_NAME="$(basename "${SHELL:-sh}")"
    case "$SHELL_NAME" in
      zsh) RC="$HOME/.zshrc" ;;
      *) RC="$HOME/.bashrc" ;;
    esac
    touch "$RC"
    if grep -qF "$BIN_DIR" "$RC" 2>/dev/null; then
      echo "$RC に対応済みの記述があります。シェルを再起動してください"
    else
      echo "" >> "$RC"
      echo "# ssh-helper (install.sh)" >> "$RC"
      echo "$LINE" >> "$RC"
      echo "$RC に追加しました。反映にはシェルの再起動か以下が必要です:"
      echo "  source $RC"
    fi
    ;;
esac
