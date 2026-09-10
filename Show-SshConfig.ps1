param(
  [Parameter(Position = 0)]
  [string]$HostAlias = "",
  [Alias("F")]
  [string]$ConfigFile = "",
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Show-SshConfig.ps1 [-F config] [alias] [-h]"
  return
}

$sshDir = Get-SshDir
$files = @((Join-Path $sshDir "config"))
$managed = Join-Path $sshDir (Join-Path "config.d" "managed")
if (Test-Path -LiteralPath $managed) { $files += $managed }
if (![string]::IsNullOrEmpty($ConfigFile)) {
  if (!(Test-Path -LiteralPath $ConfigFile)) { Write-Error "configが見つかりません: $ConfigFile" }
  $files = @($ConfigFile)
}
$gBase = @("-G")
if (![string]::IsNullOrEmpty($ConfigFile)) { $gBase = @("-G", "-F", $ConfigFile) }

function Get-Val($lines, $key) {
  return (Find-ConfigValue $lines $key)
}

if ([string]::IsNullOrEmpty($HostAlias)) {
  Write-Output ("{0,-14} {1,-28} {2}" -f "ALIAS", "USER@HOST", "PROXYJUMP")
  foreach ($a in (Get-SshAliases $files)) {
    $cap = Invoke-Capture "ssh" ($gBase + $a)
    if ($cap.ExitCode -ne 0) { Write-Output "${a}: config error"; continue }
    $g = @($cap.Stdout -split "`r?`n")
    Write-Output ("{0,-14} {1,-28} {2}" -f $a, ((Get-Val $g "user") + "@" + (Get-Val $g "hostname")), (Get-Val $g "proxyjump"))
  }
  return
}

$cap = Invoke-Capture "ssh" ($gBase + $HostAlias)
if ($cap.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($cap.Stdout)) { Write-Error "$HostAlias の解決に失敗" }
$g = @($cap.Stdout -split "`r?`n")
foreach ($k in @("hostname", "user", "port", "proxyjump", "identityfile", "forwardagent", "addkeystoagent", "serveraliveinterval", "pubkeyauthentication", "stricthostkeychecking")) {
  $vals = @($g | Select-String -Pattern ("^" + $k + " (.+)$") | ForEach-Object { $_.Matches[0].Groups[1].Value })
  foreach ($v in $vals) { Write-Output ("{0,-22} {1}" -f $k, $v) }
}
