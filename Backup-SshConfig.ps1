param(
  [Parameter(Position = 0)]
  [ValidateSet("list", "restore")]
  [string]$Command = "",
  [Parameter(Position = 1)]
  [string]$Name = "",
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "SshHelper.psm1") -Force
if ($Help) {
  Write-Output "usage: .\Backup-SshConfig.ps1 {list|restore <バックアップ名>} [-h]"
  return
}
if ([string]::IsNullOrEmpty($Command)) {
  Write-Output "usage: .\Backup-SshConfig.ps1 {list|restore <バックアップ名>} [-h]"
  exit 2
}
$sshDir = Get-SshDir

function Get-Backups() {
  $out = @()
  foreach ($d in @($sshDir, (Join-Path $sshDir "config.d"))) {
    if (!(Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -Filter "*.bak-*" -File -ErrorAction SilentlyContinue)) {
      $target = $f.Name -replace '\.bak-[^.]*$', ''
      $out += [pscustomobject]@{
        Name = $f.Name
        Path = $f.FullName
        RestoresTo = (Join-Path $d $target)
        Length = $f.Length
        Modified = $f.LastWriteTime
      }
    }
  }
  return ($out | Sort-Object Modified)
}

if ($Command -eq "list") {
  $backs = Get-Backups
  if ($backs.Count -eq 0) { Write-Output "バックアップはありません" }
  else {
    $backs | ForEach-Object { Write-Output ("{0}  -> {1}  ({2}B {3})" -f $_.Name, $_.RestoresTo, $_.Length, $_.Modified) }
  }
  return
}

if ([string]::IsNullOrEmpty($Name)) { Write-Error "使い方: .\Backup-SshConfig.ps1 restore <バックアップ名>" }
$cand = Get-Backups | Where-Object { $_.Name -eq $Name -or $_.Path -eq $Name } | Select-Object -First 1
if (!$cand) { Write-Error "バックアップが見つかりません: $Name (list で確認)" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (Test-Path -LiteralPath $cand.RestoresTo) {
  Copy-Item -LiteralPath $cand.RestoresTo -Destination ($cand.RestoresTo + ".bak-$stamp") -Force
  Write-Output ("現状を退避しました: {0}.bak-{1}" -f $cand.RestoresTo, $stamp)
}
Copy-Item -LiteralPath $cand.Path -Destination $cand.RestoresTo -Force
Write-Output ("復元しました: {0} -> {1}" -f $cand.Name, $cand.RestoresTo)
Write-Output "RESTORE-STEP:lock-start"
if ([System.Environment]::OSVersion.Platform -eq "Win32NT") {
  try {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Write-Output "RESTORE-STEP:lock-sid=$sid"
    & icacls $cand.RestoresTo /inheritance:r /grant:r "*$($sid):(F)" 2>$null | Out-Null
    & icacls $cand.RestoresTo /remove:g "BUILTIN\Administrators" "NT AUTHORITY\SYSTEM" 2>$null | Out-Null
    $null = Get-Content -LiteralPath $cand.RestoresTo -TotalCount 1 -ErrorAction Stop
    Write-Output "RESTORE-STEP:lock-ok"
  } catch {
    Write-Output ("RESTORE-STEP:lock-fallback: {0}" -f $_)
    & icacls $cand.RestoresTo /reset 2>$null | Out-Null
  }
}

$aliases = @()
foreach ($f in @($cand.RestoresTo)) {
  foreach ($line in (Get-Content -LiteralPath $f)) {
    if ($line -match '^\s*Host\s+(.+?)\s*$') {
      $first = ($Matches[1] -split '\s+')[0]
      if ($first -notlike '*`*' -and $aliases -notcontains $first) { $aliases += $first }
    }
  }
}
$bad = $false
foreach ($a in $aliases) {
  Write-Output "RESTORE-STEP:validate=$a"
  if (!(Test-SshConfigValid $a)) {
    Write-Output "書式エラー: $a"
    $bad = $true
  }
}
if ($bad -and (Test-Path -LiteralPath ($cand.RestoresTo + ".bak-$stamp"))) {
  Copy-Item -LiteralPath ($cand.RestoresTo + ".bak-$stamp") -Destination $cand.RestoresTo -Force
  Write-Error "検証失敗のため自動で戻しました"
}
Write-Output "検証OK: $($aliases.Count) エイリアス"
