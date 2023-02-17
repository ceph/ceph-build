param (
    [Parameter(Mandatory)]
    [string]$LogDirectory,
    [switch]$IncludeEvtxFiles = $false,
    [switch]$CleanupEventLog = $false
)

function SanitizeName {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )
    return $Name.replace(" ","-").replace("/", "-").replace("\", "-")
}

function DumpEventLogEvtx {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    $winEvents = Get-WinEvent -ListLog * | Where-Object { $_.RecordCount -gt 0 }
    foreach ($i in $winEvents) {
        $logFile = Join-Path $Path "eventlog_$(SanitizeName $i.LogName).evtx"

        Write-Output "exporting '$($i.LogName)' to $logFile"
        & $Env:WinDir\System32\wevtutil.exe epl "$($i.LogName)" $logFile
        if ($LASTEXITCODE) {
            Write-Output "Failed to export $($i.LogName) to $logFile"
        }
    }
}

function DumpEventLogTxt {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    $winEvents = Get-WinEvent -ListLog * | Where-Object { $_.RecordCount -gt 0 }
    foreach ($i in $winEvents) {
        $logFile = Join-Path $Path "eventlog_$(SanitizeName $i.LogName).txt"

        Write-Output "exporting '$($i.LogName)' to $logFile"
        Get-WinEvent `
            -ErrorAction "SilentlyContinue" `
            -FilterHashtable @{
                LogName=$i.LogName;
                StartTime=$(Get-Date).AddHours(-6)
            } | `
            Format-Table -AutoSize -Wrap | Out-File -Encoding ascii -FilePath $logFile
    }
}

function ClearEventLog {
    $winEvents = Get-WinEvent -ListLog * | Where-Object { $_.RecordCount -gt 0 }
    foreach ($i in $winEvents) {
        & $Env:WinDir\System32\wevtutil.exe cl $i.LogName
        if ($LASTEXITCODE) {
            Write-Output "Failed to clear '$($i.LogName)' from the event log"
        }
    }
}

mkdir -force $LogDirectory

DumpEventLogTxt $LogDirectory

if ($IncludeEvtxFiles) {
    DumpEventLogEvtx $LogDirectory
}

if ($CleanupEventLog) {
    ClearEventLog
}

Write-Output "Finished collecting Windows event logs."
