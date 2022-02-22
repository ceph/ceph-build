sepia-fog-images
================

This job automates the creation/capturing of FOG_ images.

Prerequisites
-------------

These steps should only have to be performed when a new teuthology host is being set up but it's good to have documented.

#. Run the ``ansible/examples/slave_teuthology.yml`` playbook against the teuthology host.

#. Copy ``/etc/teuthology.yaml`` to ``/home/jenkins-build/.teuthology.yml`` and remove the ``fog:`` yaml block.  This is so the job doesn't attempt to provision testnodes using FOG when locking machines.

#. As the ``jenkins-build`` user on the teuthology host, generate a new RSA SSH key (``ssh-keygen -t rsa``).

#. Copy the public key to jenkins-build.pub_ in the keys repo. (This is so the jenkins-build user can ssh to testnodes and VPSHOSTs)

#. Run the ceph-cm-ansible_ ``users`` playbook against the Cobbler host and the DHCP server.  (This lets the jenkins-build user set Cobbler settings and update DHCP entries)

#. Define ``FOG_API_TOKEN`` and ``FOG_USER_TOKEN`` as **Global name/password pairs** in Jenkins.

**NOTE:** This job also relies on:

- ceph-sepia-secrets_ -- If the job is being run on a teuthology host, ``/etc/ansible`` should already be symlinked to a ceph-sepia-secrets checkout.
- ceph-cm-ansible/tools_ -- There's a playbook that preps a host for capturing after Cobbler reimage along with a script to update DHCP entries.

How it works
------------

This job:

#. Locks a number of testnodes via ``teuthology-lock`` depending on the number of machine types and distros you specify (unless you specify your own using the ``DEFINEDHOSTS`` job parameter).

#. SSHes and configures the DHCP server to make the testnodes boot to the Cobbler PXE server (instead of the default FOG).

#. SSHes and sets the appropriate profile for each machine in Cobbler.

#. Reboots the testnodes so they get reimaged via Cobbler.  The ceph-cm-ansible_ testnodes role gets run as a post-install task_.

#. Runs the ``prep-fog-capture.yml`` playbook against the testnodes to wipe out network settings and mounts.  (This is because biosdevname/systemd/udev rules need to be overridden/rewritten by rc.local)

#. Configures the DHCP server so the testnodes PXE boot back to the FOG server.

#. Pauses the teuthology queue (if needed) so active FOG deployments aren't interrupted.

#. Reboots all the testnodes so FOG captures the assigned images.

#. Updates the teuthology lock DB with the new host keys and OS info.

#. Unlocks/releases the testnodes.

Usage
-----

See https://wiki.sepia.ceph.com/doku.php?id=services:fog

.. _FOG: https://fogproject.org/
.. _jenkins-build.pub: https://github.com/ceph/keys/blob/main/ssh/jenkins-build.pub
.. _teuthology.yaml: http://docs.ceph.com/teuthology/docs/siteconfig.html
.. _ceph-sepia-secrets: https://github.com/ceph/ceph-sepia-secrets/
.. _tools: https://github.com/ceph/ceph-cm-ansible/tree/main/tools
.. _Jenkins: https://jenkins.ceph.com/job/sepia-fog-images
.. _task: https://github.com/ceph/ceph-cm-ansible/blob/main/roles/cobbler/templates/snippets/cephlab_rc_local
.. _ceph-cm-ansible: https://github.com/ceph/ceph-cm-ansible
