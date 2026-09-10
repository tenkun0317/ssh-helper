#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 {list|restore <バックアップ名>}" >&2
  echo "  -h  このヘルプ ($0 -h の形式。サブコマンド位置では help も可)" >&2
  exit "${1:-2}"
}

check_help "$@"

[ $# -ge 1 ] || usage
CMD="$1"; shift

SSHDIR="$HOME/.ssh"

list_backups() {
  for d in "$SSHDIR" "$SSHDIR/config.d"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.bak-*; do
      [ -f "$f" ] || continue
      echo "$f"
    done
  done | sort
}

if [ "$CMD" = "list" ]; then
  FOUND=0
  for f in $(list_backups); do
    base="$(basename "$f")"
    target="${base%%.bak-*}"
    dir="$(dirname "$f")"
    info="$(ls -l "$f" | awk '{print $5"B "$6" "$7" "$8}')"
    echo "$base  -> $dir/$target  ($info)"
    FOUND=1
  done
  [ "$FOUND" -eq 1 ] || echo "バックアップはありません"
  exit 0
fi

[ "$CMD" = "restore" ] || usage
[ $# -eq 1 ] || usage
NAME="$1"

SRC=""
for f in $(list_backups); do
  if [ "$(basename "$f")" = "$NAME" ] || [ "$f" = "$NAME" ]; then SRC="$f"; break; fi
done
[ -n "$SRC" ] || die "バックアップが見つかりません: $NAME (list で確認)"

BASE="$(basename "$SRC")"
TARGET_DIR="$(dirname "$SRC")"
TARGET_NAME="${BASE%%.bak-*}"
TARGET="$TARGET_DIR/$TARGET_NAME"

STAMP="$(date +%Y%m%d-%H%M%S)"
if [ -f "$TARGET" ]; then
  cp "$TARGET" "$TARGET.bak-$STAMP"
  echo "現状を退避しました: $TARGET.bak-$STAMP"
fi
cp "$SRC" "$TARGET"
echo "復元しました: $BASE -> $TARGET"

ALIASES="$(awk '/^[ \t]*Host[ \t]/ { for (i = 2; i <= NF; i++) if ($i !~ /\*/) { print $2; break } }' "$TARGET" | awk '!seen[$0]++')"
BAD=0
COUNT=0
for a in $ALIASES; do
  COUNT=$((COUNT + 1))
  if ! ssh -G "$a" >/dev/null 2>&1; then echo "書式エラー: $a"; BAD=1; fi
done
if [ "$BAD" -ne 0 ] && [ -f "$TARGET.bak-$STAMP" ]; then
  cp "$TARGET.bak-$STAMP" "$TARGET"
  die "検証失敗のため自動で戻しました"
fi
echo "検証OK: $COUNT エイリアス"
