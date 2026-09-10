param(
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Continue"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Test-Ssh.ps1 [-h]"
  return
}
$sshDir = Get-SshDir
$files = @((Join-Path $sshDir "config"))
$managed = Join-Path $sshDir (Join-Path "config.d" "managed")
if (Test-Path -LiteralPath $managed) { $files += $managed }

$hosts = @(Get-SshAliases $files | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' })
if ($hosts.Count -eq 0) { Write-Output "ホストがありません"; exit 2 }

function Get-Reason($text) {
  if ($text -match "Could not resolve hostname") { return "DNS解決失敗" }
  if ($text -match "Connection timed out|Operation timed out") { return "接続タイムアウト" }
  if ($text -match "Connection refused") { return "接続拒否" }
  if ($text -match "Permission denied") { return "鍵認証失敗(要登録)" }
  if ($text -match "Host key verification failed") { return "ホスト鍵未確認" }
  if ($text -match "Connection closed|closed by remote") { return "接続切断" }
  return "その他"
}

$jobs = @()
foreach ($h in $hosts) {
  $jobs += Start-Job -Name $h -ScriptBlock {
    param($h)
    $err = ssh -o BatchMode=yes -o ConnectTimeout=10 $h "echo OK" 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Output "OK   $h"
    } else {
      $t = ($err | Out-String)
      $r = "その他"
      if ($t -match "Could not resolve hostname") { $r = "DNS解決失敗" }
      elseif ($t -match "Connection timed out|Operation timed out") { $r = "接続タイムアウト" }
      elseif ($t -match "Connection refused") { $r = "接続拒否" }
      elseif ($t -match "Permission denied") { $r = "鍵認証失敗(要登録)" }
      elseif ($t -match "Host key verification failed") { $r = "ホスト鍵未確認" }
      elseif ($t -match "Connection closed|closed by remote") { $r = "接続切断" }
      Write-Output "FAIL $h (reason: $r)"
    }
  } -ArgumentList $h
}

Wait-Job -Job $jobs -Timeout 120 | Out-Null
$results = @()
foreach ($j in $jobs) {
  if ($j.State -ne "Completed") {
    Stop-Job -Job $j | Out-Null
    $results += ("FAIL {0} (reason: タイムアウト)" -f $j.Name)
  } else {
    try {
      $r = Receive-Job -Job $j -ErrorAction Stop
      if ($r) { $results += $r }
      else { $results += ("FAIL {0} (reason: 結果なし)" -f $j.Name) }
    } catch {
      $results += ("FAIL {0} (reason: 結果なし)" -f $j.Name)
    }
  }
  Remove-Job -Job $j -Force | Out-Null
}

$ok = 0; $ng = 0
foreach ($line in ($results | Sort-Object)) {
  Write-Output $line
  if ($line -match "^OK") { $ok++ } else { $ng++ }
}
Write-Output "--- $ok OK / $ng FAIL ---"
if ($ng -gt 0) { exit 1 }
