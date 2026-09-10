param(
  [Parameter(Position = 0)]
  [string]$HostAlias = "",
  [Alias("u")]
  [string]$User = "",
  [Alias("i")]
  [string[]]$PubKeyFiles = @(),
  [Alias("n")]
  [switch]$DryRun,
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Revoke-SshKey.ps1 [-n] [-u user] [-i pubkey] [-h] alias"
  return
}
if ([string]::IsNullOrEmpty($HostAlias)) {
  Write-Output "usage: .\Revoke-SshKey.ps1 [-n] [-u user] [-i pubkey] [-h] alias"
  Write-Error "alias を指定してください"
}
$sshDir = Get-SshDir
if ($PubKeyFiles.Count -eq 0) {
  $PubKeyFiles = @((Join-Path $sshDir "id_ed25519.pub"), (Join-Path $sshDir "id_rsa.pub"))
}

$bodies = @()
foreach ($f in $PubKeyFiles) {
  if (-not (Test-Path -LiteralPath $f)) { Write-Error "公開鍵が見つかりません: $f" }
  $body = ((Get-Content -LiteralPath $f -TotalCount 1) -split '\s+')[1]
  if ([string]::IsNullOrEmpty($body) -or ($body -match "'")) { Write-Error "形式が不正な公開鍵: $f" }
  $bodies += $body
}

$dest = $HostAlias
if ($User -ne "") { $dest = "$User@$HostAlias" }

$filters = ($bodies | ForEach-Object { " -e '$_'" }) -join ""
$remoteCmd = "cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-`$(date +%Y%m%d-%H%M%S)" +
  " && grep -v -F$filters ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp" +
  " && { if [ -L ~/.ssh/authorized_keys ]; then cat ~/.ssh/authorized_keys.tmp > ~/.ssh/authorized_keys; else mv -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; fi; }" +
  " && rm -f ~/.ssh/authorized_keys.tmp" +
  " && chmod 600 ~/.ssh/authorized_keys" +
  " && echo '--- remaining keys ---' && ssh-keygen -l -f ~/.ssh/authorized_keys"

Write-Output "[1/2] $dest から剥奪中..."
if ($DryRun) {
  Write-Output "--- 実行するリモートコマンド ---"
  Write-Output "ssh $dest ""$remoteCmd"""
  return
}
ssh $dest $remoteCmd
if ($LASTEXITCODE -ne 0) { Write-Error "剥奪に失敗しました" }

Write-Output "[2/2] BatchModeで検証中..."
$ver = Invoke-Capture "ssh" @("-o", "BatchMode=yes", "-o", "ConnectTimeout=15", $dest, "echo STILL_OK")
if ($ver.ExitCode -eq 0) {
  Write-Output "注意: まだ鍵認証が通ります（別の鍵が残っています）"
} else {
  Write-Output "剥奪確認: $dest はパスワードなしでは通らなくなりました"
}
