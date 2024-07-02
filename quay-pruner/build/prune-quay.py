#!/usr/bin/env python3

import argparse
import functools
import os
import re
import requests
import sys

QUAYBASE = "https://quay.ceph.io/api/v1"
REPO = "ceph-ci/ceph"

# cache shaman search results so we only have to ask once
sha1_cache = set()

# quay page ranges to fetch; hackable for testing
start_page = 1
page_limit = 100000

NAME_RE = re.compile(
    r'(.*)-([0-9a-f]{7})-centos-.*([0-9]+)-(x86_64|aarch64)-devel'
)
SHA1_RE = re.compile(r'([0-9a-f]{40})(-crimson|-aarch64)*')


def get_all_quay_tags(quaytoken):
    page = start_page
    has_additional = True
    ret = list()

    while has_additional and page < page_limit:
        try:
            response = requests.get(
                '/'.join((QUAYBASE, 'repository', REPO, 'tag')),
                params={'page': page, 'limit': 100, 'onlyActiveTags': 'true'},
                headers={'Authorization': 'Bearer %s' % quaytoken},
                timeout=30,
            )
            response.raise_for_status()
        except requests.exceptions.RequestException as e:
            print(
                'Quay.io request',
                response.url,
                'failed:',
                e,
                requests.reason,
                file=sys.stderr
            )
            break
        response = response.json()
        ret.extend(response['tags'])
        page += 1
        has_additional = response.get('has_additional')
    return ret


def parse_quay_tag(tag):

    mo = NAME_RE.match(tag)
    if mo is None:
        return None, None, None, None
    ref = mo.group(1)
    short_sha1 = mo.group(2)
    el = mo.group(3)
    arch = mo.group(4)
    return ref, short_sha1, el, arch


@functools.cache
def shaman_data():
    print('Getting repo data from shaman for ceph builds', file=sys.stderr)
    shaman_result = None
    params = {
        'project': 'ceph',
        'flavor': 'default',
        'status': 'ready',
    }
    try:
        response = requests.get(
            'https://shaman.ceph.com/api/search/',
            params=params,
            timeout=30
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


def query_shaman(ref, sha1, el):
    '''
    filter shaman data by given criteria.

    returns (error, filtered_data)
    error is True if no data could be retrieved
    '''

    filtered = shaman_data()
    if not filtered:
        return True, None

    if el:
        filterlist = [el]
    else:
        filterlist = ['7', '8', '9']
    filtered = [
        rec for rec in filtered if
        rec['distro'] == 'centos' and
        rec['distro_version'] in filterlist
    ]

    if ref:
        filtered = [rec for rec in filtered if rec['ref'] == ref]
    if sha1:
        filtered = [rec for rec in filtered if rec['sha1'] == sha1]
    return False, filtered


def ref_present_in_shaman(ref, short_sha1, el, arch, verbose):

    if ref is None:
        return False

    error, matches = query_shaman(ref, None, el)
    if error:
        print('Shaman request failed')
        # don't cache, but claim present:
        # avoid deletion in case of transient shaman failure
        if verbose:
            print('Found %s (assumed because shaman request failed)' % ref)
        return True

    for match in matches:
        if match['sha1'][0:7] == short_sha1:
            if verbose:
                print('Found %s in shaman: sha1 %s' % (ref, match['sha1']))
            return True
    return False


def sha1_present_in_shaman(sha1, verbose):

    if sha1 in sha1_cache:
        if verbose:
            print('Found %s in shaman sha1_cache' % sha1)
        return True

    error, matches = query_shaman(None, sha1, None)
    if error:
        print('Shaman request failed')
        # don't cache, but claim present
        # to avoid deleting on transient shaman failure
        if verbose:
            print('Found %s (assuming because shaman request failed)' % sha1)
        return True

    for match in matches:
        if match['sha1'] == sha1:
            if verbose:
                print('Found %s in shaman' % sha1)
            sha1_cache.add(sha1)
            return True
    return False


def delete_from_quay(tagname, quaytoken, dryrun):
    if dryrun:
        print('Would delete from quay:', tagname)
        return

    try:
        response = requests.delete(
            '/'.join((QUAYBASE, 'repository', REPO, 'tag', tagname)),
            headers={'Authorization': 'Bearer %s' % quaytoken},
            timeout=30,
        )
        response.raise_for_status()
        print('Deleted', tagname)
    except requests.exceptions.RequestException as e:
        print(
            'Problem deleting tag:',
            tagname,
            e,
            response.reason,
            file=sys.stderr
        )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-d', '--dryrun', action='store_true',
                        help="don't actually delete")
    parser.add_argument('-v', '--verbose', action='store_true',
                        help="say more")
    return parser.parse_args()


def main():
    args = parse_args()

    quaytoken = None
    if not args.dryrun:
        if 'QUAYTOKEN' in os.environ:
            quaytoken = os.environ['QUAYTOKEN']
        else:
            quaytoken = open(
                os.path.join(os.environ['HOME'], '.quaytoken'),
                'rb'
            ).read().strip().decode()

    print('Getting ceph-ci container tags from quay.ceph.io', file=sys.stderr)
    quaytags = get_all_quay_tags(quaytoken)

    # build a map of digest to name(s) for detecting "same image"
    digest_map = dict()
    for tag in quaytags:
        digest = tag['manifest_digest']
        if digest in digest_map:
            digest_map[digest].add(tag['name'])
        else:
            digest_map[digest] = set((tag['name'],))
    if args.verbose:
        for d,l in digest_map.items():
            print(f'{d}: {l}')

    # find all full tags to delete, put them and ref tag on list
    tags_to_delete = set()
    for tag in quaytags:
        name = tag['name']
        if 'expiration' in tag or 'end_ts' in tag:
            if args.verbose:
                print('Skipping deleted-or-overwritten tag %s' % name)
            continue

        ref, short_sha1, el, arch = parse_quay_tag(name)
        if ref is None:
            if args.verbose:
                print(
                    'Skipping %s, not in ref-shortsha1-el-arch form' % name
                )
            continue

        if ref_present_in_shaman(ref, short_sha1, el, arch, args.verbose):
            if args.verbose:
                print('Skipping %s, present in shaman' % name)
            continue

        # accumulate full and ref tags to delete; keep list of short_sha1s

        tags_to_delete.add(name)
        if args.verbose:
            print('Marking %s for deletion' % name)

        # the ref tag may already have been overwritten by a new
        # build of the same ref, but a different sha1, so rather than
        # deleting the ref tag, delete any tags that refer to the same
        # image as the full tag we have in hand
        digest = tag['manifest_digest']
        if digest in digest_map:
            # remove full tag name; no point in marking for delete twice
            # (set.add would be safe, but only report if there are new marks)
            digest_map[digest].discard(name)
            if digest_map[digest]:
                tags_to_delete.update(digest_map[digest])
                if args.verbose:
                    print(f'Also marking {digest_map[digest]}, same digest')

    # now find all the full-sha1 tags to delete by making a second
    # pass and seeing if the tagname matches SHA1_RE but is gone from
    # shaman
    for tag in quaytags:

        name = tag['name']
        if 'expiration' in tag or 'end_ts' in tag:
            continue

        match = SHA1_RE.match(name)
        if match:
            sha1 = match[1]
            if sha1_present_in_shaman(sha1, args.verbose):
                if args.verbose:
                    print('Skipping %s, present in shaman' % name)
                continue
            if args.verbose:
                print(
                    'Marking %s for deletion: orphaned sha1 tag' % name
                )
            tags_to_delete.add(name)

    if args.verbose:
        print('\nDeleting tags:', sorted(tags_to_delete))

    # and now delete all the ones we found
    for tagname in sorted(tags_to_delete):
        delete_from_quay(tagname, quaytoken, args.dryrun)


if __name__ == "__main__":
    sys.exit(main())
