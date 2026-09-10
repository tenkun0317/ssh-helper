# ssh-helper

[![test](https://github.com/tenkun0317/ssh-helper/actions/workflows/test.yml/badge.svg)](https://github.com/tenkun0317/ssh-helper/actions/workflows/test.yml)

SSH公開鍵の登録・確認・剥奪をワンコマンド化するスクリプト集。
登録は `ssh` 1接続だけで完結するため、パスワードは最大1回だけ聞かれる。

## ファイル

| ファイル | 対象 | 用途 | 依存 |
|---|---|---|---|
| `ssh-helper` | Linux / macOS / Git Bash | ラッパー（下記9機能に振り分け） | `sh` のみ |
| `ssh-helper.ps1` | Windows | ラッパー（同上） | なし |
| `ssh-helper.cmd` | Windows cmd.exe | ラッパー（同上。実体はps1） | なし |
| `install.sh` | Linux / macOS / Git Bash | `~/.local/bin` にリンク＋PATH設定 | `sh` のみ |
| `Register-SshKey.ps1` | Windows (PowerShell 5.1+) | 鍵登録 | `ssh` のみ |
| `register-ssh-key.sh` | Linux / macOS / Git Bash (POSIX sh) | 鍵登録 | `sh`, `ssh` のみ |
| `Test-Ssh.ps1` | Windows | 全ホスト疎通確認（並列） | `ssh` のみ |
| `ssh-check.sh` | Linux / macOS / Git Bash | 全ホスト疎通確認（並列） | `sh`, `ssh` のみ |
| `Revoke-SshKey.ps1` | Windows | 鍵剥奪 | `ssh` のみ |
| `revoke-ssh-key.sh` | Linux / macOS / Git Bash | 鍵剥奪 | `sh`, `ssh` のみ |
| `Backup-SshConfig.ps1` | Windows | configバックアップ list/restore | なし |
| `ssh-backup.sh` | Linux / macOS / Git Bash | configバックアップ list/restore | `sh` のみ |
| `KNOWLEDGE.md` | — | 開発知見集（罠と対処の記録） | — |
| `Show-SshConfig.ps1` | Windows | `ssh -G` 解決結果の表示 | `ssh` のみ |
| `ssh-show.sh` | Linux / macOS / Git Bash | `ssh -G` 解決結果の表示 | `sh`, `ssh` のみ |
| `Audit-SshKeys.ps1` | Windows | authorized_keys監査 | `ssh` のみ |
| `ssh-audit.sh` | Linux / macOS / Git Bash | authorized_keys監査 | `sh`, `ssh` のみ |
| `New-SshKey.ps1` | Windows | ローカル鍵生成 | `ssh-keygen` 等 |
| `ssh-keygen-helper.sh` | Linux / macOS / Git Bash | ローカル鍵生成 | `sh`, `ssh-keygen` |
| `Sync-SshAgent.ps1` | Windows | agent起動確認・鍵登録 | `ssh-add` 等 |
| `ssh-agent-helper.sh` | Linux / macOS / Git Bash | agent起動確認・鍵登録 | `sh`, `ssh-add` 等 |

両版のオプションは対応している。PowerShell版は短縮形も使える
（`-J` `-H` `-u` `-i` `-n` `-F` はsh版と同じ文字）。

## 導入

```sh
git clone <リポジトリURL> ~/ssh-helper
cd ~/ssh-helper
./install.sh   # ~/.local/bin にリンク。PATHがなければrcへの追記も案内する
ssh-helper check
```

Windowsでは `~/ssh-helper` をPATHに足すか、`.\ssh-helper.ps1 check` のように直接呼ぶ。

## ラッパー

```sh
ssh-helper register -J bastion,internal -H 192.0.2.60 new1
ssh-helper check
ssh-helper revoke oldhost
ssh-helper backup list
ssh-helper show myserver
ssh-helper audit
ssh-helper keygen
ssh-helper agent status
ssh-helper test
```

## できること（登録スクリプト）

- 公開鍵の追記＋重複除去（`sort -u`）
- 変更前にリモート側 `authorized_keys.bak-日時` を自動保存
- サーバー側の権限修正（`chmod 755 ~` / `700 ~/.ssh` / `600 authorized_keys`）
- 改行コード混入の除去（Windowsパイプ由来の `BOM` / `CR` 対策）
- `~/.ssh/config` へのホスト追記・更新（更新前は `config.bak-日時` に自動バックアップ）
  - スクリプト管理分は `~/.ssh/config.d/managed` に分離（手書きconfigと衝突しない）。
    先頭の `Include config.d/managed` がなければ自動追加する
  - 既存ブロック更新時は未指定項目（`Host` 行・`HostName`・`ProxyJump`）を現状維持する
- 初回ホスト鍵確認を出さない（`StrictHostKeyChecking=accept-new` で `known_hosts` に自動追加）
- 登録後に `BatchMode` でパスワードなし接続を検証
- 変なサーバー向けの堅牢化: `authorized_keys` がsymlinkでもリンクを保って書く、
  `chmod 755 ~` 失敗時は `|| true` で続行、リモート文字列にダブルクォート不使用

## 使い方

Windows:

```powershell
cd ~/ssh-helper
.\Register-SshKey.ps1 myserver
.\Register-SshKey.ps1 -HostAlias web1 -RealHost 192.0.2.60 -JumpHosts "bastion,internal"
.\Register-SshKey.ps1 -n -J bastion,internal -H 192.0.2.60 web1   # dry-run（変更せず表示だけ）
.\Test-Ssh.ps1
.\Revoke-SshKey.ps1 -HostAlias oldhost -PubKeyFiles @("$env:USERPROFILE\.ssh\id_ed25519.pub")
.\Backup-SshConfig.ps1 list
.\Backup-SshConfig.ps1 restore config.bak-20260910-001337
```

Linux / macOS:

```sh
cd ~/ssh-helper
./register-ssh-key.sh myserver
./register-ssh-key.sh -J bastion,internal -H 192.0.2.60 -u deploy web1
./register-ssh-key.sh -n -J bastion,internal -H 192.0.2.60 web1   # dry-run（変更せず表示だけ）
./ssh-check.sh
./revoke-ssh-key.sh -i ~/.ssh/id_ed25519.pub oldhost
```

## オプション

| 意味 | PowerShell | sh |
|---|---|---|
| ジャンプ先（カンマ区切り、2段も可） | `-JumpHosts "bastion,internal"` / `-J` | `-J bastion,internal` |
| 実際のホスト名・IP（省略時はaliasと同じ） | `-RealHost 192.0.2.60`（短縮形なし、後述） | `-H 192.0.2.60` |
| ユーザー（省略時は既存値、なければ既定ユーザー） | `-User deploy` / `-u` | `-u deploy` |
| 公開鍵ファイル（繰り返し可） | 既定 `id_ed25519.pub` + `id_rsa.pub` / `-i` | `-i ~/.ssh/id_ed25519.pub` |
| 信頼するホスト鍵指紋（accept-new代替） | `-TrustFingerprints SHA256:...` / `-F` | `-F SHA256:...`（`SSH_HELPER_TRUST_FINGERPRINTS` でも可） |
| 変更せず表示だけ | `-DryRun` / `-n` | `-n` |

`config` ブロックが既にあり、ジャンプ・ホスト名・ユーザーの指定がなければ、
`config` は変更せず鍵登録だけ行う。

全コマンドは `-h` / `--help` で使い方を表示する（終了コード0）。

> 注意: PowerShell版の短縮形は `-J` `-u` `-i` `-F` `-n` `-h`。
> `-H` はない（`H`/`h` は大文字小文字を区別しないため `-h` と衝突する）。
> `-RealHost` はフル名で指定すること。

## 既定ユーザー

新規ホストで `-User` / `-u` を省略した場合のユーザー名は、環境変数
`SSH_HELPER_DEFAULT_USER` で変更できる。未設定時は警告
（`DEFAULT_USERが設定されていません。`）を出してOSユーザー名を使う。

```powershell
$env:SSH_HELPER_DEFAULT_USER = "myuser"
```

```sh
export SSH_HELPER_DEFAULT_USER=myuser
```

## 環境変数一覧

| 変数 | 用途 | 既定 |
|---|---|---|
| `SSH_HELPER_DEFAULT_USER` | 新規ホストの既定ユーザー | OSユーザー名（警告付き） |
| `SSH_HELPER_TRUST_FINGERPRINTS` | 信頼するホスト鍵指紋（カンマ区切り） | 未設定（`accept-new` 動作） |
| `SSH_HELPER_NO_AGENT` | `1` で鍵生成時のagent登録をスキップ | 未設定 |
| `SSH_HELPER_NO_RC` | `1` でinstall.shのrc書換えをスキップ | 未設定 |
| `PREFIX` | install.shの導入先 | `~/.local/bin` |

## ホスト鍵の指紋検証（accept-newの代替）

既定では初回ホスト鍵を無条件で信頼する（TOFU）。事前に管理者から指紋を
もらえる場合は `-F` / `-TrustFingerprints` で検証できる。keyscanで取得した
ホスト鍵の指紋が一致したものだけ `known_hosts` に登録し、厳格なまま接続する。
不一致なら中止する。

```sh
./register-ssh-key.sh -J bastion,internal -H 192.0.2.60 -F SHA256:abc... web1
```

## その他のコマンド

- `check`：全ホストを並列に疎通確認。失敗時は理由付き
  （`DNS解決失敗` / `接続タイムアウト` / `鍵認証失敗(要登録)` 等）
- `show [alias]`：`ssh -G` の解決結果を表示（`-F` で別config指定可）
- `audit [alias...]`：各ホストの `authorized_keys` とローカル鍵を突き合わせ
  （`PRESENT` / `UNKNOWN` / `MISSING` / `UNREACHABLE`）
- `keygen [-f]`：ローカル鍵がなければ `ed25519` を生成（権限修正・agent登録まで）
- `agent [status]`：agent起動確認・不足鍵の登録・一覧
- `backup list|restore`：configバックアップの管理（restoreは検証＋自動ロールバック付き）

## テスト

```sh
python tests/run_tests.py        # 全件（一時HOMEに隔離、実害なし）
ssh-helper test                  # ラッパー経由も可
```

標準ライブラリのみ。一時HOMEに隔離し、到達不能な `.invalid` ホストで
config書込パスまで検証する（実config・実ネットワーク不使用）。
CI（GitHub Actions）では ubuntu / macos / windows の3 OSで実行する。
powershell不在環境ではps系テストをSKIPする。

## 開発者向け：共通モジュール

重複排除のため共通処理は以下に集約している。新規スクリプトもここを使うこと。

- `SshHelper.psm1`（PowerShell版、全ps1から `Import-Module`）：
  `Invoke-Capture`（stderr誤爆しないコマンド捕捉）、`Find-Block`（Host行パース）、
  `Get-SshAliases`（エイリアス列挙）、`Find-ConfigValue`、
  `Write-Utf8NoBom`、`Lock-FileToOwner`、`Get-DefaultUser`、`Test-SshConfigValid`
- `lib.sh`（sh版、`. "$HELPER_DIR/lib.sh"` で読込）：
  `die`、`log`、`valid_token`、`ssh_aliases`

注意：
- ps1はUTF-8 BOM必須（BOMなし日本語はen-US環境で構文エラー。テストで強制）
- ps1のリモート文字列にダブルクォート不可（Windowsのargv変換で消える）
- native stderrの `2>$null` は `$ErrorActionPreference="Stop"` 下で異常終了化
  することがあるため、捕捉は `Invoke-Capture`（`Start-Process` 分離）に統一する

## よくある流れ

```sh
ssh-helper check          # まず疎通確認。FAIL host (reason: 鍵認証失敗(要登録)) が出たら
ssh-helper show host      # config解決を確認し
ssh-helper register host  # パスワード1回で登録
ssh-helper audit host     # 登録内容を監査
```

## トラブルシューティング

| 症状 | 原因・対処 |
|---|---|
| 登録直後も `Permission denied (publickey,password)` | `~` が他者書き込み可だと `StrictModes` で拒否される。本スクリプトは `chmod 755 ~` を実行する |
| 鍵を足したのに fingerprints に出ない | `authorized_keys` の行頭 `BOM` や行末 `CR` で無効化されている。本スクリプトは `echo` 埋め込み＋`sed` 除去で回避する |
| `UNPROTECTED PRIVATE KEY FILE` / 鍵が無視される | 秘密鍵のACLに `Administrators` 等が付いている。所有者のみにすること：`icacls key /remove:g BUILTIN\Administrators "NT AUTHORITY\SYSTEM"` |
| 再起動後にパスワードを聞かれる | `ssh-agent` が停止している。Windows: `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`＋`ssh-add`。`AddKeysToAgent yes` も有効にすること |

## 戻し方

- ローカル: `~/.ssh/config.bak-日時`（または `config.d/managed.bak-日時`）を戻す
- リモート: `~/.ssh/authorized_keys.bak-日時` を `authorized_keys` に戻す

## 配布

```sh
git clone https://github.com/tenkun0317/ssh-helper ~/ssh-helper
```

`.gitignore` で `*.bak-*` を除外済み。個人の `config` は含めず、
このディレクトリのスクリプト＋READMEだけを共有すること。

## 注意

- Windows版OpenSSHは `ControlMaster` による接続使い回しに未対応のため、
  パスワードの再利用ではなく「鍵登録で聞かれないようにする」方式を取っている
- `accept-new` は初回ホスト鍵を無条件で信頼する（TOFU）。
  指紋が分かる場合は `-F` / `-TrustFingerprints` で検証モードを使うこと
