# ensure-stampinf.ps1
# Outputs ONLY the directory that contains x64/amd64 stampinf.exe (stdout).
# No where.exe. No Write-Host.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Find-StampInfDir {
  $base = "C:\Program Files (x86)\Windows Kits\10\bin"
  if (!(Test-Path $base)) { return $null }

  $hit = Get-ChildItem -Path $base -Recurse -Filter stampinf.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\x64\stampinf.exe" -or $_.FullName -like "*\amd64\stampinf.exe" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

  if (-not $hit) {
    $hit = Get-ChildItem -Path $base -Recurse -Filter stampinf.exe -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notlike "*\arm64\stampinf.exe" } |
      Select-Object -First 1
  }

  if (-not $hit) { return $null }

  if ($hit.FullName -like "*\arm64\stampinf.exe") {
    throw "Found only ARM64 stampinf.exe ($($hit.FullName)); need x64/amd64."
  }

  return $hit.Directory.FullName
}

$dir = Find-StampInfDir
if ([string]::IsNullOrWhiteSpace($dir) -or !(Test-Path $dir)) {
  throw "stampinf.exe not found under Windows Kits bin. WDK x64 tools missing."
}

# Stdout: ONLY the dir path
Write-Output $dir
