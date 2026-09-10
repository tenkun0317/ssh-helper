param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Targets = @(),
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Continue"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Audit-SshKeys.ps1 [alias...] [-h]"
  return
}
$sshDir = Get-SshDir

$local = @()
foreach ($spec in @(@("id_ed25519.pub", "ed25519"), @("id_rsa.pub", "rsa"))) {
  $f = Join-Path $sshDir $spec[0]
  if (Test-Path -LiteralPath $f) {
    $fp = (((Invoke-Capture "ssh-keygen" @("-l", "-f", $f)).Stdout -split '\s+'))[1]
    if ($fp) { $local += [pscustomobject]@{ Fp = $fp; Label = $spec[1] } }
  }
}
if ($local.Count -eq 0) { Write-Error "ローカル公開鍵がありません" }

if ($Targets.Count -eq 0) {
  $files = @((Join-Path $sshDir "config"))
  $managed = Join-Path $sshDir (Join-Path "config.d" "managed")
  if (Test-Path -LiteralPath $managed) { $files += $managed }
  $Targets = @(Get-SshAliases $files)
}

foreach ($h in $Targets) {
  Write-Output "== $h =="
  $cap = Invoke-Capture "ssh" @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $h, "ssh-keygen -l -f ~/.ssh/authorized_keys")
  if ($cap.ExitCode -ne 0) { Write-Output "  UNREACHABLE"; continue }
  $out = @($cap.Stdout -split "`r?`n" | Where-Object { $_ -match '\S' })
  $seen = @()
  foreach ($line in $out) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = ($line -split '\s+')
    $fp = $parts[1]
    $rest = ($parts[2..($parts.Count - 1)] -join ' ')
    $seen += $fp
    $hit = @($local | Where-Object { $_.Fp -eq $fp }) | Select-Object -First 1
    if ($hit) { Write-Output "  PRESENT $($hit.Label) $fp $rest" }
    else { Write-Output "  UNKNOWN $fp $rest" }
  }
  foreach ($lk in $local) {
    if ($seen -notcontains $lk.Fp) { Write-Output "  MISSING $($lk.Label) $($lk.Fp)" }
  }
}
