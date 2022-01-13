$ErrorActionPreference = "Stop"

Get-WindowsCapability -Online -Name OpenSSH* | Add-WindowsCapability -Online

Set-Service -Name "sshd" -StartupType Automatic
Start-Service -Name "sshd"

New-NetFirewallRule -Name "sshd" -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# Authorize the SSH key
$authorizedKeysFile = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
Set-Content -Path $authorizedKeysFile -Value (Get-Content "${PSScriptRoot}\id_rsa.pub") -Encoding ascii
$acl = Get-Acl $authorizedKeysFile
$acl.SetAccessRuleProtection($true, $false)
$administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule("Administrators", "FullControl", "Allow")
$systemRule = New-Object system.security.accesscontrol.filesystemaccessrule("SYSTEM", "FullControl", "Allow")
$acl.SetAccessRule($administratorsRule)
$acl.SetAccessRule($systemRule)
$acl | Set-Acl
