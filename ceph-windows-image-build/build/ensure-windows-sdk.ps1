# ensure-windows-sdk.ps1
# Emits:
#   StampinfDir=...
#   WindowsSdkDir=...
#   WindowsTargetPlatformVersion=...

$ErrorActionPreference = "Stop"

function Find-StampinfDir {
  $base = "C:\Program Files (x86)\Windows Kits\10\bin"
  if (!(Test-Path $base)) { return $null }

  # Prefer x64 stampinf
  $hit = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object Name -Descending |
    ForEach-Object {
      $x64 = Join-Path $_.FullName "x64"
      $exe = Join-Path $x64 "stampinf.exe"
      if (Test-Path $exe) { return $x64 }
    }

  if ($hit) { return $hit }
  return $null
}

function Find-WindowsSdk {
  $sdkRoot = "C:\Program Files (x86)\Windows Kits\10"
  if (!(Test-Path $sdkRoot)) { throw "Windows Kits root not found: $sdkRoot" }

  $inc = Join-Path $sdkRoot "Include"
  if (!(Test-Path $inc)) { throw "Windows SDK Include dir not found: $inc" }

  $ver = Get-ChildItem -Path $inc -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if (!$ver) { throw "No versioned SDK include dir under: $inc" }

  # This is what MSBuild expects
  $windowsSdkDir = $sdkRoot + "\"
  $windowsTargetPlatformVersion = $ver.Name

  return @{ WindowsSdkDir = $windowsSdkDir; WindowsTargetPlatformVersion = $windowsTargetPlatformVersion }
}

$stampDir = Find-StampinfDir
if (-not $stampDir) { throw "stampinf.exe not found under Windows Kits bin\x64 (WDK/SDK missing or incomplete)" }

$sdk = Find-WindowsSdk

# Emit key=value lines ONLY (so callers can parse cleanly)
"StampinfDir=$stampDir"
"WindowsSdkDir=$($sdk.WindowsSdkDir)"
"WindowsTargetPlatformVersion=$($sdk.WindowsTargetPlatformVersion)"
