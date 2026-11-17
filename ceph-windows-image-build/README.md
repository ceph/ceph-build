# Ceph Windows Image Build

The Windows image can be generated, fully unattended, via the build script:

```bash
./build/build
```

It accepts the following environment variables:

* `SSH_PRIVATE_KEY` (required) - The SSH private key the build uses to log in to the VM. Its public key must be one of `build/authorized_keys/*.pub`.
* `WINDOWS_SERVER_2019_ISO_URL` (optional) - URL to the Windows Server 2019 ISO image. It defaults to the lab copy of the Microsoft evaluation ISO on apt-mirror.sepia.ceph.com.
* `VIRTIO_WIN_ISO_URL` (optional) - URL to the virtio-win guest tools ISO image. It defaults to the lab copy on apt-mirror.sepia.ceph.com of the stable ISO from the [official docs](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md#downloads).

The build script assumes that the host is a KVM enabled machine, and it will do the following:

1. Download the ISOs from the URLs specified in the environment variables (or the defaults if not given).

2. Start a libvirt virtual machine and install the Windows Server 2019 from the ISO.

    * The process is fully unattended, via the `autounattended.xml` file with the input needed to install the operating system.

    * The virtio drivers and the guest tools are installed from the ISO.

    * SSH is configured and the public keys in `build/authorized_keys/` are authorized for `administrator`.

3. Install the latest Windows updates.

4. Run the `setup.ps1` script to prepare the CI environment.

5. Generalize the VM image via `Sysprep`.

## Rotating the CI SSH key

The private key is the Jenkins "Secret file" credential `ceph_win_ci_private_key`
(1Password item of the same name). To rotate it:

1. Generate a new key pair and store the private key in 1Password; commit the public
   key as a new file in `build/authorized_keys/`, keeping the old one.
2. Run `ceph-windows-image-build` and publish the image (the build log prints how).
   The image now accepts both keys.
3. Push the new private key into the Jenkins credential and run a consumer job
   (`wnbd-build`, `ceph-windows-installer-build`, the ceph-pr-pipeline Windows leg).
4. Remove the old `.pub`, rebuild and publish the image again.
