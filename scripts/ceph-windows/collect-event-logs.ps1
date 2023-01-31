param (
    [Parameter(Mandatory)]
    [string]$LogDirectory,
    [switch]$IncludeEvtxFiles = $false,
    [switch]$CleanupEventLog = $false
)

$ErrorActionPreference = "Stop"

function DumpEventLogEvtx($path){
    foreach ($i in (Get-WinEvent -ListLog * |  ? {$_.RecordCount -gt 0 })) {
        $logName = "eventlog_" + $i.LogName + ".evtx"
        $logName = $logName.replace(" ","-").replace("/", "-").replace("\", "-")
        Write-Output "exporting "$i.LogName" as "$logName
        $logFile = Join-Path $path $logName
        & $Env:WinDir\System32\wevtutil.exe epl $i.LogName $logFile
        if ($LASTEXITCODE) {
            Throw "Failed to export $($i.LogName) to $logFile"
        }
    }
}

function ConvertEvtxDumpToTxt($path){
    foreach ($i in (Get-ChildItem $path -Filter eventlog_*.evtx)) {
        $logName = $i.BaseName + ".txt"
        $logName = $logName.replace(" ","-").replace("/", "-").replace("\", "-")
        Write-Output "converting "$i.BaseName" evtx to txt"
        $logFile = Join-Path $path $logName
        & $Env:WinDir\System32\wevtutil.exe qe $i.FullName /lf > $logFile
        if ($LASTEXITCODE) {
            Throw "Failed to convert $($i.FullName) to txt"
        }
    }
}

function ClearEventLog(){
    foreach ($i in (Get-WinEvent -ListLog * |  ? {$_.RecordCount -gt 0 })) {
        & $Env:WinDir\System32\wevtutil.exe cl $i.LogName
        if ($LASTEXITCODE) {
            Throw "Failed to clear $($i.LogName) from the event log"
        }
    }
}

mkdir -force $LogDirectory

DumpEventLogEvtx $LogDirectory
ConvertEvtxDumpToTxt $LogDirectory

if ($CleanupEventLog) {
    ClearEventLog
}

if (-not $IncludeEvtxFiles) {
    rm $LogDirectory\eventlog_*.evtx
}
