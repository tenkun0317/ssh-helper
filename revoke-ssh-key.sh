#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [-n] [-u user] [-i pubkey] alias" >&2
  echo "  -h  このヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

USER_ARG=""
PUBKEYS=""
DRYRUN=0
while getopts "nu:i:" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    u) USER_ARG="$OPTARG" ;;
    i) PUBKEYS="$PUBKEYS $OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
ALIAS="$1"

if [ -z "$PUBKEYS" ]; then
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$f" ] && PUBKEYS="$PUBKEYS $f"
  done
  [ -n "$PUBKEYS" ] || die "公開鍵が見つかりません (-i で指定してください)"
fi

FILTERS=""
for f in $PUBKEYS; do
  [ -f "$f" ] || die "公開鍵が見つかりません: $f"
  body="$(awk '{print $2}' "$f")"
  case "$body" in
    "" | *"'"*) die "形式が不正な公開鍵: $f" ;;
  esac
  FILTERS="$FILTERS -e '$body'"
done

if [ -n "$USER_ARG" ]; then DEST="$USER_ARG@$ALIAS"; else DEST="$ALIAS"; fi

REMOTE="cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-\$(date +%Y%m%d-%H%M%S)"
REMOTE="$REMOTE && grep -v -F$FILTERS ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp"
REMOTE="$REMOTE && { if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; fi; }"
REMOTE="$REMOTE && rm -f ~/.ssh/authorized_keys.tmp"
REMOTE="$REMOTE && chmod 600 ~/.ssh/authorized_keys"
REMOTE="$REMOTE && echo '--- remaining keys ---' && ssh-keygen -l -f ~/.ssh/authorized_keys"

echo "[1/2] $DEST から剥奪中..."
if [ "$DRYRUN" -eq 1 ]; then
  echo "--- 実行するリモートコマンド ---"
  echo "ssh $DEST \"$REMOTE\""
  exit 0
fi
ssh "$DEST" "$REMOTE"

echo "[2/2] BatchModeで検証中..."
if ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEST" "echo STILL_OK" >/dev/null 2>&1; then
  echo "注意: まだ鍵認証が通ります（別の鍵が残っています）"
else
  echo "剥奪確認: $DEST はパスワードなしでは通らなくなりました"
fi
