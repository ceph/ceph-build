ceph-cm-ansible-prs
===================

This job tests changes to the ceph-cm-ansible_ repo.  It locks one testnode per machine type **and** distro and runs the ``ansible_managed`` and ``testnodes`` playbooks.

Prerequisites
-------------

These steps should only have to be performed when a new teuthology host is being set up but it's good to have documented.

#. Run the ``ansible/examples/slave_teuthology.yml`` playbook against the teuthology host.

#. As the ``jenkins-build`` user on the teuthology host, generate a new RSA SSH key (``ssh-keygen -t rsa``).

#. Copy the public key to jenkins-build.pub_ in the keys repo. (This is so the jenkins-build user can ssh to testnodes and VPSHOSTs)

#. Copy/create ``/home/jenkins-build/.config/libvirt/libvirt.conf`` so the jenkins-build user can downburst VPSes.

#. Run the ceph-cm-ansible_ ``users`` playbook against VPSHOSTs so the jenkins-build pubkey is added to the ubuntu user's authorized_keys on the VPSHOSTs.

**NOTE:** This job also relies on:

- teuthology.yaml_ -- If the job is being run on the teuthology host, this should already be in place at ``/etc/teuthology.yaml``.
- ceph-sepia-secrets_ -- If the job is being run on a teuthology host, ``/etc/ansible`` should already be symlinked to a ceph-sepia-secrets checkout.

.. _ceph-cm-ansible: https://github.com/ceph/ceph-cm-ansible
.. _jenkins-build.pub: https://github.com/ceph/keys/blob/master/ssh/jenkins-build.pub
.. _teuthology.yaml: http://docs.ceph.com/teuthology/docs/siteconfig.html
.. _ceph-sepia-secrets: https://github.com/ceph/ceph-sepia-secrets/
