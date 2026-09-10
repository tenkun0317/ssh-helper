# KNOWLEDGE.md — ssh-helper 開発知見集

本プロジェクトで実際に踏んだ罠と対処の記録。再発防止のための必読事項。
最終更新: 2026-09-12

---

## 1. Windows × OpenSSH の権限

### 1.1 秘密鍵に他者の権限があると鍵が無視される
`BUILTIN\Administrators` 等のACEが付いた秘密鍵は、OpenSSHが
`UNPROTECTED PRIVATE KEY FILE` 扱いで無視し、パスワード要求にフォールバックする。
本件の発端そのもの。

- 対処: 所有者のみに絞る（`SshHelper.psm1` の `Lock-FileToOwner` 相当）
- 新規鍵生成時も同様に絞ること（`keygen` コマンド内で実施）

### 1.2 サーバー側ホームの権限 (StrictModes)
`~` が他者書き込み可（例: `drwxrwxrwx`）だと、鍵が正しくてもサーバーが
`Permission denied (publickey,password)` で拒否する。
`chmod 755 ~` が定番処置。ただしNFS等で失敗しうるため `|| true` で許容する。

### 1.3 config自体の権限も見られる
Windows版OpenSSHは `~/.ssh/config` や `Include` 先の権限も検証し、
他者から読めると無視する。スクリプトがconfigを書き換えたらACLも整えること。

### 1.4 Windows版sshはUSERPROFILE上書きを無視する
一時HOME隔離が `ssh.exe` 自体の動作には効かない（プロファイル解決にAPI使用）。
テストで `ssh` の振る舞いを検証したい場合は `ssh -F <config>` で明示する。

---

## 2. PowerShell の罠

### 2.1 `$x = native 2>$null` でもstderrが異常終了化する
`$ErrorActionPreference = "Stop"` 下では、捨てたはずのnative stderrが
`NativeCommandError` として異常終了化することがある（`ssh` のPTY警告、
`ssh-add` の成功メッセージ等で実証済み）。
**対策: 捕捉は `Invoke-Capture`（`Start-Process` 分離）に統一する。**
素の `2>$null` / `2>&1` は検証・デバッグ用途以外で使わない。

### 2.2 空文字引数の欠落
`ssh-keygen -N ""` が "Too many arguments" で死ぬ（空文字argvが欠落）。
`Start-Process -ArgumentList` も空要素を拒否する。
**対策: `.NET ProcessStartInfo` に素のargv文字列を渡す。**

### 2.3 変数直後のコロン
`"$me:(F)"` はスコープ構文と解釈されパースエラー。`"$($me):(F)"` と書く。
同じミスを繰り返したため、構文テストで検出できるようにした。

### 2.4 残余引数の素通し不可
`param` ブロックがあると未知の `-J` 等でバインドエラーになる。
ラッパー（`ssh-helper.ps1`）は `param` を持たせず `$args` 素通し方式にした。

### 2.5 ps1はUTF-8 BOM必須
BOMなし日本語ps1はen-US環境で構文エラーになる。日本語ロケールの手元では
再現しないためCIで初めて発覚した。テストでBOM有無を強制する。

### 2.6 batはCRLF必須
LFのみのbatは行が結合されて誤動作する。生成時は改行コードを明示する。
また `rem` 行の日本語も化けるためASCIIのみにする。

### 2.7 `Start-Job` + 変なHOME
`Receive-Job` が "Persistence Path" エラーになることがある。try/catchで防御し、
取得失敗時は `FAIL (reason: 結果なし)` に倒す（チェックツールは落ちない設計）。

---

## 3. リモート操作・データ破損防止

### 3.1 PowerShellパイプのBOM混入
`Get-Content ... | ssh` は `authorized_keys` の行頭にBOMを混入させ鍵を無効化する。
バイナリ正確性が必要な転送はパイプを避け、`echo` 埋め込み方式に統一した。

### 3.2 CRLF混入
`ssh -G` 出力の行末 `\r` がホスト名等に混入しkeyscanが空振りした。
**外部コマンドの出力は常にtrim/除去する**（sh: `tr -d '\r'`、ps1: `.Trim()`）。

### 3.3 symlinkを壊さない書き込み
`sed -i` や `sort -o` 同名、`mv` 直書きは `authorized_keys` のsymlinkを
通常ファイルに置き換えてしまう。別tmp経由で作り、
`[ -L ... ]` なら `cat >`、そうでなければ `mv -f` で戻す。

### 3.4 MSYSのargv変換でダブルクォートが消える
Git Bash経由でnative `ssh.exe` を呼ぶと、リモート文字列内の `""` が消滅し
awk等が構文エラーになる。**リモート文字列にダブルクォートは使わない。**

### 3.5 Windowsの `ssh-keyscan` が特定サーバーと鍵交換できない
`choose_kex` 失敗で空振りする組み合わせがある。`accept-new` を既定とし、
検証が必要な場合はジャンプホスト上（Linux）のkeyscanを使う設計にした。

### 3.6 `ssh -G` は未知ホストでもexit 0
検証が素通りになるため、stdout空チェックを併用する。

### 3.7 `Select-String` と `-Raw`
`Get-Content -Raw` の単一文字列に `^...$` は刺さらない。行分割してから渡す。

---

## 4. テスト・CI設計

- `.invalid` ホストでconfig書込パスまで踏む（実害なし・高速・確定的）。
- fixture鍵は実生成する（不正な鍵だと `ssh-keygen -l` 系が死ぬ）。
- 一時HOMEに完全隔離する。ただしWindowsでは `ssh.exe` 自体に効かない点に注意（1.4）。
- 判定はASCII部分で行う（en-US環境で日本語が化ける）。
- 子プロセス出力のdecodeは `errors="replace"`、表示はUTF-8再設定。
- powershell不在環境ではps系テストをSKIPする。
- ps1の構文・BOMチェックをCIに含める（ロケール差異の検出）。
- dry-runのみのテストは実行パスを網羅しない（`Revoke` の未定義関数を見逃した）。
  非dry-run系も `.invalid` でカバーする。
- CIの3 OS回しが最も稼いだ。権限・ロケール・パス解決の問題は手元で再現困難。

---

## 5. 運用設計原則（自作事故の反省から）

- 未指定項目は現状維持する（`Host` 行・`HostName`・`ProxyJump` の上書き禁止）。
  かつて自作スクリプトが `HostName` をaliasで上書きし接続不能にした。
- 書換えはUTF-8無BOMで（Ascii書込で日本語コメントを破壊した前科あり）。
- 書換え前は必ずbackupを取り、書換え後は `ssh -G` 検証、失敗時は自動ロールバック。
- 書く先は `config.d/managed` に分離し、手書きconfigと衝突させない。
- 読取専用ツール（check/show/audit）は副作用なしを保証する。
- 危険操作（revoke等）はdry-runを必ず用意する。

---

## 6. 変更履歴メモ

- 指紋検証モード追加時に `Raw` 文字列パース不具合で2往復した。以降、
  外部出力のパースは行分割を最初に行う。
- `install.sh` のsymlink方式はMSYSの解釈差異で破綻し、実パス埋め込みシムに変更した。
- 失敗時は日本語に加えて `RESTORE-STEP:` のようなASCIIマーカーを出すと
  CIログのgrep可能性が上がる。
