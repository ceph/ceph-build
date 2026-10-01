sepia-fog-windows-images
========================

Refreshes the Windows Server FOG_ testnode images (tracker `80811`_:
Windows Server 2025 on testnodes for AD/SMB-on-Ceph testing).  The Windows
counterpart of sepia-fog-images_: FOG-deploy the existing
``<machinetype>_windows_<version>`` image, run Windows Update, clean up,
recapture, and verify the capture boots on a second host.  The OS-agnostic
plumbing (FOG API, IPMI, teuthology lock/queue handling, flaky-PXE nudging)
is shared with the Linux job via ``sepia-fog-images/build/fog-lib.sh``;
everything in ``build/fog-windows.sh`` is Windows policy.

Manual trigger only -- there is no cron.  ``trial`` is the supported
machine type for now (UEFI-only hosts; Windows Server 2025 requires UEFI).

Licensing
---------

Per the tracker: the images are built from the Windows Server **Evaluation**
ISO (180 days).  Windows installs on testnodes are meant to be short-lived,
OR the user who locked the machine is responsible for applying license
keys.  The job deliberately does **not** sysprep between captures: sysprep
rearms are a finite resource, and duplicate machine SIDs are harmless for
hostname-unique testnodes (including domain join and DC promotion).  The
FOG client's HostnameChanger gives every deployed node its own hostname.

Golden image prerequisites
--------------------------

The first image is installed by hand once; after that this job refreshes
it.  Install Windows Server Evaluation (Desktop Experience or Core, the
job does not care) on a testnode via BMC virtual media with an
``autounattend.xml``, and bake in:

#. **OpenSSH Server**, enabled and started, with PowerShell as the default
   shell::

     Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
     Set-Service sshd -StartupType Automatic; Start-Service sshd
     New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
       -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

#. The ``jenkins-build`` and teuthology public keys in
   ``C:\ProgramData\ssh\administrators_authorized_keys`` (mind the ACLs:
   Administrators + SYSTEM only), so the job can ssh as ``Administrator``.

#. The **FOG client** (SmartInstaller, pointed at the FOG server) -- its
   HostnameChanger module renames each deployed host to its FOG host
   record's name and reboots it.  That rename is the job's readiness
   signal, the Windows equivalent of the Linux images' sentinel file.

#. The **PSWindowsUpdate** module (``Install-Module PSWindowsUpdate``) --
   the update phase runs it from a SYSTEM scheduled task, because the
   Windows Update API refuses most operations from an ssh (network) logon.

#. DHCP networking (dnsmasq hands out the MAC-reserved IP; do not
   configure anything static) and RDP enabled for interactive users.

Seeding the first image
-----------------------

#. Install the golden image by hand as above on a locked testnode.
#. Make sure the host's dnsmasq PXE entry points at ``fog`` and the host
   is registered in FOG (the trial nodes already are).
#. Run this job with ``DEFINEDHOSTS=<host>`` and ``SKIPDEPLOY`` checked:
   the host's current install is update/prepped and captured as
   ``<type>_windows_<version>`` (the FOG image record is created on first
   capture, with Windows osID and Single Disk - Resizable).

How it works
------------

#. Locks one testnode per machine type (paddles lock, marked down), or
   uses ``DEFINEDHOSTS``.
#. FOG-deploys the existing ``<type>_windows_<version>`` image (only an
   image FOG has recorded a size for counts), reboots, and waits for the
   host to come up over ssh *as itself* -- i.e. after the FOG client's
   hostname rename and reboot.  The deploy only counts if FOG bumps the
   host's ``deployed`` timestamp, and the installed ProductName must match
   ``Server <version>``.
#. Runs Windows Update via PSWindowsUpdate in a SYSTEM scheduled task, up
   to 3 rounds, rebooting while updates keep requesting it.
#. Preps for capture: DISM component cleanup, drops update/temp litter,
   and schedules an offline NTFS repair + reboot if ``C:`` is dirty (the
   Windows stand-in for the Linux job's fsck phase, so ntfsresize starts
   from a clean filesystem).
#. Creates a FOG capture task and reboots.  The shared task-wait helpers
   re-reboot a host whose task is never picked up (the warm-cycle PXE
   flake on the trial sleds).
#. Verifies by deploying the new image onto a *different* host of the
   same type and checking ssh, hostname, and Windows version.
#. Unlocks everything; cleanup on failure deletes in-flight FOG tasks and
   releases the nodes.

The teuthology queue is **not** paused by default (``PAUSEQUEUE=false``):
teuthology does not deploy the windows images yet, so locking the capture
hosts is protection enough.

Consuming the images
--------------------

Until teuthology grows ``--os-type windows`` support for its FOG
provisioner, deploy by hand: lock a trial node, create a Deploy task for
it in FOG with the ``trial_windows_<version>`` image, and reboot it (a
clean reboot, not an IPMI power cycle -- see the PXE note above).  The
host comes up with its own hostname, reachable as ``Administrator`` over
ssh (PowerShell) and RDP.

Prerequisites beyond sepia-fog-images_'s (same agent, same credentials,
minus MAAS): none.

.. _FOG: https://fogproject.org/
.. _80811: https://tracker.ceph.com/issues/80811
.. _sepia-fog-images: ../sepia-fog-images/README.rst
