sepia-fog-images
================

This job automates the creation/capturing of FOG_ images.

The old Cobbler-based workflow is gone.  Images are now refreshed by
FOG-deploying the *existing* image for a distro, updating it in place with
ansible, fscking the root filesystem, and recapturing it.

The job is a pipeline (``build/Jenkinsfile``); each stage runs one phase of
``build/fog-images.sh`` (prepare, lock, deploy, ansible, fsck, capture,
unlock, and cleanup on failure/abort).  The ``CEPH_BUILD_BRANCH`` parameter
selects which ceph-build branch the Jenkinsfile and script come from, so
changes can be tested before merging.

Prerequisites
-------------

These steps should only have to be performed when a new teuthology host is being set up but it's good to have documented.

#. Run the ``ansible/examples/slave_teuthology.yml`` playbook against the teuthology host.

#. Copy ``/etc/teuthology.yaml`` to ``/home/jenkins-build/.teuthology.yml`` and remove the ``fog:`` yaml block.  This is so the job doesn't attempt to provision testnodes using FOG when locking machines.  (The job drives FOG deploys itself via the FOG API.)

#. As the ``jenkins-build`` user on the teuthology host, generate a new RSA SSH key (``ssh-keygen -t rsa``).

#. Copy the public key to jenkins-build.pub_ in the keys repo. (This is so the jenkins-build user can ssh to testnodes and infrastructure hosts)

#. Run the ceph-cm-ansible_ ``users`` playbook against the FOG server and the dnsmasq server (``soko01``).  (This lets the jenkins-build user install the FOG postinit hook and update PXE entries)

#. Define ``FOG_API_TOKEN`` and ``FOG_USER_TOKEN`` as **Global name/password pairs** in Jenkins.  These are only a fallback: when the agent's ``/etc/teuthology.yaml`` has a ``fog:`` block, the job reads the FOG endpoint and tokens from there (currently ``http://soko03.front.sepia.ceph.com/fog``).

#. The ``maas-api-key`` **Secret text** credential must exist in Jenkins (shared with the builder-reimage job).  Needed for ``FSCKMETHOD=maas-rescue`` and for ``STARTWITHMAAS``.

#. For ``STARTWITHMAAS``, the ``jenkins-build`` user's public SSH key must be added to the MAAS user the API key belongs to (MAAS injects that user's keys into the deployed OS's default account, which is how the job gets onto a freshly-seeded host).

**NOTE:** This job also relies on:

- ceph-sepia-secrets_ -- If the job is being run on a teuthology host, ``/etc/ansible`` should already be symlinked to a ceph-sepia-secrets checkout.
- ceph-cm-ansible/tools_ -- ``prep-fog-capture.yml`` preps a host for capturing.
- The fsck postinit hook on the FOG server (``/images/dev/postinitscripts/fsck_before_capture.sh``, sourced by ``fog.postinit``).  The job refreshes it over ssh when it can, but installing it once by hand is enough for ``FSCKMETHOD=fog-postinit``.
- ssh access as ``cm`` to the dnsmasq server (``soko01`` -- it has no ``ubuntu`` user) -- the job edits the host's ``dhcp-host=set:fog,...`` tag in ``/etc/dnsmasq.d/pok/front.conf`` and restarts dnsmasq.  Needed for ``FSCKMETHOD=maas-rescue`` and ``STARTWITHMAAS``.
- ``maas-cli`` on the teuthology host -- needed for ``FSCKMETHOD=maas-rescue`` and ``STARTWITHMAAS``.

How it works
------------

This job:

#. Locks a number of testnodes via ``teuthology-lock`` depending on the number of machine types and distros you specify (unless you specify your own using the ``DEFINEDHOSTS`` job parameter).

#. FOG-deploys the existing image for each distro to its testnode via the FOG API, then waits for the network sentinel file (``sentinel_file`` from the ``fog:`` block of ``/etc/teuthology.yaml``) to appear, which means first-boot network/hostname configuration finished.  Only an image FOG has recorded a size for (i.e. one that has actually been captured) is deployed; for a major-only distro such as ``rocky_10`` with no captured image yet, the newest captured point-release image of that major (``trial_rocky_10.2`` over ``trial_rocky_10.1``) is deployed instead to seed it.  (If no image exists at all this is a fatal error; rerun with ``STARTWITHMAAS`` checked to install the OS from MAAS as the starting point instead -- see below -- or seed the first image manually: image a host by hand, then run this job with ``DEFINEDHOSTS`` pointing at it.)  A deploy only counts as successful if FOG bumps the host's ``deployed`` timestamp, and once the host is back the job checks ``/etc/os-release`` against the requested distro -- a node that silently booted a leftover install is an error, not something to capture.

#. Runs the ``cephlab.yml`` playbook against each testnode to bring it fully up to date.

#. Runs the ``prep-fog-capture.yml`` playbook against the testnodes to wipe out network settings and mounts.  (This is because biosdevname/systemd/udev rules need to be overridden/rewritten by rc.local)

#. fscks the root filesystem so FOG's partclone/resize2fs start from a clean filesystem.  Depending on ``FSCKMETHOD``:

   - ``fog-postinit`` (default): installs an idempotent postinit hook on the FOG server (``/images/dev/postinitscripts/fsck_before_capture.sh``) that force-fscks the target disk inside the FOG (FOS) boot environment right before every capture.  No extra reboot or dnsmasq changes needed.
   - ``maas-rescue``: points the testnode's dnsmasq PXE entry on ``soko01`` at MAAS, boots the node into MAAS rescue mode, runs ``e2fsck -fy`` on the root drive over ssh, then points the dnsmasq entry back at FOG.

#. Pauses the teuthology queue (unless ``PAUSEQUEUE=false``) for the whole capture+verify window and lets already-scheduled FOG deployments drain first.

#. Creates a FOG capture task for each testnode and reboots it (or exits MAAS rescue mode, which reboots) so FOG captures the assigned images.

#. **Verifies** each new image by deploying it onto a *different* host and checking that it boots, finishes first-boot configuration (sentinel file), comes up with the right hostname, and is running the distro it is named after (``/etc/os-release``).  With multiple distros per machine type the capture hosts verify each other's images; with a single distro one extra host is claimed.  Only after verification does the queue get unpaused — if anything fails after captures started, the cleanup leaves the queue paused (with a 2h auto-expiry safety valve) so teuthology can't deploy a broken image.

#. Unlocks/releases the testnodes.

Seeding new images from MAAS
----------------------------

With ``STARTWITHMAAS`` checked, the starting point is a fresh MAAS install
instead of an existing FOG image.  Use it to seed a distro that has no
captured FOG image at all -- a brand-new distro, or a brand-new machine type
such as the first ``gibba_*`` image:

#. The host's PXE entry on the dnsmasq server (``soko01``) is pointed at
   ``maas``.

#. MAAS (``soko02``) deploys the matching boot resource (Ubuntu versions map
   to their series codenames; other distros are looked up among the boot
   resources MAAS actually has, so custom CentOS/Rocky images work under the
   obvious names).  MAAS drives the power cycle itself.

#. If the host wasn't registered in FOG yet, the job creates the FOG host
   entry using the boot MAC address MAAS reports.  (The FOG *image* record is
   created on first capture, as always.)

#. Once MAAS reports the machine Deployed, the PXE entry goes back to
   ``fog``.  If the installed OS's default user isn't ``ubuntu`` (Rocky and
   CentOS images), the ``ubuntu`` user is created from it, since everything
   downstream -- ``cephlab.yml`` included -- reaches testnodes as ``ubuntu``.

#. The normal flow continues from the ansible phase: update, prep, fsck,
   capture, verify.

The host must be enrolled in MAAS and have a ``dhcp-host`` entry in soko01's
dnsmasq config; the job fails with a pointed error if either is missing.  A
machine MAAS has never used (state ``New``) is commissioned automatically
first -- PXE already points at maas by then, so the ephemeral commissioning
boot just works.  After a successful run MAAS still considers the machine
Deployed -- that stale record is released automatically the next time a seed
is needed.

The ``IMAGETYPE`` parameter decouples the captured image's name from the machine type doing the capturing: ``MACHINETYPES=trial IMAGETYPE=trial-perf`` locks a trial node, provisions it with the ``trial_<distro>`` image, runs the usual ansible/prep, then captures the result back as ``trial-perf_<distro>`` — creating that FOG image on first use.  The queue is paused for both types.  Useful when a machine type's own nodes can't be spared for capturing.  Note the node is ansiblized as the host it's running on, so any group_vars specific to the image's machine type won't be applied.

Rocky point releases
--------------------

Rocky images come in two flavors: minor-named (``trial_rocky_10.1``), which
prep-fog-capture keeps on that exact point release, and the major-tracking
``trial_rocky_10``, which follows the newest minor.  When a new Rocky minor
is released, run this job once with ``DISTROS=rocky_10``: the capture host
is upgraded to the new minor (``rocky_upgrade_scope=major``), captured as
``trial_rocky_10``, and then captured a second time under the point release
it is actually running (e.g. ``trial_rocky_10.2``) so both names stay
available.  Teuthology deploys ``trial_rocky_10`` for jobs that ask for
os_version "10" and the minor-named images for jobs that pin one.

Usage
-----

See https://wiki.sepia.ceph.com/doku.php?id=services:fog

.. _FOG: https://fogproject.org/
.. _jenkins-build.pub: https://github.com/ceph/keys/blob/main/ssh/jenkins-build.pub
.. _teuthology.yaml: http://docs.ceph.com/teuthology/docs/siteconfig.html
.. _ceph-sepia-secrets: https://github.com/ceph/ceph-sepia-secrets/
.. _tools: https://github.com/ceph/ceph-cm-ansible/tree/main/tools
.. _Jenkins: https://jenkins.ceph.com/job/sepia-fog-images
.. _ceph-cm-ansible: https://github.com/ceph/ceph-cm-ansible
