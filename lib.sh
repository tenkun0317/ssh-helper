#!/bin/sh
die() { echo "error: $1" >&2; exit 1; }
log() { echo "$1"; }

check_help() {
  for a in "$@"; do
    if [ "$a" = "-h" ] || [ "$a" = "--help" ]; then
      usage 0
    fi
  done
}

valid_token() {
  case "$1" in
    "" | *[!A-Za-z0-9._-]* ) return 1 ;;
    *) return 0 ;;
  esac
}

ssh_aliases() {
  awk '/^[ \t]*Host[ \t]/ { for (i = 2; i <= NF; i++) if ($i !~ /\*/) { print $i; break } }' "$@" | awk '!seen[$0]++'
}
