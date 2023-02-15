param (
    [Parameter(Mandatory)]
    [string]$LogDirectory,
    [switch]$IncludeEvtxFiles = $false,
    [switch]$CleanupEventLog = $false
)

$ErrorActionPreference = "Ignore"

function DumpEventLogEvtx($path){
    foreach ($i in (Get-WinEvent -ListLog * |  ? {$_.RecordCount -gt 0 })) {
        $logName = "eventlog_" + $i.LogName + ".evtx"
        $logName = $logName.replace(" ","-").replace("/", "-").replace("\", "-")
        Write-Output "exporting "$i.LogName" as "$logName
        $logFile = Join-Path $path $logName
        & $Env:WinDir\System32\wevtutil.exe epl $i.LogName $logFile
        if ($LASTEXITCODE) {
            Write-Output "Failed to export $($i.LogName) to $logFile"
        }
    }
}

function DumpEventLogTxt($path){
    foreach ($i in (Get-WinEvent -ListLog * |  ? {$_.RecordCount -gt 0 })) {
        $logName = "eventlog_" + $i.LogName + ".txt"
        $logName = $logName.replace(" ","-").replace("/", "-").replace("\", "-")
        Write-Output "exporting "$i.LogName" as "$logName
        $logFile = Join-Path $path $logName
        Get-WinEvent `
            -ErrorAction "Ignore" `
            -FilterHashtable @{
                LogName=$i.LogName;
                StartTime=$(Get-Date).AddHours(-6)
            } | `
            Format-Table -AutoSize -Wrap > $logFile
    }
}

function ClearEventLog(){
    foreach ($i in (Get-WinEvent -ListLog * |  ? {$_.RecordCount -gt 0 })) {
        & $Env:WinDir\System32\wevtutil.exe cl $i.LogName
        if ($LASTEXITCODE) {
            Write-Output "Failed to clear $($i.LogName) from the event log"
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

Write-Output "Successfully collected Windows event logs."
