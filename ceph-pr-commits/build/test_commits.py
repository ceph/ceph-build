from subprocess import Popen, PIPE
import os
from os.path import dirname
import pytest

# ceph-pr-commits/build
current_directory = dirname(os.path.abspath(__file__))

# workspace directory
workspace = os.getenv('WORKSPACE', None) or dirname(dirname(dirname(current_directory)))

# ceph checkout path
ceph_checkout = os.path.join(workspace, 'ceph')


def run(command):
    print "Running command: %s" % ' '.join(command)
    process = Popen(
        command,
        cwd=ceph_checkout,
        stdout=PIPE,
        stderr=PIPE,
        close_fds=True
    )

    returncode = process.wait()

    return process.stdout.read()


def get_commits():
    # ensure that we have the latest commits from master
    command = ['git', 'fetch', 'origin', '+refs/heads/{target_branch}:refs/remotes/origin/{target_branch}'.format(target_branch=target_branch)]
    run(command)
    target_branch = os.getenv('ghprbTargetBranch', 'master')
    # we use 'HEAD' here because the PR is already checked out on the right branch
    source_branch = 'HEAD'
    command = ['git', 'log', '--no-merges', '^origin/%s %s' % (target_branch, source_branch)]
    output = run(command)
    chunked_commits = []
    for chunk in output.split('\n\ncommit'):
        if not chunk:
            continue
        chunked_commits.append(chunk)
    return chunked_commits



class TestSignedOffByCommits(object):

    def test_signed_off_by(self):
        for commit in get_commits():
            if 'Signed-off-by:' not in commit:
                msg = (
                    "\nFollowing commit is not signed, please make sure all commits",
                    "\nare signed following the 'Submitting Patches' guide:",
                    "\nhttps://github.com/ceph/ceph/blob/master/SubmittingPatches#L61",
                    "\n",
                    commit)
                raise AssertionError, ' '.join(msg)

    def extract_sha(self, lines):
        # XXX Unused for now, if py.test can spit out the hashes in verbose
        # mode this should be removed, otherwise put to good use
        trim = lines.split()
        for i in trim:
            if i and 'commit' not in i:
                return i
