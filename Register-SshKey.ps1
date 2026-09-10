param(
  [Parameter(Position = 0)]
  [string]$HostAlias = "",
  [Alias("J")]
  [string]$JumpHosts = "",
  [string]$RealHost = "",
  [Alias("u")]
  [string]$User = "",
  [Alias("i")]
  [string[]]$PubKeyFiles = @(),
  [Alias("F")]
  [string[]]$TrustFingerprints = @(),
  [Alias("n")]
  [switch]$DryRun,
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Register-SshKey.ps1 [-J jumps] [-RealHost hostname] [-u user] [-i pubkey] [-F fingerprint] [-n] [-h] alias"
  return
}
if ([string]::IsNullOrEmpty($HostAlias)) {
  Write-Output "usage: .\Register-SshKey.ps1 [-J jumps] [-RealHost hostname] [-u user] [-i pubkey] [-F fingerprint] [-n] [-h] alias"
  Write-Error "alias を指定してください"
}
$sshDir = Get-SshDir
$cfgPath = Join-Path $sshDir "config"
if ($PubKeyFiles.Count -eq 0) {
  $PubKeyFiles = @((Join-Path $sshDir "id_ed25519.pub"), (Join-Path $sshDir "id_rsa.pub"))
}

foreach ($f in $PubKeyFiles) {
  if (-not (Test-Path -LiteralPath $f)) { Write-Error "公開鍵が見つかりません: $f" }
}

$managedDir = Join-Path $sshDir "config.d"
$managedPath = Join-Path $managedDir "managed"
$cfgLines = Get-Content -LiteralPath $cfgPath

$mainBlock = Find-Block $cfgLines $HostAlias
$managedLines = @()
if (Test-Path -LiteralPath $managedPath) { $managedLines = @(Get-Content -LiteralPath $managedPath) }
$managedBlock = Find-Block $managedLines $HostAlias
$blockExists = $mainBlock.Exists -or $managedBlock.Exists

$wantList = @($TrustFingerprints)
if (![string]::IsNullOrEmpty($env:SSH_HELPER_TRUST_FINGERPRINTS)) {
  $wantList += ($env:SSH_HELPER_TRUST_FINGERPRINTS -split ',')
}
$wantList = @($wantList | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Sort-Object -Unique)
foreach ($fp in $wantList) {
  if ($fp -notmatch '^SHA256:[A-Za-z0-9+/=]+$') { Write-Error "-TrustFingerprints は SHA256:... 形式で指定してください: $fp" }
}

if ($blockExists -and $JumpHosts -eq "" -and $RealHost -eq "" -and $User -eq "") {
  $dest = $HostAlias
} else {
  $origHostLine = "Host $HostAlias"
  $origHostName = ""
  $origJump = ""
  if ($blockExists) {
    $srcLines = $cfgLines; $srcBlock = $mainBlock
    if ($managedBlock.Exists) { $srcLines = $managedLines; $srcBlock = $managedBlock }
    $srcRange = $srcLines[$srcBlock.Start..($srcBlock.End - 1)]
    $origHostLine = $srcLines[$srcBlock.Start]
    $mh = $srcRange | Select-String -Pattern '^\s*HostName\s+(\S+)' | Select-Object -First 1
    if ($mh) { $origHostName = $mh.Matches[0].Groups[1].Value }
    $mj = $srcRange | Select-String -Pattern '^\s*ProxyJump\s+(\S+)' | Select-Object -First 1
    if ($mj) { $origJump = $mj.Matches[0].Groups[1].Value }
  }
  if ($RealHost -eq "") { $RealHost = $origHostName }
  if ($RealHost -eq "") { $RealHost = $HostAlias }
  if ($User -eq "") {
    if ($blockExists) {
      $srcLines = $cfgLines; $srcBlock = $mainBlock
      if ($managedBlock.Exists) { $srcLines = $managedLines; $srcBlock = $managedBlock }
      $m = $srcLines[$srcBlock.Start..($srcBlock.End - 1)] | Select-String -Pattern '^\s*User\s+(\S+)' | Select-Object -First 1
      $User = if ($m) { $m.Matches[0].Groups[1].Value } else { Get-DefaultUser }
    } elseif ($JumpHosts -ne "") {
      $User = Get-DefaultUser
    } else {
      Write-Error "新規ホストには -User を指定してください"
    }
  }
  if ($JumpHosts -ne "") {
    $JumpHosts = ($JumpHosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }) -join ','
    if ($JumpHosts -eq "") { Write-Error "-JumpHosts の書式が不正です。例: -JumpHosts 'bastion,internal'" }
  } elseif ($origJump -ne "") {
    $JumpHosts = $origJump
  }

  $newBlock = @(
    $origHostLine,
    "  HostName $RealHost",
    "  User $User",
    "  IdentityFile ~/.ssh/id_ed25519",
    "  IdentityFile ~/.ssh/id_rsa",
    "  ForwardAgent yes"
  )
  if ($JumpHosts -ne "") { $newBlock += "  ProxyJump $JumpHosts" }

  if ($DryRun) {
    Write-Output "--- config に書き込む内容 ---"
    $newBlock | ForEach-Object { Write-Output $_ }
    $dest = $HostAlias
  } else {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"

  New-Item -ItemType Directory -Path $managedDir -Force | Out-Null
  if (!(Test-Path -LiteralPath $managedPath)) { New-Item -ItemType File -Path $managedPath -Force | Out-Null }
  if ((Get-Content -LiteralPath $cfgPath -Raw) -notmatch '(?m)^\s*Include\s+config\.d/managed\s*$') {
    Copy-Item -LiteralPath $cfgPath -Destination "$cfgPath.bak-$stamp" -Force
    Write-Output "[0/3] config先頭に Include config.d/managed を追加します (backup: config.bak-$stamp)"
    Write-Utf8NoBom $cfgPath (@("Include config.d/managed") + @(Get-Content -LiteralPath $cfgPath))
    Lock-FileToOwner $cfgPath
    $cfgLines = Get-Content -LiteralPath $cfgPath
    $mainBlock = Find-Block $cfgLines $HostAlias
  }

  $targetPath = $managedPath
  $targetLines = @(Get-Content -LiteralPath $managedPath)
  $targetBlock = Find-Block $targetLines $HostAlias
  if (!$targetBlock.Exists -and $mainBlock.Exists) {
    $targetPath = $cfgPath
    $targetLines = $cfgLines
    $targetBlock = $mainBlock
  }
  Copy-Item -LiteralPath $targetPath -Destination "$targetPath.bak-$stamp" -Force
  Write-Output "[0/3] $targetPath を更新します (backup: $(Split-Path $targetPath -Leaf).bak-$stamp)"

  if ($targetBlock.Exists) {
    $before = @()
    if ($targetBlock.Start -gt 0) { $before = $targetLines[0..($targetBlock.Start - 1)] }
    $after = @()
    if ($targetBlock.End -lt $targetLines.Count) { $after = $targetLines[$targetBlock.End..($targetLines.Count - 1)] }
    $targetLines = @($before) + @($newBlock) + @($after)
  } else {
    $targetLines = @($targetLines) + @("") + @($newBlock)
  }
  Write-Utf8NoBom $targetPath $targetLines
  Lock-FileToOwner $targetPath
  if (!(Test-SshConfigValid $HostAlias)) { Write-Error "configの書式エラー。backupから戻してください" }
  $dest = $HostAlias
  }
}

$keyLines = @()
foreach ($f in $PubKeyFiles) {
  $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::ASCII).Trim()
  if ($t -eq "") { Write-Error "空の公開鍵ファイル: $f" }
  if ($t -match "'") { Write-Error "公開鍵に引用符が含まれています: $f" }
  $keyLines += $t
}
$appends = ($keyLines | ForEach-Object { "echo '$_' >> ~/.ssh/authorized_keys" }) -join " && "
$remoteCmd = "mkdir -p ~/.ssh && cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-`$(date +%Y%m%d-%H%M%S) 2>/dev/null; " + $appends +
  " && tr -d '\r' < ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp" +
  " && sort -u ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys.tmp2" +
  " && { if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp2 > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp2 ~/.ssh/authorized_keys; fi; }" +
  " && rm -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys.tmp2" +
  " && { chmod 755 ~ || true; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys" +
  " && { if [ -L ~/.ssh/authorized_keys ]; then echo '(symlink preserved)'; fi; }" +
  " && echo '--- fingerprints on server ---' && ssh-keygen -l -f ~/.ssh/authorized_keys" +
  " && echo '--- perms ---' && ls -ld ~ ~/.ssh ~/.ssh/authorized_keys"

Write-Output "[1/2] $dest に登録中 ..."
if ($DryRun) {
  Write-Output "--- 実行するリモートコマンド ---"
  Write-Output "ssh $dest ""$remoteCmd"""
  if ($TrustFingerprints.Count -gt 0 -or ![string]::IsNullOrEmpty($env:SSH_HELPER_TRUST_FINGERPRINTS)) {
    Write-Output "(指紋検証モード: keyscan照合後にknown_hostsへ登録)"
  }
  return
}

$checking = @("-o", "StrictHostKeyChecking=accept-new")
if ($wantList.Count -gt 0) {
  if (!(Get-Command ssh-keyscan -ErrorAction SilentlyContinue)) { Write-Error "ssh-keyscan が見つかりません" }
  Write-Output "ホスト鍵をkeyscanで取得中..."
  $effJump = ""
  $geff = (Invoke-Capture "ssh" @("-G", $HostAlias)).Stdout
  $geffLines = @($geff -split "`r?`n")
  if (![string]::IsNullOrWhiteSpace($geff)) {
    $gm = $geffLines | Select-String -Pattern '^proxyjump (.+)$' | Select-Object -First 1
    if ($gm) { $effJump = $gm.Matches[0].Groups[1].Value.Trim() }
    if ([string]::IsNullOrEmpty($RealHost)) {
      $gh = $geffLines | Select-String -Pattern '^hostname (.+)$' | Select-Object -First 1
      if ($gh) { $RealHost = $gh.Matches[0].Groups[1].Value.Trim() }
    }
  }
  if ($effJump -eq "") {
    $scan = (Invoke-Capture "ssh-keyscan" @("-T", "10", $RealHost)).Stdout
  } else {
    $hops = $effJump -split ','
    $last = $hops[-1]
    if ($hops.Count -gt 1) {
      $rest = ($hops[0..($hops.Count - 2)] -join ',')
      $scan = (Invoke-Capture "ssh" @("-J", $rest, $last, "ssh-keyscan -T 10 $RealHost")).Stdout
    } else {
      $scan = (Invoke-Capture "ssh" @($last, "ssh-keyscan -T 10 $RealHost")).Stdout
    }
  }
  $scanLines = @($scan -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' })
  if ($scanLines.Count -eq 0) { Write-Error "ホスト鍵を取得できませんでした (keyscan失敗。要ネットワーク)" }
  $scanFile = [System.IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $scanFile -Value $scanLines -Encoding Ascii
  try {
    $got = @((Invoke-Capture "ssh-keygen" @("-l", "-f", $scanFile)).Stdout -split "`r?`n" | ForEach-Object { ($_ -split '\s+')[1] } | Where-Object { $_ -ne "" })
  } finally {
    Remove-Item -LiteralPath $scanFile -Force -ErrorAction SilentlyContinue
  }
  $match = @($wantList | Where-Object { $got -contains $_ }) | Select-Object -First 1
  if ([string]::IsNullOrEmpty($match)) {
    Write-Error ("指紋不一致のため中止します。実際: " + ($got -join ' '))
  }
  Write-Output "指紋OK ($match)。known_hostsに登録します"
  $kh = Join-Path $sshDir "known_hosts"
  if (!(Test-Path -LiteralPath $kh)) { New-Item -ItemType File -Path $kh -Force | Out-Null }
  $existing = Get-Content -LiteralPath $kh
  foreach ($kl in $scanLines) {
    $parts = ($kl -split '\s+')
    $cands = @($kl)
    if ($parts[0] -ne $HostAlias) { $cands += ($HostAlias + ' ' + ($parts[1..($parts.Count - 1)] -join ' ')) }
    foreach ($c in $cands) {
      if ($existing -notcontains $c) {
        Add-Content -LiteralPath $kh -Value $c -Encoding Ascii
        $existing += $c
      }
    }
  }
  $checking = @()
}
ssh @checking $dest $remoteCmd
if ($LASTEXITCODE -ne 0) { Write-Error "サーバー側の登録に失敗しました" }

Write-Output "[2/2] BatchModeで検証中..."
ssh -o BatchMode=yes -o ConnectTimeout=15 $dest "echo REGISTER_OK"
if ($LASTEXITCODE -eq 0) {
  Write-Output "成功: $dest はパスワードなしで接続できます"
} else {
  Write-Warning "まだパスワードなしでは通りません。sshd設定を確認してください"
}
