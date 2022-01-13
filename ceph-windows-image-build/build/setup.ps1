$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$VS_2019_BUILD_TOOLS_URL = "https://aka.ms/vs/16/release/vs_buildtools.exe"
$WDK_URL = "https://download.microsoft.com/download/7/d/6/7d602355-8ae9-414c-ae36-109ece2aade6/wdk/wdksetup.exe"  # Windows 11 WDK (22000.1). It can be used to develop drivers for previous OS releases.
$PYTHON3_URL = "https://www.python.org/ftp/python/3.10.1/python-3.10.1-amd64.exe"

$WNBD_GIT_REPO = "https://github.com/ceph/wnbd.git"
$WNBD_GIT_BRANCH = "master"


function Get-WindowsBuildInfo {
    $p = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $table = New-Object System.Data.DataTable
    $table.Columns.AddRange(@("Release", "Version", "Build"))
    $table.Rows.Add($p.ProductName, $p.ReleaseId, "$($p.CurrentBuild).$($p.UBR)") | Out-Null
    return $table
}

function Invoke-CommandLine {
    Param(
        [Parameter(Mandatory=$true)]
        [String]$Command,
        [String]$Arguments,
        [Int[]]$AllowedExitCodes=@(0)
    )
    & $Command $Arguments.Split(" ")
    if($LASTEXITCODE -notin $AllowedExitCodes) {
        Throw "$Command $Arguments returned a non zero exit code ${LASTEXITCODE}."
    }
}

function Start-ExecuteWithRetry {
    Param(
        [Parameter(Mandatory=$true)]
        [ScriptBlock]$ScriptBlock,
        [Int]$MaxRetryCount=10,
        [Int]$RetryInterval=3,
        [String]$RetryMessage,
        [Array]$ArgumentList=@()
    )
    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0
    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
            $ErrorActionPreference = $currentErrorActionPreference
            return $res
        } catch [System.Exception] {
            $retryCount++
            if ($retryCount -gt $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                Throw $_
            } else {
                $prefixMsg = "Retry(${retryCount}/${MaxRetryCount})"
                if($RetryMessage) {
                    Write-Host "${prefixMsg} - $RetryMessage"
                } elseif($_) {
                    Write-Host "${prefixMsg} - $($_.ToString())"
                }
                Start-Sleep $RetryInterval
            }
        }
    }
}

function Start-FileDownload {
    Param(
        [Parameter(Mandatory=$true)]
        [String]$URL,
        [Parameter(Mandatory=$true)]
        [String]$Destination,
        [Int]$RetryCount=10
    )
    Write-Output "Downloading $URL to $Destination"
    Start-ExecuteWithRetry `
        -ScriptBlock { Invoke-CommandLine -Command "curl.exe" -Arguments "-L -s -o $Destination $URL" } `
        -MaxRetryCount $RetryCount `
        -RetryMessage "Failed to download '${URL}'. Retrying"
    Write-Output "Successfully downloaded."
}

function Add-ToPathEnvVar {
    Param(
        [Parameter(Mandatory=$true)]
        [String[]]$Path,
        [Parameter(Mandatory=$false)]
        [ValidateSet([System.EnvironmentVariableTarget]::User, [System.EnvironmentVariableTarget]::Machine)]
        [System.EnvironmentVariableTarget]$Target=[System.EnvironmentVariableTarget]::Machine
    )
    $pathEnvVar = [Environment]::GetEnvironmentVariable("PATH", $Target).Split(';')
    $currentSessionPath = $env:PATH.Split(';')
    foreach($p in $Path) {
        if($p -notin $pathEnvVar) {
            $pathEnvVar += $p
        }
        if($p -notin $currentSessionPath) {
            $currentSessionPath += $p
        }
    }
    $env:PATH = $currentSessionPath -join ';'
    $newPathEnvVar = $pathEnvVar -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPathEnvVar, $Target)
}

function Install-Tool {
    [CmdletBinding(DefaultParameterSetName = "URL")]
    Param(
        [Parameter(Mandatory=$true, ParameterSetName = "URL")]
        [String]$URL,
        [Parameter(Mandatory=$true, ParameterSetName = "LocalPath")]
        [String]$LocalPath,
        [Parameter(ParameterSetName = "URL")]
        [Parameter(ParameterSetName = "LocalPath")]
        [String[]]$Params=@(),
        [Parameter(ParameterSetName = "URL")]
        [Parameter(ParameterSetName = "LocalPath")]
        [Int[]]$AllowedExitCodes=@(0)
    )
    PROCESS {
        $installerPath = $LocalPath
        if($PSCmdlet.ParameterSetName -eq "URL") {
            $installerPath = Join-Path $env:TEMP $URL.Split('/')[-1]
            Start-FileDownload -URL $URL -Destination $installerPath
        }
        Write-Output "Installing ${installerPath}"
        $p = Start-Process -FilePath $installerPath -ArgumentList $Params -NoNewWindow -PassThru -Wait
        if($p.ExitCode -notin $AllowedExitCodes) {
            Throw "Installation failed. Exit code: $($p.ExitCode)"
        }
        if($PSCmdlet.ParameterSetName -eq "URL") {
            Start-ExecuteWithRetry `
                -ScriptBlock { Remove-Item -Force -Path $installerPath -ErrorAction Stop } `
                -RetryMessage "Failed to remove ${installerPath}. Retrying"
        }
    }
}

function Get-GitHubReleaseAssets {
    Param(
        [Parameter(Mandatory=$true)]
        [String]$Repository,
        [String]$Version="latest"
    )
    $releasesUrl = "https://api.github.com/repos/${Repository}/releases"
    if($Version -eq "latest") {
        $release = Invoke-CommandLine "curl.exe" "-s ${releasesUrl}/latest" | ConvertFrom-Json
    } else {
        $releases = Invoke-CommandLine "curl.exe" "-s ${releasesUrl}" | ConvertFrom-Json
        $release = $releases | Where-Object { $_.tag_name -eq $Version }
        if(!$release) {
            Throw "Cannot find '${Repository}' release '${Version}'."
        }
    }
    return $release.assets
}

function Set-VCVars {
    Param(
        [String]$Version="2019",
        [String]$Platform="x86_amd64"
    )
    Push-Location "${env:ProgramFiles(x86)}\Microsoft Visual Studio\${Version}\BuildTools\VC\Auxiliary\Build"
    try {
        cmd.exe /c "vcvarsall.bat ${Platform} & set" | ForEach-Object {
            if ($_ -match "=") {
                $v = $_.split("=")
                Set-Item -Force -Path "ENV:\$($v[0])" -Value "$($v[1])"
            }
        }
    }
    finally {
        Pop-Location
    }
}

function Install-Requirements {
    # Create the needed directories
    New-Item `
        -ItemType Directory -Force `
        -Path @(
            "${env:SystemDrive}\tmp",
            "${env:SystemDrive}\ceph",
            "${env:SystemDrive}\wnbd",
            "${env:SystemDrive}\workspace",
            "${env:SystemDrive}\workspace\repos"
        )
    Add-ToPathEnvVar -Path @("${env:SystemDrive}\ceph", "${env:SystemDrive}\wnbd")
    # Set UTC time zone
    Set-TimeZone -Id "UTC"
    # Allow ping requests
    Get-NetFirewallRule -Name @("FPS-ICMP4-ERQ-In", "FPS-ICMP6-ERQ-In") | Enable-NetFirewallRule
    # Allow test signed drivers
    Invoke-CommandLine "bcdedit.exe" "/set testsigning yes"
}

function Install-VisualStudio2019BuildTools {
    Write-Output "Installing Visual Studio 2019 Build Tools"
    $params = @(
        "--quiet", "--wait", "--norestart", "--nocache",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Workload.MSBuildTools",
        "--add", "Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22000"
    )
    Install-Tool -URL $VS_2019_BUILD_TOOLS_URL -Params $params -AllowedExitCodes @(0, 3010)
    Write-Output "Successfully installed Visual Studio 2019 Build Tools"
}

function Install-WDK {
    # Install WDK excluding WDK.vsix
    Write-Output "Installing Windows Development Kit (WDK)"
    Install-Tool -URL $WDK_URL -Params @("/q")
    # Install WDK.vsix in manual manner
    Copy-Item -Path "${env:ProgramFiles(x86)}\Windows Kits\10\Vsix\VS2019\WDK.vsix" -Destination "${env:TEMP}\wdkvsix.zip"
    Expand-Archive "${env:TEMP}\wdkvsix.zip" -DestinationPath "${env:TEMP}\wdkvsix"
    $src = "${env:TEMP}\wdkvsix\`$MSBuild\Microsoft\VC\v160"
    $dst = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools\MSBuild\Microsoft\VC\v160"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Push-Location $src
    Get-ChildItem -Recurse | Resolve-Path -Relative | ForEach-Object {
        $item = Get-Item -Path $_
        if($item.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path "${dst}\$_" | Out-Null
        } else {
            Copy-Item -Force -Path $item.FullName -Destination "${dst}\$_" | Out-Null
        }
    }
    Pop-Location
    Remove-Item -Recurse -Force -Path @("${env:TEMP}\wdkvsix.zip", "${env:TEMP}\wdkvsix")
    Write-Output "Successfully installed Windows Development Kit (WDK)"
}

function Get-GitDownloadUrl {
    Param(
        [String]$Version="latest"
    )
    $asset = Get-GitHubReleaseAssets -Repository "git-for-windows/git" -Version $Version | Where-Object {
        $_.content_type -eq "application/executable" -and `
        $_.name.StartsWith("Git-") -and `
        $_.name.EndsWith("-64-bit.exe") }
    if(!$asset) {
        Throw "Cannot find Git on Windows release asset with the 64-bit installer."
    }
    if($asset.Count -gt 1) {
        Throw "Found multiple Git on Windows release assets with the 64-bit installer."
    }
    return $asset.browser_download_url
}

function Install-Git {
    Write-Output "Installing Git"
    Install-Tool -URL (Get-GitDownloadUrl) -Params @("/VERYSILENT", "/NORESTART")
    Add-ToPathEnvVar -Path @("${env:ProgramFiles}\Git\cmd", "${env:ProgramFiles}\Git\usr\bin")
    Write-Output "Successfully installed Git"
}

function Install-WnbdDriver {
    $outDir = Join-Path $env:SystemDrive "wnbd"
    $gitDir = Join-Path $env:TEMP "wnbd"
    Invoke-CommandLine "git.exe" "clone ${WNBD_GIT_REPO} --branch ${WNBD_GIT_BRANCH} ${gitDir}"
    Push-Location $gitDir
    try {
        Set-VCVars
        Invoke-CommandLine "MSBuild.exe" "vstudio\wnbd.sln /p:Configuration=Release"
        Copy-Item -Force -Path "vstudio\x64\Release\driver\*" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\libwnbd.dll" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\wnbd-client.exe" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\wnbd.cer" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\pdb\driver\*" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\pdb\libwnbd\*" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\x64\Release\pdb\wnbd-client\*" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\wnbdevents.xml" -Destination "${outDir}\"
        Copy-Item -Force -Path "vstudio\reinstall.ps1" -Destination "${outDir}\"
    } finally {
        Pop-Location
        Remove-Item -Recurse -Force -Path $gitDir
    }
    Import-Certificate -FilePath "${outDir}\wnbd.cer" -Cert Cert:\LocalMachine\Root
    Import-Certificate -FilePath "${outDir}\wnbd.cer" -Cert Cert:\LocalMachine\TrustedPublisher
    Invoke-CommandLine "wnbd-client.exe" "install-driver ${outDir}\wnbd.inf"
    Invoke-CommandLine "wevtutil.exe" "im ${outDir}\wnbdevents.xml"
}

function Install-Python3 {
    Write-Output "Installing Python3"
    Install-Tool -URL $PYTHON3_URL -Params @("/quiet", "InstallAllUsers=1", "PrependPath=1")
    Add-ToPathEnvVar -Path @("${env:ProgramFiles}\Python310\", "${env:ProgramFiles}\Python310\Scripts\")
    Write-Output "Installing pip dependencies"
    Start-ExecuteWithRetry {
        # Needed to run the Ceph unit tests via https://github.com/ceph/ceph-win32-tests scripts
        Invoke-CommandLine "pip3.exe" "install os-testr python-dateutil requests"
    }
    Write-Output "Successfully installed Python3"
}

function Get-Wix3ToolsetDownloadUrl {
    Param(
        [String]$Version="latest"
    )
    $asset = Get-GitHubReleaseAssets -Repository "wixtoolset/wix3" -Version $Version | Where-Object {
        $_.content_type -eq "application/x-msdownload" }
    if(!$asset) {
        Throw "Cannot find Wix3 toolset release asset."
    }
    if($asset.Count -gt 1) {
        Throw "Found multiple Wix3 toolset release assets."
    }
    return $asset.browser_download_url
}

function Install-Wix3Toolset {
    Write-Output "Installing .NET Framework 3.5"
    Install-WindowsFeature -Name "NET-Framework-Features" -ErrorAction Stop
    Write-Output "Installing Wix3 toolset"
    Install-Tool -URL (Get-Wix3ToolsetDownloadUrl) -Params @("/install", "/quiet", "/norestart")
    Write-Output "Successfully installed Wix3 toolset"
}


Get-WindowsBuildInfo
Install-Requirements
Install-VisualStudio2019BuildTools
Install-WDK
Install-Git
Install-WnbdDriver
Install-Python3
Install-Wix3Toolset

Write-Output "Successfully installed the CI environment. Please reboot the system before sysprep."
