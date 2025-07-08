$ErrorActionPreference = "Stop"
$ProgressPreference='SilentlyContinue'

Write-Output "Installing PSWindowsUpdate PowerShell module"
Install-PackageProvider -Name "NuGet" -Force -Confirm:$false
Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
Install-Module -Name "PSWindowsUpdate" -Force -Confirm:$false

Write-Output "Installing latest Windows updates"
$updateScript = {
    Import-Module "PSWindowsUpdate"
    Install-WindowsUpdate -AcceptAll -IgnoreReboot | Out-File -FilePath "${env:SystemDrive}\PSWindowsUpdate.log" -Encoding ascii
}
Invoke-WUJob -Script $updateScript -Confirm:$false -RunNow
while($true) {
    $task = Get-ScheduledTask -TaskName "PSWindowsUpdate"
    if($task.State -eq "Ready") {
        break
    }
    Start-Sleep -Seconds 10
}
Get-Content "${env:SystemDrive}\PSWindowsUpdate.log"
Remove-Item -Force -Path "${env:SystemDrive}\PSWindowsUpdate.log"
Unregister-ScheduledTask -TaskName "PSWindowsUpdate" -Confirm:$false
Write-Output "Windows updates successfully installed"
