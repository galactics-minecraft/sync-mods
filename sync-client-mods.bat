@echo off
setlocal
set "SELF=%~f0"
set "TMP_PS=%TEMP%\sync-mods-%RANDOM%%RANDOM%.ps1"

powershell -NoProfile -Command "$s=[IO.File]::ReadAllText($env:SELF); $m='#PS-'+'START'; $i=$s.IndexOf($m); [IO.File]::WriteAllText($env:TMP_PS,$s.Substring($i+$m.Length))"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TMP_PS%" "%~dp0." %*
set "RC=%ERRORLEVEL%"
del "%TMP_PS%" >nul 2>&1

echo %cmdcmdline% | find /i "%~nx0" >nul && pause
exit /b %RC%

#PS-START
$UA = 'OmarLawaty/mod-sync'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Here    = $args[0]
$rest    = @($args | Select-Object -Skip 1)
$Csv     = 'https://raw.githubusercontent.com/galactics-minecraft/mods-collector/master/client-mods.csv'
$ModsDir = Join-Path $env:APPDATA '.minecraft\mods'
$DryRun  = $false
$NoPrune = $false

for ($i = 0; $i -lt $rest.Count; $i++) {
  switch ($rest[$i]) {
    '--csv'       { $i++; $Csv = $rest[$i] }
    '--mods-dir'  { $i++; $ModsDir = $rest[$i] }
    '--dry-run'   { $DryRun = $true }
    '--no-prune'  { $NoPrune = $true }
    { $_ -in '--help', '-h', '/?' } {
      Write-Host 'Usage: sync-mods.bat [options]'
      Write-Host '  --csv <path|url>    client-mods.csv location (default: next to this script)'
      Write-Host '  --mods-dir <path>   mods folder (default: %APPDATA%\.minecraft\mods)'
      Write-Host '  --dry-run           show what would change, change nothing'
      Write-Host '  --no-prune          only download missing mods, never remove anything'
      Write-Host 'keep.txt (optional, next to this script): one file name or part of a name per line.'
      Write-Host 'Matching jars are never removed.'
      exit 0
    }
    default { Write-Host "Unknown option: $($rest[$i])"; exit 2 }
  }
}

function Get-JarName([string]$link) {
  try {
    $u = [Uri]$link
    if ($u.Scheme -notin 'http', 'https') { return $null }
    $last = [Uri]::UnescapeDataString($u.Segments[-1]).Trim('/')
  } catch { return $null }
  if ($last -notmatch '\.jar$') { return $null }
  return ($last -replace '[<>:"/\\|?*]', '_')
}

function Get-File([string]$url, [string]$dest) {
  for ($a = 1; $a -le 3; $a++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile "$dest.part" -Headers @{ 'User-Agent' = $UA }
      if ((Get-Item -LiteralPath "$dest.part").Length -eq 0) { throw 'empty file' }
      Move-Item -LiteralPath "$dest.part" -Destination $dest -Force
      return
    } catch {
      Remove-Item -LiteralPath "$dest.part" -ErrorAction SilentlyContinue
      if ($a -eq 3) { throw }
      Start-Sleep -Seconds $a
    }
  }
}

Write-Host "CSV:      $Csv"
Write-Host "Mods dir: $ModsDir$(if ($DryRun) { '   (dry run)' })"
Write-Host ''

# ---------- load csv ----------
try {
  if ($Csv -match '^https?://') {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $Csv -Headers @{ 'User-Agent' = $UA }
    $text = $resp.Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $entries = ($text -replace "^\uFEFF", '') | ConvertFrom-Csv
  } else {
    $entries = Import-Csv -LiteralPath $Csv -Encoding UTF8
  }
} catch {
  Write-Host "[FAIL] could not read the CSV: $($_.Exception.Message)"
  exit 1
}

$wanted = @{}      # file name (case-insensitive) -> entry
$manual = @()
foreach ($e in $entries) {
  $file = Get-JarName $e.link
  if (-not $file) { $manual += $e; continue }
  if (-not $wanted.ContainsKey($file)) {
    $wanted[$file] = [pscustomobject]@{ Name = $e.'mod name'; File = $file; Link = $e.link }
  }
}

# ---------- existing jars ----------
if (-not (Test-Path -LiteralPath $ModsDir)) {
  if (-not $DryRun) { New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null }
}
$existing = @()
if (Test-Path -LiteralPath $ModsDir) {
  $existing = @(Get-ChildItem -LiteralPath $ModsDir -Filter *.jar -File | ForEach-Object { $_.Name })
}
$existingSet = @{}
foreach ($f in $existing) { $existingSet[$f] = $true }

$keepFile = Join-Path $Here 'keep.txt'
$keep = @()
if (Test-Path -LiteralPath $keepFile) {
  $keep = @(Get-Content -LiteralPath $keepFile | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
}
function Test-Kept([string]$f) {
  $l = $f.ToLower()
  foreach ($k in $keep) { if ($l.Contains($k)) { return $true } }
  return $false
}

# ---------- download ----------
$uptodate = 0; $downloaded = 0; $failed = 0
foreach ($w in $wanted.Values) {
  if ($existingSet.ContainsKey($w.File)) { $uptodate++; continue }
  if ($DryRun) { Write-Host "[..] would download $($w.File)"; $downloaded++; continue }
  try {
    Get-File $w.Link (Join-Path $ModsDir $w.File)
    Write-Host "[OK] downloaded $($w.File)"
    $downloaded++
  } catch {
    Write-Host "[FAIL] $($w.Name) ($($w.File)): $($_.Exception.Message)"
    $failed++
  }
}

# ---------- prune ----------
$extras = @($existing | Where-Object { -not $wanted.ContainsKey($_) -and -not (Test-Kept $_) })
$removed = 0
if ($extras.Count -gt 0) {
  if ($NoPrune) {
    Write-Host ''
    Write-Host "[i] $($extras.Count) jar(s) are not in the list and were left alone (--no-prune)."
  } elseif ($failed -gt 0) {
    Write-Host ''
    Write-Host "[WARN] Skipping removal of $($extras.Count) extra jar(s) because $failed download(s) failed."
  } else {
    $backup = Join-Path (Split-Path -Parent $ModsDir) ('mods-removed\' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    if (-not $DryRun) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
    foreach ($f in $extras) {
      if ($DryRun) { Write-Host "[..] would move $f out of the mods folder" }
      else {
        Move-Item -LiteralPath (Join-Path $ModsDir $f) -Destination (Join-Path $backup $f) -Force
        Write-Host "[--] removed $f"
      }
      $removed++
    }
    if (-not $DryRun) { Write-Host "     (moved to $backup)" }
  }
}

# ---------- manual rows ----------
if ($manual.Count -gt 0) {
  Write-Host ''
  Write-Host '[WARN] No direct .jar link for these. Download them by hand and add their jar name to keep.txt:'
  foreach ($m in $manual) { Write-Host "   - $($m.'mod name'): $($m.link)" }
}

Write-Host ''
$dl = if ($DryRun) { 'to download' } else { 'downloaded' }
$rm = if ($DryRun) { 'to remove' } else { 'removed' }
Write-Host "Done. $uptodate up to date, $downloaded $dl, $removed $rm, $failed failed, $($manual.Count) manual."
if ($failed -gt 0) { exit 1 } else { exit 0 }
