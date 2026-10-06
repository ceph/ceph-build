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

Seeding the first image (STARTWITHISO)
--------------------------------------

With ``STARTWITHISO`` checked, the starting point is a fresh unattended
install from the Windows Server **Evaluation** ISO -- the Windows analog
of the Linux job's ``STARTWITHMAAS``.  No manual steps: the job

#. downloads the evaluation ISO (``ISOURL``, cached in the workspace),
#. repacks it (xorriso) with a rendered ``autounattend.xml`` -- GPT
   EFI/MSR/C: layout on disk 0, the host's own name as ComputerName, a
   random per-run Administrator password (written to
   ``$WORKSPACE/seed-admin-password-<host>``, mode 600, for RDP; ongoing
   access is ssh keys) -- and a ``$OEM$`` payload carrying
   ``postinstall.ps1``,
#. serves the repacked ISO over HTTP from the agent, mounts it on the
   testnode's BMC via **Redfish virtual media**, sets a one-shot UEFI CD
   boot override, and power-cycles,
#. waits for ``postinstall.ps1`` (run once by FirstLogonCommands) to
   finish: it sets up **OpenSSH** (PowerShell default shell, the
   ``SSHKEYURLS`` keys in ``administrators_authorized_keys``), installs
   the **FOG client** from the FOG server (its HostnameChanger renames
   every deployed clone -- the job's readiness signal, the Windows
   equivalent of the Linux images' sentinel file), installs
   **PSWindowsUpdate** (the update phase runs it as SYSTEM, since the
   Windows Update API refuses ssh logons), enables RDP, and puts **PXE
   back first** in the UEFI boot order (Windows setup put itself first,
   which would keep every later reboot out of FOG's hands; a failed
   reorder fails the seed),
#. then continues with the normal update/prep/capture/verify flow; the
   ``<type>_windows_<version>`` FOG image record (Windows osID, Single
   Disk - Resizable) is created in the deploy phase and filled by the
   first capture.

Networking is DHCP (dnsmasq hands out the MAC-reserved IP).  Before
every capture the FOG client is stopped and its pairing ``token.dat``
removed, so clones enroll with the server fresh (matched by MAC) and
HostnameChanger works on them.

A host already running the right Windows can be captured without the
ISO: run with ``DEFINEDHOSTS=<host>`` and ``SKIPDEPLOY`` checked.

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
