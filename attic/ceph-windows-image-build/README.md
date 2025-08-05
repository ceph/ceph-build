# Ceph Windows Image Build

The Windows image can be generated, fully unattended, via the build script:

```bash
./build/build
```

It accepts the following environment variables:

* `SSH_PRIVATE_KEY` (required) - The SSH private key path that will be authorized to access the VMs using the new image.
* `WINDOWS_SERVER_2019_ISO_URL` (optional) - URL to the Windows Server 2019 ISO image. It defaults to the official Microsoft evaluation ISO.
* `VIRTIO_WIN_ISO_URL` (optional) - URL to the virtio-win guest tools ISO image. It defaults to the stable ISO from the [official docs](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md#downloads).

The build script assumes that the host is a KVM enabled machine, and it will do the following:

1. Download the ISOs from the URLs specified in the environment variables (or the defaults if not given).

2. Start a libvirt virtual machine and install the Windows Server 2019 from the ISO.

    * The process is fully unattended, via the `autounattended.xml` file with the input needed to install the operating system.

    * The virtio drivers and the guest tools are installed from the ISO.

    * SSH is configured and the given SSH private key is authorized.

3. Install the latest Windows updates.

4. Run the `setup.ps1` script to prepare the CI environment.

5. Generalize the VM image via `Sysprep`.
