$ErrorActionPreference = "Stop"

$VIRTIO_WIN_PATH = "E:\"

Write-Output "Installing virtio-win guest tools"

# Trust driver certs
$certStore = Get-Item "cert:\LocalMachine\TrustedPublisher"
$certStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$driverPath = Get-Item "${VIRTIO_WIN_PATH}\*\2k19\amd64"
Get-ChildItem -Recurse -Path $driverPath -Filter "*.cat" | ForEach-Object {
    $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
    $certStore.Add($cert)
}
$certStore.Close()

# Install QEMU quest tools
$p = Start-Process -FilePath "${VIRTIO_WIN_PATH}\virtio-win-guest-tools.exe" -ArgumentList @("/install", "/quiet", "/norestart") -NoNewWindow -PassThru -Wait
if($p.ExitCode) {
    Throw "The virtio-win guest tools installation failed. Exit code: $($p.ExitCode)"
}

Write-Output "Successfully installed virtio-win guest tools"
