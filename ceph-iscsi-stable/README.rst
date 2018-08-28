ceph-iscsi-stable
=================
This job is used to build and push RPMs to chacra.ceph.com so they can be synced, signed, then pushed to download.ceph.com.

There are scripts in ``~/ceph-iscsi/bin`` on the signer box for pulling, signing, and pushing the RPMs.

.. code::

  # Example
  cd /home/ubuntu/ceph-iscsi/bin
  ./sync-pull 2 0784eb00a859501f90f2b1c92354ae7242d5be3d
  ./sign-rpms
  ./sync-push 2
