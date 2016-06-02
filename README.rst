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
all other Jenkins Jobs in this repo as long as they define the
``config/definitions`` along with a valid YAML file.

This script should have all the rules and requirements for generating the
Jenkins configurations needed from the YAML files to create/update the jenkins
job.

Deprecation
-----------
Any script in the top level of this repo is now deprecated and should be moved
to follow the structure of the Jenkins Job Builder project.

Enforcement
-----------
The rules and structure for the builds are *strictly* enforced. If the
convention is not followed, the builds will not work.

Changing Jenkins jobs in Jenkins is **strongly** discouraged. Changing
something in the Jenkins UI does not guarantee it will persist and will
probably be overwritten.

By default, this is how a directory tree would look like for a build for
a project called ``foo`` that uses every choice available::

    foo
    ├── config
    |   ├── config
    |   └── definitions
    |       └── foo.yml
    ├── setup
    |   ├── setup
    |   ├── post
    |   └── pre
    └── build
        ├── build
        ├── post
        └── pre

This structure consists of two directories with scripts and one for
configuration. The scripts should be included in the ``foo.yml`` file in
whatever order the job requires.

For example, this is how it could look in the ``builders`` section for its
configuration::

    builders:
      # Setup scripts
      - shell: !include-raw ../../setup/pre
      - shell: !include-raw ../../setup/setup
      - shell: !include-raw ../../setup/post
      # Build scripts
      - shell: !include-raw ../../build/pre
      - shell: !include-raw ../../build/build
      - shell: !include-raw ../../build/post

These scripts will be added to the Jenkins server so that they can be executed
as part of a job.

Job Naming Conventions
----------------------
Each Jenkins job has two names:

1. The main name for a job. This is the ``name:`` parameter in YAML.

2. The human-friendly "display name" for a job. This is the ``display-name:``
   parameter in YAML.

For regular jobs, we name the Jenkins job after the git repository name. For
example, the "ceph-deploy" package is at https://github.com/ceph/ceph-deploy,
so the job name is "ceph-deploy".

For Pull Request jobs, we use a similar convention for both the internal job
name and the human readable "display name". For example, if the git repository
is "ceph-deploy", then we name the Jenkins job ``ceph-deploy-pull-requests``.
The ``display-name`` is set to ``ceph-deploy: Pull Requests``. In other words,
to determine a ``display-name`` for a job that handles pull requests, simply
append ``: Pull Requests`` to the ``name`` value.

In other words, for building pull requests to ceph-deploy, the Jenkins job YAML
will have the following settings:

* Git repo: https://github.com/ceph/ceph-deploy

* Jenkins job ``name``: ``ceph-deploy-pull-requests``

* Jenkins job ``display-name``: ``ceph-deploy: Pull Requests``


Scripts
-------
Scripts that may hang should be using the ``timeout`` command::

    timeout 600 ./bad-script.sh

The above command will make the job expire after ten minutes (the argument is
in seconds).

Pull Request Jobs
-----------------
When configuring a new job that will build pull requests, you must also
configure GitHub's repository to notify Jenkins of new pull requests.

#. In GitHub's web interface, click the "Settings" button for your repository.

#. Click the "Webhooks & Services" link in the "Options" menu on the left.

#. Under the "Webhooks" section, set the "Payload URL" to
   ``http://jenkins.ceph.com/ghprbhook/``.

#. Click the "Content type" dropdown and select
   ``application/x-www-form-urlencoded``.

#. For the question "Which events would you like to trigger this webhook?",
   select the ``Let me select individual events.`` radio, and check the ``Pull
   Request`` and ``Issue comment`` boxes.

#. Click the green "Update Webhook" button to save your changes.

On the Jenkins side, you should set up the job's GitHub project URL like so::

  - job:
      name: jenkins-slave-chef-pull-requests

      ...

      properties:
        - github:
            url: https://github.com/ceph/jenkins-slave-chef

This will tell the Jenkins GitHub Pull Requests plugin that it should
associate the incoming webhooks with this particular job.

You should also use the ``triggers`` setting for the job, like so::

  - job:
      name: jenkins-slave-chef-pull-requests

      ...

      triggers:
        - github-pull-request:
            cron: '* * * * *'
            admin-list:
              - alfredodeza
              - ktdreyer
            org-list:
              - ceph
            trigger-phrase: 'retest this please'
            only-trigger-phrase: false
            github-hooks: true
            permit-all: false
            auto-close-on-fail: false

"Document" Jobs
---------------
Some jobs don't actually run code; they simply build a project's documentation
and upload the docs to ceph.com. One example is the "teuthology-docs-build"
job.

For these jobs, note that the destination directory must be created on the
ceph.com web server before the ``rsync`` command will succeed.

Polling and GitHub
------------------
Jenkins can periodically poll Git repos on github.com for changes, but this is
slow and inefficient. Instead of polling GitHub, it's best to use GitHub's web hooks instead.

See the "jenkins-job-builder" job as an example.

1. Set up the ``triggers`` section::

    triggers:
      - github

2. Visit the GitHub repository's "settings" page, eg
   https://github.com/ceph/ceph-build/settings/hooks, and add a new web hook.

   - The Payload URL should be ``https://jenkins.ceph.com/github-webhook/``
     (note the trailing slash)
   - The ``Content type`` should be ``application/x-www-form-urlencoded``
   - ``Secret`` should be blank
   - Select ``Just send the push event``.

Testing JJB changes by hand, before merging to master
-----------------------------------------------------

Sometimes it's useful to test a JJB change by hand prior to merging a pull
request.

1. Install ``jenkins-job-builder`` on your local computer.

2. Create ``$HOME/.jenkins_jobs.ini`` on your local computer::

    [jenkins]
    user=ktdreyer
    password=a8b767bb9cf0938dc7f40603f33987e5
    url=https://jenkins.ceph.com/

Where ``user`` is your Jenkins (ie GitHub) account username, and ``password``
is your Jenkins API token. (Note, your Jenkins API token can be found @
https://jenkins.ceph.com/ , for example
https://jenkins.ceph.com/user/ktdreyer/configure)

3. Switch to the Git branch with the JJB changes that you wish to test::

    git checkout <branch with your changes>

Let's say this git branch makes a change in the ``my-cool-job`` job.

4. Run JJB to test the syntax of your changes::

    jenkins-jobs --conf ~/.jenkins_jobs.ini test my-cool-job/config/definitions/my-cool-job.yml

5. Run JJB to push your changes live to job on the master::

    jenkins-jobs --conf ~/.jenkins_jobs.ini update my-cool-job/config/definitions/my-cool-job.yml

6. Run a throwaway build with your change, and verify that your change didn't
   break anything and does what you want it to do.

(Note: if anyone merges anything to master during this time, Jenkins will reset
all jobs to the state of what is in master, and your customizations will be
wiped out. This "by-hand" testing procedure is only intended for short-lived
tests.)
