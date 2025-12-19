# C:\ensure-toolchain.ps1
# Ensures VS Build Tools + SDK + WDK are present, and prints the version we will build against.

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "==> $msg" }

function Get-WinKitsRoot {
  $root = "${env:ProgramFiles(x86)}\Windows Kits\10\"
  if (!(Test-Path $root)) { throw "Windows Kits root not found: $root" }
  return $root
}

function Get-InstalledSdkVersions {
  $root = Get-WinKitsRoot
  $inc = Join-Path $root "Include"
  if (!(Test-Path $inc)) { return @() }

  # folders like 10.0.19041.0, 10.0.22000.0, etc.
  Get-ChildItem -Directory $inc |
    ForEach-Object { $_.Name } |
    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object {[version]$_} -Descending
}

function Test-WdkInstalledForVersion([string]$ver) {
  $root = Get-WinKitsRoot

  # If WDK is installed, these typically exist for that version:
  # - Include\<ver>\km  (WDK kernel-mode headers)
  # - Lib\<ver>\km
  $kmInc = Join-Path $root "Include\$ver\km"
  $kmLib = Join-Path $root "Lib\$ver\km"
  return (Test-Path $kmInc) -and (Test-Path $kmLib)
}

function Get-StampinfDir([string]$ver) {
  $root = Get-WinKitsRoot
  foreach ($arch in @("x64","x86")) {
    $d = Join-Path $root "bin\$ver\$arch"
    if (Test-Path (Join-Path $d "stampinf.exe")) { return $d }
  }
  return $null
}

function Ensure-VSBuildTools {
  Write-Info "Ensuring VS 2019 Build Tools + Windows 10 SDK 19041 are installed"

  $btPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools"
  $vcvars = Join-Path $btPath "VC\Auxiliary\Build\vcvars64.bat"

  if (Test-Path $vcvars) {
    Write-Info "VS Build Tools already present: $btPath"
    return
  }

  $bootstrap = Join-Path $env:TEMP "vs_buildtools.exe"
  if (!(Test-Path $bootstrap)) {
    Write-Info "Downloading VS Build Tools bootstrapper"
    Invoke-WebRequest -Uri "https://aka.ms/vs/16/release/vs_buildtools.exe" -OutFile $bootstrap
  }

  # Install minimal set + SDK 19041.
  # --wait is a supported bootstrapper flag.  (not the same as setup.exe modify)
  # See MS docs. 
  $args = @(
    "--quiet","--wait","--norestart","--nocache",
    "--add","Microsoft.VisualStudio.Workload.VCTools",
    "--add","Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add","Microsoft.VisualStudio.Component.Windows10SDK.19041"
  )

  Write-Info "Installing VS Build Tools..."
  $p = Start-Process -FilePath $bootstrap -ArgumentList $args -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "vs_buildtools.exe failed with exit code $($p.ExitCode)" }

  if (!(Test-Path $vcvars)) { throw "VS Build Tools still missing after install (expected $vcvars)" }
}

function Ensure-WDK19041 {
  Write-Info "Ensuring WDK (10.0.19041.0) is installed"

  $ver = "10.0.19041.0"
  if (Test-WdkInstalledForVersion $ver) {
    Write-Info "WDK $ver already installed"
    return
  }

  # Server 2019 often has no winget; use the specific 19041 WDK installer link.
  $wdkUrl = "https://go.microsoft.com/fwlink/?linkid=2342425"  # WDK Win10 2004 / 19041
  $wdkExe = Join-Path $env:TEMP "wdksetup-19041.exe"

  Write-Info "Downloading WDK 19041 installer to $wdkExe"
  Invoke-WebRequest -Uri $wdkUrl -OutFile $wdkExe

  Write-Info "Running WDK installer (/quiet /norestart)"
  $p = Start-Process -FilePath $wdkExe -ArgumentList "/quiet","/norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "WDK installer failed with exit code $($p.ExitCode)" }

  Start-Sleep -Seconds 5

  if (!(Test-WdkInstalledForVersion $ver)) {
    throw @"
WDK $ver install ran but the expected paths are still missing.
Expected:
  ${env:ProgramFiles(x86)}\Windows Kits\10\Include\$ver\km
  ${env:ProgramFiles(x86)}\Windows Kits\10\Lib\$ver\km

If this VM needs a reboot to finalize kit registration, reboot and rerun setup.
"@
  }

  Write-Info "WDK $ver installed"
}

Ensure-VSBuildTools
Ensure-WDK19041

# Choose the *highest* SDK version that has a matching WDK (km headers/libs).
# --- PIN to 19041 ---
$chosen = "10.0.19041.0"

# SDK must exist
$root = Get-WinKitsRoot
$sdkInc = Join-Path $root "Include\$chosen"
if (!(Test-Path $sdkInc)) {
  throw "Pinned SDK $chosen not found under $sdkInc. Install Windows 10 SDK $chosen."
}

# WDK must exist (km headers/libs)
if (!(Test-WdkInstalledForVersion $chosen)) {
  throw "Pinned WDK $chosen not found (missing Include\$chosen\km and/or Lib\$chosen\km under Windows Kits). Install Windows 10 WDK $chosen."
}

$stampDir = Get-StampinfDir $chosen
if (!$stampDir) { throw "stampinf.exe not found for SDK version $chosen" }

Write-Info "Pinned WindowsTargetPlatformVersion: $chosen"
Write-Info "stampinf dir: $stampDir"

"WindowsSdkDir=$(Get-WinKitsRoot)"
"WindowsTargetPlatformVersion=$chosen"
"StampinfDir=$stampDir"
