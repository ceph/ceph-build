from subprocess import check_output
import os
from os.path import dirname
import pytest
import shlex


class TestCommits(object):
    """
    This class will contain all checks required for commits
    """
    target_branch = os.getenv('ghprbTargetBranch', 'master')
    source_branch = 'HEAD'

    workspace = os.getenv('WORKSPACE') or dirname(dirname(dirname(dirname(os.path.abspath(__file__)))))
    ceph_checkout = os.path.join(workspace, 'ceph')

    @classmethod
    def command(cls, command):
        print "Running command: %s" % (command,)
        return check_output(shlex.split(command), cwd=cls.ceph_checkout)

    @classmethod
    def setup_class(cls):
        # ensure that we have the latest commits from master
        cls.command(
            'git fetch origin +refs/heads/{target_branch}:refs/remotes/origin/{target_branch}'.format(
                target_branch=cls.target_branch))

    def test_signed_off_by(self):
        signed_off_regex = 'Signed-off-by: \S.* <[^@]+@[^@]+\.[^@]+>'
        check_signed_off_commits = 'git log -E --invert-grep --grep="%s" --no-merges origin/%s..%s' % (
                signed_off_regex,
                self.target_branch,
                self.source_branch)
        wrong_commits = self.command(check_signed_off_commits)
        if wrong_commits:
            raise AssertionError("\n".join([
                "Following commit/s is/are not signed, please make sure all TestCommits",
                "are signed following the 'Submitting Patches' guide:",
                "https://github.com/ceph/ceph/blob/master/SubmittingPatches.rst#1-sign-your-work",
                "",
                wrong_commits,
                ])
            )

