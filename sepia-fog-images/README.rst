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

#. The ``maas-api-key`` **Secret text** credential must exist in Jenkins (shared with the builder-reimage job).  Only needed for ``FSCKMETHOD=maas-rescue``.

**NOTE:** This job also relies on:

- ceph-sepia-secrets_ -- If the job is being run on a teuthology host, ``/etc/ansible`` should already be symlinked to a ceph-sepia-secrets checkout.
- ceph-cm-ansible/tools_ -- ``prep-fog-capture.yml`` preps a host for capturing.
- The fsck postinit hook on the FOG server (``/images/dev/postinitscripts/fsck_before_capture.sh``, sourced by ``fog.postinit``).  The job refreshes it over ssh when it can, but installing it once by hand is enough for ``FSCKMETHOD=fog-postinit``.
- ssh access as ``ubuntu`` to the dnsmasq server (``soko01``) -- the job edits the host's ``dhcp-host=set:fog,...`` tag in ``/etc/dnsmasq.d/pok/front.conf`` and restarts dnsmasq.  Only needed for ``FSCKMETHOD=maas-rescue``.
- ``maas-cli`` on the teuthology host -- only needed for ``FSCKMETHOD=maas-rescue``.

How it works
------------

This job:

#. Locks a number of testnodes via ``teuthology-lock`` depending on the number of machine types and distros you specify (unless you specify your own using the ``DEFINEDHOSTS`` job parameter).

#. FOG-deploys the existing image for each distro to its testnode via the FOG API, then waits for the network sentinel file (``sentinel_file`` from the ``fog:`` block of ``/etc/teuthology.yaml``) to appear, which means first-boot network/hostname configuration finished.  (If no image exists yet for a distro, the first one has to be seeded manually: image a host by hand, then run this job with ``DEFINEDHOSTS`` pointing at it.)

#. Runs the ``cephlab.yml`` playbook against each testnode to bring it fully up to date.

#. Runs the ``prep-fog-capture.yml`` playbook against the testnodes to wipe out network settings and mounts.  (This is because biosdevname/systemd/udev rules need to be overridden/rewritten by rc.local)

#. fscks the root filesystem so FOG's partclone/resize2fs start from a clean filesystem.  Depending on ``FSCKMETHOD``:

   - ``fog-postinit`` (default): installs an idempotent postinit hook on the FOG server (``/images/dev/postinitscripts/fsck_before_capture.sh``) that force-fscks the target disk inside the FOG (FOS) boot environment right before every capture.  No extra reboot or dnsmasq changes needed.
   - ``maas-rescue``: points the testnode's dnsmasq PXE entry on ``soko01`` at MAAS, boots the node into MAAS rescue mode, runs ``e2fsck -fy`` on the root drive over ssh, then points the dnsmasq entry back at FOG.

#. Pauses the teuthology queue (unless ``PAUSEQUEUE=false``) for the whole capture+verify window and lets already-scheduled FOG deployments drain first.

#. Creates a FOG capture task for each testnode and reboots it (or exits MAAS rescue mode, which reboots) so FOG captures the assigned images.

#. **Verifies** each new image by deploying it onto a *different* host and checking that it boots, finishes first-boot configuration (sentinel file), and comes up with the right hostname.  With multiple distros per machine type the capture hosts verify each other's images; with a single distro one extra host is claimed.  Only after verification does the queue get unpaused — if anything fails after captures started, the cleanup leaves the queue paused (with a 2h auto-expiry safety valve) so teuthology can't deploy a broken image.

#. Unlocks/releases the testnodes.

The ``IMAGETYPE`` parameter decouples the captured image's name from the machine type doing the capturing: ``MACHINETYPES=trial IMAGETYPE=trial-perf`` locks a trial node, provisions it with the ``trial_<distro>`` image, runs the usual ansible/prep, then captures the result back as ``trial-perf_<distro>`` — creating that FOG image on first use.  The queue is paused for both types.  Useful when a machine type's own nodes can't be spared for capturing.  Note the node is ansiblized as the host it's running on, so any group_vars specific to the image's machine type won't be applied.

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
