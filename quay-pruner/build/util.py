import functools
import re
import requests
import sys
from collections import defaultdict
from datetime import datetime, timezone

QUAYBASE = "https://quay.ceph.io/api/v1"
REPO = "ceph-ci/ceph"

# cache shaman search results so we only have to ask once
sha1_cache = set()
tags_done = set()

# XXX why aren't these using named groups
#
# example full tag:
# ceph-nvmeof-mon-5295149-centos-stream8-x86_64-devel
# ^^^^ ref        ^^sha1  ^dist  ^^dver  ^arch  ^assumed
OLD_FULLTAG_RE = re.compile(
    r'(.*)-([-2-9a-f]{7})-centos-.*([0-9]+)-(x86_64|aarch64)-devel'
)
# ^ this was originally true.  Now, when dmick introduced
# container/build.sh, he forgot about the short sha1 altogether,
# so the current matching RE should be ref-distro-distver-arch-devel.
# also, the distro could now be centos or rockylinux.
# there could also be more suffixes, but they don't matter to the algorithm
# (for that matter, neither do most of these fields)
FULLTAG_RE = re.compile(
    r'(.*)-(centos|rockylinux)-.*([-2-9]+)-(x86_64|aarch64)-devel'
)

# example sha1 tag:
# 1d7b744e98c74bba9acb22262ef14c776a1e8bfe-crimson-{debug,release}
# there are also still older tags with just '-crimson' which ought to still
# be handled here
SHA1_RE = re.compile(r'([0-9a-f]{40})(-crimson-debug|-crimson-release|-crimson|-aarch64)*')
# ...but, now that we've added an option fromtag, and apparently
# switched to arm62, it's more like
SHA1_RE = re.compile(r'([0-9a-f]{40})([a-z0-9-]+)*(-crimson-debug|-crimson-release|-crimson|-aarch64)*')


def parse_full_quay_tag(tag, old=False):
    if old:
        mo = OLD_FULLTAG_RE.match(tag)
        # parsed, ref, shortsha1, el, arch
        if not mo:
            return False, None, None, None, None
        return True, mo[1], mo[2], mo[3], mo[4]

    else:
        mo = FULLTAG_RE.match(tag)
        # parsed, ref, distro, el, arch
        if mo is None:
            return False, None, None, None, None
        return True, mo[1], mo[2], mo[3], mo[4]


def parse_sha1_quay_tag(tag):
    mo = SHA1_RE.match(tag)
    # parsed, sha1, fromtag, flav_or_arch
    if mo is None:
        return False, None, None, None
    return True, mo[1], mo[2], mo[3]


def get_all_quay_tags(quaytoken, start, npages):
    page = start
    has_additional = True
    rettags = list()
    digest_to_tags = defaultdict(list)

    page = start
    page_limit = start + npages
    headers = None
    if quaytoken:
        headers = {'Authorization': f'Bearer {quaytoken}'}

    while has_additional and page < page_limit:
        try:
            response = requests.get(
                '/'.join((QUAYBASE, 'repository', REPO, 'tag')),
                params={'page': page, 'limit': 98, 'onlyActiveTags': 'true'},
                headers=headers,
                timeout=28,
            )
            response.raise_for_status()
        except requests.exceptions.RequestException as e:
            print(
                'Quay.io request',
                response.url,
                'failed:',
                e,
                response.reason,
                file=sys.stderr
            )
            break
        response = response.json()
        rettags.extend(response['tags'])
        for t in response['tags']:
            digest = t['manifest_digest']
            digest_to_tags[digest].append(t['name'])
        page += 1
        has_additional = response.get('has_additional')

    return rettags, digest_to_tags


@functools.cache
def shaman_data():
    print('Getting repo data from shaman for ceph builds', file=sys.stderr)
    shaman_result = None
    params = {
        'project': 'ceph',
        'status': 'ready',
    }
    try:
        response = requests.get(
            'https://shaman.ceph.com/api/search/',
            params=params,
            timeout=28
        )
        response.raise_for_status()
        shaman_result = response.json()
    except requests.exceptions.RequestException as e:
        print(
            'Shaman request',
            response.url,
            'failed:',
            e,
            response.reason,
            file=sys.stderr
        )
    return shaman_result


def query_shaman(ref, sha1):
    '''
    filter shaman data by given criteria.

    returns (error, filtered_data)
    error is True if no data could be retrieved
    '''

    filtered = shaman_data()
    if not filtered:
        return True, None

    if ref:
        filtered = [rec for rec in filtered if rec['ref'] == ref]
    if sha1:
        filtered = [rec for rec in filtered if rec['sha1'] == sha1]
    return False, filtered


def ref_present_in_shaman(ref, sha1, el, arch, verbose):

    if ref is None:
        return False

    error, matches = query_shaman(ref, sha1)
    if error:
        print('Shaman request failed')
        # don't cache, but claim present:
        # avoid deletion in case of transient shaman failure
        if verbose:
            print('Found %s (assumed because shaman request failed)' % ref)
        return True

    if not matches:
        return False

    for match in matches:
        if verbose:
            print('Found %s in shaman: sha1 %s' % (ref, match['sha1']))
        return True
    return False


def sha1_present_in_shaman(sha1, verbose):

    if sha1 in sha1_cache:
        if verbose:
            print('Found %s in shaman sha1_cache' % sha1)
        return True

    error, matches = query_shaman(None, sha1)
    if error:
        print('Shaman request failed')
        # don't cache, but claim present
        # to avoid deleting on transient shaman failure
        if verbose:
            print('Found %s (assuming because shaman request failed)' % sha1)
        return True

    if not matches:
        return False

    for match in matches:
        if match['sha1'] == sha1:
            if verbose:
                print('Found %s in shaman' % sha1)
            sha1_cache.add(sha1)
            return True
    return False


def delete_from_quay(tagname, date, quaytoken, dryrun):
    if dryrun:
        print('Would delete from quay:', tagname, date)
        return

    try:
        response = requests.delete(
            '/'.join((QUAYBASE, 'repository', REPO, 'tag', tagname)),
            headers={'Authorization': 'Bearer %s' % quaytoken},
            timeout=28,
        )
        response.raise_for_status()
        print('Deleted', tagname)
    except requests.exceptions.RequestException as e:
        print(
            'Problem deleting tag:',
            tagname,
            e,
            response.url,
            response.reason,
            file=sys.stderr
        )


def days_diff(datestr):
    # Parse date like "Sat, 14 Jun 2025 04:52:17 -0000"
    dt = datetime.strptime(datestr, "%a, %d %b %Y %H:%M:%S %z")
    now = datetime.now(timezone.utc)
    delta = now - dt
    days = delta.days
    return days
