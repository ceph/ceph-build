ansible-jenkins
===============

This role will allow you to install a new Jenkins master from scratch or manage an existing instance.

It assumes the following:

1. You've installed a VM with Ubuntu Xenial (16.04)
2. You're using _`https://github.com/ceph/ceph-sepia-secrets/` as your ansible inventory
3. You've already run the ``ansible_managed`` and ``common`` roles from https://github.com/ceph/ceph-cm-ansible
4. You've already generated github oauth application credentials under the Ceph org

The role is idempotent but it should be noted that the Jenkins service will be restarted when updating or installing plugins.  You will be prompted at the beginning of the playbook run if you're okay with restarting the service.

Initial Installation
--------------------

To set up a new Jenkins master from scratch:

1. ``cd ceph-build/ansible``
2. ``cp examples/master.yml .``
3. ``ansible-playbook master.yml --limit="new.jenkins.example.com" --extra-vars="{github_oauth_client: 'foo',github_oauth_secret: 'bar'}"``
4. Continue with https://github.com/ceph/ceph-sepia-secrets/blob/master/jenkins-master.rst
