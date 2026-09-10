param(
  [Parameter(Position = 0)]
  [string]$Mode = "",
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Continue"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Sync-SshAgent.ps1 [status] [-h]"
  return
}
$sshDir = Get-SshDir

function Test-Agent() {
  return ((Invoke-Capture "ssh-add" @("-l")).ExitCode -eq 0)
}

if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
  $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
  if ($svc -and $svc.StartType -eq "Disabled") {
    if ($Mode -eq "status") { Write-Output "agent service: Disabled"; exit 1 }
    Set-Service -Name ssh-agent -StartupType Automatic
    Write-Output "agent service: Disabled -> Automatic"
  }
  $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    if ($Mode -eq "status") { Write-Output "agent service: Stopped"; exit 1 }
    Start-Service ssh-agent
    Write-Output "agent service: started"
  }
}

if (Test-Agent) {
  Write-Output "agent: running"
} else {
  if ($Mode -eq "status") { Write-Output "agent: not running"; exit 1 }
  if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
    Write-Error "agentが応答しません。サービスを確認してください"
  } else {
    Write-Output "起動します。以下をシェルの起動ファイルに足すと永続化できます:"
    Write-Output '  eval $(ssh-agent -s) > /dev/null'
    Invoke-Expression (& ssh-agent -s | Out-String)
    Write-Output "agent: started"
  }
}

if ($Mode -eq "status") {
  Write-Output ((Invoke-Capture "ssh-add" @("-l")).Stdout)
  return
}

foreach ($name in @("id_ed25519", "id_rsa")) {
  $k = Join-Path $sshDir $name
  if (!(Test-Path -LiteralPath $k)) { continue }
  $fp = (((Invoke-Capture "ssh-keygen" @("-l", "-f", "$k.pub")).Stdout -split '\s+'))[1]
  $loaded = ((Invoke-Capture "ssh-add" @("-l")).Stdout | Select-String -Pattern ([regex]::Escape($fp)) -Quiet)
  if ($loaded) { Write-Output "loaded: $k" }
  else {
    $add = Invoke-Capture "ssh-add" @($k)
    if ($add.ExitCode -eq 0) { Write-Output "added: $k" }
    else { Write-Output "skip (passphrase付きか失敗): $k" }
  }
}
Write-Output "--- loaded keys ---"
Write-Output ((Invoke-Capture "ssh-add" @("-l")).Stdout)
