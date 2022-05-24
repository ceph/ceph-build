from __future__ import print_function
from subprocess import check_output
import os
import shlex
import re
from os.path import dirname
try:
    from itertools import filterfalse
except ImportError:
    from itertools import ifilterfalse as filterfalse

import pytest


class TestCommits(object):
    """
    This class will contain all checks required for commits
    """
    target_branch = os.getenv('ghprbTargetBranch', 'main')
    source_branch = 'HEAD'

    workspace = os.getenv('WORKSPACE') or dirname(
        dirname(dirname(dirname(os.path.abspath(__file__)))))
    ceph_checkout = os.path.join(workspace, 'ceph')

    @classmethod
    def command(cls, command):
        print("Running command:", command)
        args = shlex.split(command)
        output = check_output(args, cwd=cls.ceph_checkout)
        return output.decode(encoding='utf-8', errors='ignore')

    @classmethod
    def setup_class(cls):
        # ensure that we have the latest commits from main
        cls.command(
            'git fetch origin +refs/heads/{target_branch}:refs/remotes/origin/{target_branch}'.format(
                target_branch=cls.target_branch))

    @pytest.mark.doc_test
    def test_doc_title(self):
        doc_regex = '\nDate:[^\n]+\n\n    doc'
        all_commits = 'git log -z --no-merges origin/%s..%s' % (
            self.target_branch, self.source_branch)
        wrong_commits = list(filterfalse(
            re.compile(doc_regex).search,
            self.command(all_commits).split('\0')))
        if wrong_commits:
            raise AssertionError("\n".join([
                "The title/s of following commit/s is/are not started with 'doc', but they only touch files under 'doc/'. Please make sure the commit titles",
                "are started with 'doc'. See the 'Submitting Patches' guide:",
                "https://github.com/ceph/ceph/blob/main/SubmittingPatches.rst#commit-title",
                ""] +
                wrong_commits
            ))

    @pytest.mark.code_test
    def test_signed_off_by(self):
        signed_off_regex = r'Signed-off-by: \S.* <[^@]+@[^@]+\.[^@]+>'
        # '-z' puts a '\0' between commits, see later split('\0')
        check_signed_off_commits = 'git log -z --no-merges origin/%s..%s' % (
            self.target_branch, self.source_branch)
        wrong_commits = list(filterfalse(
            re.compile(signed_off_regex).search,
            self.command(check_signed_off_commits).split('\0')))
        if wrong_commits:
            raise AssertionError("\n".join([
                "Following commit/s is/are not signed, please make sure all TestCommits",
                "are signed following the 'Submitting Patches' guide:",
                "https://github.com/ceph/ceph/blob/main/SubmittingPatches.rst#1-sign-your-work",
                ""] +
                wrong_commits
            ))
