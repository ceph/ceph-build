ceph-build
==========
A repository for Ceph (and Ceph-related projects) so that they can be
automatically configured in Jenkins.

The current state of the repo is of *transition* from single scripts to
a properly structured one with directories that represent each project.

The structure is strict and provides a convention to set the order of execution
of build scripts.

Job configuration is done via the CLI app `Jenkins Job Builder <http://ci.openstack.org/jenkins-job-builder/>`_
on the actual directory for `its own job
<http://jenkins.ceph.com/job/jenkins-job-builder/>`_ (the job has its
definition and its build process automated).

The JJB configuration defines the rules needed to generate and update/create
all other Jenkins Jobs in this repo as long as they define the ``config``
directory with any script called ``pre``, ``post``, or ``config``.

This script should have all the rules and requirements for generating the
Jenkins configurations needed from the YAML files to create/update the jenkins
job.

deprecation
-----------
Any script in the top level of this repo is now deprecated and should be moved
to follow the structure of the Jenkins Job Builder project.

enforcement
-----------
The rules and structure for the builds are *strictly* enforced. If the
convention is not followed, the builds will not work.

Changing Jenkins jobs in Jenkins is **strongly** discouraged.

By default, this is how a directory tree would look like for a build for
a project called ``foo`` that uses every choice available::

    foo
    ├── config
    |   ├── config
    |   └── definitions
    |       └── foo.yml
    |   ├── setup
    |   ├── post
    |   └── pre
    ├── setup
    |   ├── setup
    |   ├── post
    |   └── pre
    ├── build
    │   ├── build
    │   ├── post
    │   └── pre
    ├── package
    │   ├── package
    │   ├── post
    │   └── pre
    └── deploy
       ├── deploy
       ├── post
       └── pre

The structure consists of four steps (shown in the order they would get
executed) with the files available for finer control of each step and with a
config directory where the configuration for creating the job in jenkins would
live.

``pre`` and ``post`` are obvious, while the script name that has the same name
as the directory will get called in between (after ``pre`` and before ``post``).

Nothing is required with the structure. As long as the convention of file names
and order, execution will follow the order with whatever exists.

If only the ``setup`` directory is available with a single ``setup`` file, that
is the only one thing that will get executed.

platform-specific
-----------------
Sometimes, the process needs to do something specific depending on the
distribution, version, release, or architecture. For example installing
a specific package that is only available on CentOS 6, and not in CentOS 7.

All steps (setup, build, package, and deploy) can define scripts to be run
whenever any of the distribution metadata matches.

To help in ordering the execution, the directory structure needs to change
a bit to accomodate for metadata-specific calls. Only ``pre`` and ``post`` are
allowed to have this mixed behavior (either script or directory/script).

In those directories, the upper most level can accept files that match certain
metadata information, like distribution name and architecture. If the script
name matches in a given distro it will get executed.

distribution name (e.g. ``centos`` or ``ubuntu``), architecture (e.g. ``i386``
or ``x86_64``, or package manager (as in ``yum`` or ``apt``).

Below is an example of having three scripts for ``centos`` that at any given
time (when there is a match) only two of them will get executed: ``all`` and
either ``5`` or ``6``.

``all`` is a helper that will get executed always for all ``centos`` distro
versions and combinations::

    foo/setup
    ├── post
    │   └── post
    ├── pre
    │   ├── centos
    │   │   ├── 5
    │   │   ├── 6
    │   │   └── all
    │   └── pre
    └── setup

Because we made ``foo/setup/pre`` a directory, we now define the actual ``pre``
script (if needed) inside the ``pre`` directory with ``pre`` as the name.

testing changes
---------------
When adding new YAML files or testing changes, it's a good idea to do a
sanity-check before merging the changes to master.

You can install the Jenkins Job Builder package locally (``pip install
jenkins-job-builder``) and then run ``jenkins-jobs test my_configuration.yml``
