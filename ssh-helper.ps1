$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot

function Show-Usage() {
  Write-Output "usage: .\ssh-helper.ps1 {register|check|revoke|backup|show|audit|keygen|agent|test} [args...]"
}

if ($args.Count -eq 0) {
  Show-Usage
  exit 0
}
$Command = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }

if ($Command -in @("-h", "--help", "-?", "help")) {
  Show-Usage
  exit 0
}

switch ($Command) {
  "register" { & (Join-Path $dir "Register-SshKey.ps1") @rest; exit $LASTEXITCODE }
  "check"    { & (Join-Path $dir "Test-Ssh.ps1") @rest; exit $LASTEXITCODE }
  "revoke"   { & (Join-Path $dir "Revoke-SshKey.ps1") @rest; exit $LASTEXITCODE }
  "backup"   { & (Join-Path $dir "Backup-SshConfig.ps1") @rest; exit $LASTEXITCODE }
  "show"     { & (Join-Path $dir "Show-SshConfig.ps1") @rest; exit $LASTEXITCODE }
  "audit"    { & (Join-Path $dir "Audit-SshKeys.ps1") @rest; exit $LASTEXITCODE }
  "keygen"   { & (Join-Path $dir "New-SshKey.ps1") @rest; exit $LASTEXITCODE }
  "agent"    { & (Join-Path $dir "Sync-SshAgent.ps1") @rest; exit $LASTEXITCODE }
  "test" {
    $py = (Get-Command python3 -ErrorAction SilentlyContinue)
    if (!$py) { $py = (Get-Command python -ErrorAction SilentlyContinue) }
    if (!$py) { Write-Error "python3 が必要です" }
    & $py.Source (Join-Path $dir (Join-Path "tests" "run_tests.py")); exit $LASTEXITCODE
  }
  default {
    Show-Usage
    exit 2
  }
}
