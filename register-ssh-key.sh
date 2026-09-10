#!/bin/sh
set -eu

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HELPER_DIR/lib.sh"

usage() {
  echo "usage: $0 [-n] [-J jumps] [-H hostname] [-u user] [-i pubkey] [-F fingerprint] [-h] alias" >&2
  echo "  -J  カンマ区切りジャンプ先 (例: bastion,internal)。空=直結" >&2
  echo "  -H  configのHostName (省略時はaliasと同じ)" >&2
  echo "  -u  configのUser (省略時は既存値/SSH_HELPER_DEFAULT_USER/OSユーザー名)" >&2
  echo "  -i  公開鍵ファイル (繰り返し可。省略時はed25519+rsaの存在する方)" >&2
  echo "  -F  信頼するホスト鍵指紋 (例: SHA256:abc...。複数可/カンマ区切り)" >&2
  echo "      指定時はkeyscanで検証しknown_hostsに登録してから接続 (accept-new不使用)" >&2
  echo "      SSH_HELPER_TRUST_FINGERPRINTS でも指定可" >&2
  echo "  -n  dry-run (変更せず表示だけ)" >&2
  echo "  -h  このヘルプ" >&2
  exit "${1:-2}"
}

check_help "$@"

get_default_user() {
  DEFAULT_USER="${SSH_HELPER_DEFAULT_USER:-${USER:-}}"
  if [ -z "$DEFAULT_USER" ]; then DEFAULT_USER="$(id -un)"; fi
  if [ -z "${SSH_HELPER_DEFAULT_USER:-}" ]; then
    echo "警告: DEFAULT_USERが設定されていません。環境変数 SSH_HELPER_DEFAULT_USER の設定をおすすめします。(既定値 $DEFAULT_USER を使用します)" >&2
  fi
}

JUMPS=""
REALHOST=""
USER_ARG=""
PUBKEYS=""
DRYRUN=0
TRUST_FPS=""

while getopts "nJ:H:u:i:F:" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    J) JUMPS="$OPTARG" ;;
    H) REALHOST="$OPTARG" ;;
    u) USER_ARG="$OPTARG" ;;
    i) PUBKEYS="$PUBKEYS $OPTARG" ;;
    F) TRUST_FPS="$TRUST_FPS,$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
ALIAS="$1"

command -v ssh >/dev/null 2>&1 || die "ssh が見つかりません"

valid_token "$ALIAS" || die "不正なalias: $ALIAS"
[ -z "$REALHOST" ] || valid_token "$REALHOST" || die "不正なhostname: $REALHOST"
[ -z "$USER_ARG" ] || valid_token "$USER_ARG" || die "不正なuser: $USER_ARG"

NJUMPS=""
if [ -n "$JUMPS" ]; then
  oldifs="$IFS"; IFS=","
  # shellcheck disable=SC2086
  set -- $JUMPS
  IFS="$oldifs"
  for j in "$@"; do
    j="$(echo "$j" | tr -d ' \t')"
    [ -z "$j" ] && continue
    valid_token "$j" || die "不正なjump host: $j"
    if [ -z "$NJUMPS" ]; then NJUMPS="$j"; else NJUMPS="$NJUMPS,$j"; fi
  done
  [ -n "$NJUMPS" ] || die "-J の書式が不正です。例: -J bastion,internal"
  JUMPS="$NJUMPS"
fi

NEED_FP=0
WANT=""
if [ -n "$TRUST_FPS" ] || [ -n "${SSH_HELPER_TRUST_FINGERPRINTS:-}" ]; then
  NEED_FP=1
  WANT="$(echo "$TRUST_FPS,${SSH_HELPER_TRUST_FINGERPRINTS:-}" | tr ',' '\n' | tr -d ' \t\r' | grep -v '^$' | sort -u)"
  [ -n "$WANT" ] || die "-F の書式が不正です。例: -F SHA256:abc..."
  echo "$WANT" | grep -qvE '^SHA256:[A-Za-z0-9+/=]+$' && die "-F は SHA256:... 形式で指定してください"
fi

if [ -z "$PUBKEYS" ]; then
  # shellcheck disable=SC2086
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$f" ] && PUBKEYS="$PUBKEYS $f"
  done
  [ -n "$PUBKEYS" ] || die "公開鍵が見つかりません (-i で指定してください)"
fi

SSHDIR="$HOME/.ssh"
CFG="$SSHDIR/config"
[ -f "$CFG" ] || die "$CFG が見つかりません"

find_block() {
  awk -v alias="$ALIAS" '
    /^[ \t]*Host[ \t]/ {
      n = split($0, a, /[ \t]+/)
      if (!found) {
        for (i = 2; i <= n; i++) if (a[i] == alias) { found = NR; }
      } else if (!end) { end = NR; }
    }
    END {
      if (found) { if (!end) end = "EOF"; print found, end; }
    }' "$1"
}

split_range() {
  BLOCK_START=""
  BLOCK_END=""
  if [ -n "$1" ]; then
    BLOCK_START="${1%% *}"
    BLOCK_END="${1##* }"
  fi
}

MANAGEDDIR="$SSHDIR/config.d"
MANAGED="$MANAGEDDIR/managed"

RANGE_MAIN="$(find_block "$CFG" || true)"
split_range "$RANGE_MAIN"
MAIN_START="$BLOCK_START"; MAIN_END="$BLOCK_END"
RANGE_MANAGED=""
if [ -f "$MANAGED" ]; then RANGE_MANAGED="$(find_block "$MANAGED" || true)"; fi
split_range "$RANGE_MANAGED"
MANAGED_START="$BLOCK_START"; MANAGED_END="$BLOCK_END"

if { [ -n "$MAIN_START" ] || [ -n "$MANAGED_START" ]; } && [ -z "$JUMPS" ] && [ -z "$REALHOST" ] && [ -z "$USER_ARG" ]; then
  DEST="$ALIAS"
  NEED_CONFIG=0
else
  NEED_CONFIG=1
  ORIG_HOSTLINE="Host $ALIAS"
  ORIG_HOSTNAME=""
  ORIG_JUMP=""
  if [ -n "$MANAGED_START" ] || [ -n "$MAIN_START" ]; then
    if [ -n "$MANAGED_START" ]; then
      SRC="$MANAGED"; S="$MANAGED_START"; E="$MANAGED_END"
    else
      SRC="$CFG"; S="$MAIN_START"; E="$MAIN_END"
    fi
    if [ "$E" = "EOF" ]; then RANGE_SED="${S},\$p"; else RANGE_SED="${S},$((E - 1))p"; fi
    ORIG_HOSTLINE="$(sed -n "${S}p" "$SRC")"
    ORIG_HOSTNAME="$(sed -n "$RANGE_SED" "$SRC" | grep -E '^[ \t]*HostName[ \t]+' | head -n 1 | awk '{print $2}')"
    ORIG_JUMP="$(sed -n "$RANGE_SED" "$SRC" | grep -E '^[ \t]*ProxyJump[ \t]+' | head -n 1 | awk '{print $2}')"
  fi
  if [ -z "$REALHOST" ]; then REALHOST="$ORIG_HOSTNAME"; fi
  if [ -z "$REALHOST" ]; then REALHOST="$ALIAS"; fi
  if [ -z "$JUMPS" ] && [ -n "$ORIG_JUMP" ]; then JUMPS="$ORIG_JUMP"; fi
  if [ -z "$USER_ARG" ]; then
    if [ -n "$MANAGED_START" ] || [ -n "$MAIN_START" ]; then
      if [ -n "$MANAGED_START" ]; then
        SRC="$MANAGED"; S="$MANAGED_START"; E="$MANAGED_END"
      else
        SRC="$CFG"; S="$MAIN_START"; E="$MAIN_END"
      fi
      if [ "$E" = "EOF" ]; then
        USER_ARG="$(sed -n "${S},\$p" "$SRC" | grep -E '^[ \t]*User[ \t]+' | head -n 1 | awk '{print $2}')"
      else
        USER_ARG="$(sed -n "${S},$((E - 1))p" "$SRC" | grep -E '^[ \t]*User[ \t]+' | head -n 1 | awk '{print $2}')"
      fi
      [ -n "$USER_ARG" ] || { get_default_user; USER_ARG="$DEFAULT_USER"; }
    elif [ -n "$JUMPS" ]; then
      get_default_user
      USER_ARG="$DEFAULT_USER"
    else
      die "新規ホストには -u を指定してください (例: -u deploy)"
    fi
  fi

  BLOCKFILE="$(mktemp)"
  {
    echo "$ORIG_HOSTLINE"
    echo "  HostName $REALHOST"
    echo "  User $USER_ARG"
    echo "  IdentityFile ~/.ssh/id_ed25519"
    echo "  IdentityFile ~/.ssh/id_rsa"
    echo "  ForwardAgent yes"
    [ -n "$JUMPS" ] && echo "  ProxyJump $JUMPS"
  } > "$BLOCKFILE"

  if [ "$DRYRUN" -eq 1 ]; then
    log "--- config に書き込む内容 ---"
    cat "$BLOCKFILE"
    rm -f "$BLOCKFILE"
  else
    STAMP="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$MANAGEDDIR"
    [ -f "$MANAGED" ] || : > "$MANAGED"
    if ! grep -qE '^[ \t]*Include[ \t]+config\.d/managed[ \t]*$' "$CFG"; then
      cp "$CFG" "$CFG.bak-$STAMP"
      log "[0/3] config先頭に Include config.d/managed を追加します (backup: config.bak-$STAMP)"
      { echo "Include config.d/managed"; cat "$CFG"; } > "$CFG.new"
      mv "$CFG.new" "$CFG"
      RANGE_MAIN="$(find_block "$CFG" || true)"
      split_range "$RANGE_MAIN"
      MAIN_START="$BLOCK_START"; MAIN_END="$BLOCK_END"
    fi
    TARGET="$MANAGED"
    if [ -z "$MANAGED_START" ] && [ -n "$MAIN_START" ]; then TARGET="$CFG"; fi
    cp "$TARGET" "$TARGET.bak-$STAMP"
    log "[0/3] $(basename "$TARGET") を更新します (backup: $(basename "$TARGET").bak-$STAMP)"
    if { [ "$TARGET" = "$MANAGED" ] && [ -n "$MANAGED_START" ]; } || { [ "$TARGET" = "$CFG" ] && [ -n "$MAIN_START" ]; }; then
      awk -v alias="$ALIAS" -v blockfile="$BLOCKFILE" '
        function names_alias(line,  n,a,i) {
          n = split(line, a, /[ \t]+/)
          for (i = 2; i <= n; i++) if (a[i] == alias) return 1
          return 0
        }
        /^[ \t]*Host[ \t]/ {
          if (in_block) {
            while ((getline l < blockfile) > 0) print l
            emitted = 1; in_block = 0
          }
          if (!done && names_alias($0)) { in_block = 1; done = 1; next }
          print; next
        }
        { if (!in_block) print }
        END {
          if (in_block && !emitted) {
            while ((getline l < blockfile) > 0) print l
          } else if (!done) {
            print ""; while ((getline l < blockfile) > 0) print l
          }
        }' "$TARGET" > "$TARGET.new"
      mv "$TARGET.new" "$TARGET"
    else
      { echo ""; cat "$BLOCKFILE"; } >> "$TARGET"
    fi
    rm -f "$BLOCKFILE"
    ssh -G "$ALIAS" >/dev/null 2>&1 || die "configの書式エラー。backupから戻してください"
  fi
  DEST="$ALIAS"
fi

APPENDS=""
for f in $PUBKEYS; do
  [ -f "$f" ] || die "公開鍵が見つかりません: $f"
  line="$(cat "$f")"
  nl='
'
  case "$line" in
    *"$nl"*) die "複数行の公開鍵ファイル: $f" ;;
    *"'"*) die "引用符を含む公開鍵ファイル: $f" ;;
  esac
  echo "$line" | grep -qE '^ssh-(ed25519|rsa|ecdsa|dss) [A-Za-z0-9+/=]+( .*)?$' \
    || die "形式が不正な公開鍵: $f"
  if [ -z "$APPENDS" ]; then
    APPENDS="echo '$line' >> ~/.ssh/authorized_keys"
  else
    APPENDS="$APPENDS && echo '$line' >> ~/.ssh/authorized_keys"
  fi
done

REMOTE="mkdir -p ~/.ssh && cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-\$(date +%Y%m%d-%H%M%S) 2>/dev/null; $APPENDS"
REMOTE="$REMOTE && tr -d '\r' < ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp"
REMOTE="$REMOTE && sort -u ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys.tmp2"
REMOTE="$REMOTE && { if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp2 > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp2 ~/.ssh/authorized_keys; fi; }"
REMOTE="$REMOTE && rm -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys.tmp2"
REMOTE="$REMOTE && { chmod 755 ~ || true; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
REMOTE="$REMOTE && { if [ -L ~/.ssh/authorized_keys ]; then echo '(symlink preserved)'; fi; }"
REMOTE="$REMOTE && echo '--- fingerprints on server ---' && ssh-keygen -l -f ~/.ssh/authorized_keys"
REMOTE="$REMOTE && echo '--- perms ---' && ls -ld ~ ~/.ssh ~/.ssh/authorized_keys"

if [ "$DRYRUN" -eq 1 ]; then
  log "--- 実行するリモートコマンド ---"
  echo "ssh $DEST \"$REMOTE\""
  [ "$NEED_FP" -eq 1 ] && log "(指紋検証モード: keyscan照合後にknown_hostsへ登録)"
  exit 0
fi

CHECKING="-o StrictHostKeyChecking=accept-new"
if [ "$NEED_FP" -eq 1 ]; then
  command -v ssh-keyscan >/dev/null 2>&1 || die "ssh-keyscan が見つかりません"
  log "ホスト鍵をkeyscanで取得中..."
  EFFJUMP="$(ssh -G "$ALIAS" 2>/dev/null | tr -d '\r' | awk '/^proxyjump /{print $2}')"
  if [ -z "$REALHOST" ]; then
    REALHOST="$(ssh -G "$ALIAS" 2>/dev/null | tr -d '\r' | awk '/^hostname /{print $2}')"
  fi
  if [ -z "$EFFJUMP" ]; then
    SCAN="$(ssh-keyscan -T 10 "$REALHOST" 2>/dev/null | tr -d '\r' || true)"
  else
    LAST="${EFFJUMP##*,}"
    case "$EFFJUMP" in
      *,*) REST="${EFFJUMP%,*}"
        SCAN="$(ssh -J "$REST" "$LAST" "ssh-keyscan -T 10 $REALHOST" 2>/dev/null | tr -d '\r' || true)" ;;
      *) SCAN="$(ssh "$LAST" "ssh-keyscan -T 10 $REALHOST" 2>/dev/null | tr -d '\r' || true)" ;;
    esac
  fi
  SCANF="$(mktemp)"
  echo "$SCAN" | grep -v '^#' > "$SCANF"
  GOT="$(ssh-keygen -l -f "$SCANF" 2>/dev/null | awk '{print $2}')"
  rm -f "$SCANF"
  [ -n "$GOT" ] || die "ホスト鍵を取得できませんでした (keyscan失敗。要ネットワーク)"
  MATCH=""
  for fp in $WANT; do
    if echo "$GOT" | grep -qxF "$fp"; then MATCH="$fp"; break; fi
  done
  if [ -z "$MATCH" ]; then
    die "指紋不一致のため中止します。実際: $(echo $GOT | tr '\n' ' ')"
  fi
  log "指紋OK ($MATCH)。known_hostsに登録します"
  KH="$HOME/.ssh/known_hosts"
  [ -f "$KH" ] || : > "$KH"
  echo "$SCAN" | grep -v '^#' | while IFS= read -r kl; do
    [ -n "$kl" ] || continue
    set -- $kl
    nm="$1"; shift
    grep -qxF "$kl" "$KH" 2>/dev/null || echo "$kl" >> "$KH"
    if [ "$nm" != "$ALIAS" ]; then
      cand="$ALIAS $*"
      grep -qxF "$cand" "$KH" 2>/dev/null || echo "$cand" >> "$KH"
    fi
  done
  CHECKING=""
fi

log "[1/2] $DEST に登録中 ..."
if [ -z "$CHECKING" ]; then
  ssh "$DEST" "$REMOTE"
else
  ssh "$CHECKING" "$DEST" "$REMOTE"
fi

log "[2/2] BatchModeで検証中..."
if ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEST" "echo REGISTER_OK"; then
  log "成功: $DEST はパスワードなしで接続できます"
else
  die "まだパスワードなしでは通りません。sshd設定を確認してください"
fi
