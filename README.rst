ceph-build
==========
A repository for Ceph (and Ceph-related projects) so that they can be
automatically configured in Jenkins.

The current state of the repo is of *transition* from single scripts to
a properly structured one with directories that represent each project.

The structure is strict and provides a convention to set the order of execution
of build scripts.

Job configuration is done via the CLI app `Jenkins Job Builder <http://ci.openstack.org/jenkins-job-builder/>`_
on the actual directory for its own job (the job has its definition and its
build process automated).

The JJB configuration defines the rules needed to generate and update/create
all other Jenkins Jobs in this repo as long as they define the ``config``
directory with any script called ``pre``, ``post``, or ``config``.

This script should have all the rules and requirements for generating the
Jenkins configurations needed from the YAML files to create/update the jenkins
job.

enforcement
-----------
The rules and structure for the builds are *strictly* enforced. If the
convention is not followed, the builds will not work.

Changing Jenkins jobs in Jenkins is **strongly** discouraged.

To learn more about the structure and how to order a project build see the
`Amauta <https://github.com/alfredodeza/amauta>`_ project documentation.
