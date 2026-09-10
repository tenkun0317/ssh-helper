param(
  [Alias("f")]
  [switch]$Force,
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\New-SshKey.ps1 [-f] [-h]"
  return
}
$sshDir = Get-SshDir
$key = Join-Path $sshDir "id_ed25519"
$pub = "$key.pub"

if ((Test-Path -LiteralPath $key) -and !$Force) {
  Write-Output "exists: $key (作り直す場合は -Force)"
  Write-Output ((Invoke-Capture "ssh-keygen" @("-l", "-f", $pub)).Stdout)
  return
}

if (!(Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { Write-Error "ssh-keygen が見つかりません" }
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
if (Test-Path -LiteralPath $key) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  Move-Item -LiteralPath $key -Destination "$key.bak-$stamp" -Force
  if (Test-Path -LiteralPath $pub) { Move-Item -LiteralPath $pub -Destination "$pub.bak-$stamp" -Force }
  Write-Output "backup: $key.bak-$stamp"
}
$comment = ($env:USERNAME)
if ([string]::IsNullOrEmpty($comment)) { $comment = "user" }
if (![string]::IsNullOrEmpty($env:COMPUTERNAME)) { $comment += "@" + $env:COMPUTERNAME }
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "ssh-keygen"
$psi.Arguments = '-t ed25519 -N "" -C "' + $comment + '" -f "' + $key + '"'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit(120000) | Out-Null
if ($proc.ExitCode -ne 0) { Write-Error ("鍵生成に失敗しました: " + $proc.StandardError.ReadToEnd()) }
if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
  & icacls $key /inheritance:r 2>$null | Out-Null
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls $key /grant:r "*$($me):(F)" 2>$null | Out-Null
  & icacls $key /remove:g "BUILTIN\Administrators" "NT AUTHORITY\SYSTEM" 2>$null | Out-Null
} else {
  chmod 600 $key
}
Write-Output "created: $key"
Write-Output ((Invoke-Capture "ssh-keygen" @("-l", "-f", $pub)).Stdout)
if ([string]::IsNullOrEmpty($env:SSH_HELPER_NO_AGENT)) {
  $add = Invoke-Capture "ssh-add" @($key)
  if ($add.ExitCode -eq 0) { Write-Output "agentに登録しました" }
  else { Write-Output "注意: ssh-agentが動いていないため登録をスキップ (agentコマンドで起動可)" }
} else {
  Write-Output "agent登録をスキップしました (SSH_HELPER_NO_AGENT)"
}
