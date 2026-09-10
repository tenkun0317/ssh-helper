function Get-HomeBase() {
  $hb = $env:USERPROFILE
  if ([string]::IsNullOrEmpty($hb)) { $hb = $HOME }
  return $hb
}

function Get-SshDir() {
  return (Join-Path (Get-HomeBase) ".ssh")
}

function Invoke-Capture([string]$Exe, [string[]]$ExeArgs) {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList $ExeArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -ErrorAction Stop
    $txt = Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue
    return @{ ExitCode = $p.ExitCode; Stdout = [string]$txt }
  } catch {
    return @{ ExitCode = 1; Stdout = "" }
  } finally {
    Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
  }
}

function Write-Utf8NoBom($path, $lines) {
  $enc = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllLines($path, [string[]]$lines, $enc)
}

function Lock-FileToOwner($path) {
  if ([System.Environment]::OSVersion.Platform -ne "Win32NT") { return }
  try {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $path /inheritance:r /grant:r "*$($sid):(F)" 2>$null | Out-Null
    & icacls $path /remove:g "BUILTIN\Administrators" "NT AUTHORITY\SYSTEM" 2>$null | Out-Null
    $null = Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction Stop
  } catch {
    & icacls $path /reset 2>$null | Out-Null
  }
}

function Get-DefaultUser() {
  if (![string]::IsNullOrEmpty($env:SSH_HELPER_DEFAULT_USER)) {
    return $env:SSH_HELPER_DEFAULT_USER
  }
  $who = $env:USERNAME
  if ([string]::IsNullOrEmpty($who)) { $who = $env:USER }
  if ([string]::IsNullOrEmpty($who)) { $who = "user" }
  Write-Warning "DEFAULT_USERが設定されていません。環境変数 SSH_HELPER_DEFAULT_USER の設定をおすすめします。(既定値 $who を使用します)"
  return $who
}

function Test-SshConfigValid($alias) {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  try {
    $p = Start-Process -FilePath "ssh" -ArgumentList @("-G", $alias) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -ErrorAction Stop
    $txt = Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue
    return ($p.ExitCode -eq 0 -and ![string]::IsNullOrWhiteSpace([string]$txt))
  } catch {
    return $false
  } finally {
    Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
  }
}

function Find-Block($lines, $alias) {
  $s = -1; $e = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*Host\s+(.+?)\s*$') {
      if ($s -ge 0) { $e = $i; break }
      if (($Matches[1] -split '\s+') -contains $alias) { $s = $i }
    }
  }
  return @{ Start = $s; End = $e; Exists = ($s -ge 0) }
}

function Get-SshAliases($files) {
  $out = @()
  foreach ($f in $files) {
    if (!(Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
      if ($line -match '^\s*Host\s+(.+?)\s*$') {
        $first = ($Matches[1] -split '\s+')[0]
        if ($first -notlike '*`*' -and $out -notcontains $first) { $out += $first }
      }
    }
  }
  return $out
}

function Find-ConfigValue($lines, $key) {
  $m = $lines | Select-String -Pattern ("^" + $key + " (.+)$") | Select-Object -First 1
  if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
  return ""
}
