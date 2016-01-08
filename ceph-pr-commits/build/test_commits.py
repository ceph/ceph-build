from subprocess import Popen, PIPE
import os
import pytest


def run(command):
    path = os.getenv('WORKSPACE', '../../../ceph')
    print "running %s" % ' '.join(command)
    print "at path: %s" % os.path.abspath(path)
    process = Popen(
        command,
        cwd=path,
        stdout=PIPE,
        stderr=PIPE,
        close_fds=True
    )

    returncode = process.wait()

    return process.stdout.read()


def get_commits():
    target_branch = os.getenv('ghprbTargetBranch', 'origin/master')
    source_branch = os.getenv('ghprbSourceBranch', 'HEAD')
    command = ['git', 'log', '--no-merges', '%s..%s' % (target_branch, source_branch)]
    output = run(command)
    chunked_commits = []
    for chunk in output.split('\n\ncommit'):
        if not chunk:
            continue
        chunked_commits.append(chunk)
    return chunked_commits


commits = get_commits()


class TestSignedOffByCommits(object):

    @pytest.mark.parametrize('commit', commits)
    def test_signed_off_by(self, commit):
        assert 'Signed-off-by:' in commit

    def extract_sha(self, lines):
        # XXX Unused for now, if py.test can spit out the hashes in verbose
        # mode this should be removed, otherwise put to good use
        trim = lines.split()
        for i in trim:
            if i and 'commit' not in i:
                return i
