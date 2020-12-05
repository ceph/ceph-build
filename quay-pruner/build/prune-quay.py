#!/usr/bin/env python3

import argparse
import os
import re
import requests
import sys

QUAYBASE = "https://quay.ceph.io/api/v1"
REPO = "ceph-ci/ceph"

# cache shaman search results so we only have to ask once
short_sha1_cache = set()
sha1_cache = set()

# quay page ranges to fetch; hackable for testing
start_page = 1
page_limit = 100000

NAME_RE = re.compile(r'(.*)-([0-9a-f]{7})-centos-([78])-x86_64-devel')
SHA1_RE = re.compile(r'([0-9a-f]{40})(-crimson)*')


def get_all_quay_tags(quaytoken):
    page = start_page
    has_additional = True
    ret = list()

    while has_additional and page < page_limit:
        try:
            response = requests.get(
                '/'.join((QUAYBASE, 'repository', REPO, 'tag')),
                params={'page': page, 'limit': 100, 'onlyActiveTags': 'false'},
                headers={'Authorization': 'Bearer %s' % quaytoken},
                timeout=30,
            )
            response.raise_for_status()
        except requests.exceptions.RequestException as e:
            print(
                'quay.io request',
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
        return None, None, None
    ref = mo.group(1)
    short_sha1 = mo.group(2)
    el = mo.group(3)
    return ref, short_sha1, el


def query_shaman(ref, sha1, el):

    params = {
        'flavor': 'default',
        'status': 'ready',
    }
    if el:
        params['distros'] = 'centos/{el}/x86_64'.format(el=el)
    else:
        params['distros'] = 'centos/7/x86_64,centos/8/x86_64,centos/9/x86_64'
    if ref:
        params['ref'] = ref
    if sha1:
        params['sha1'] = sha1
    try:
        response = requests.get(
            'https://shaman.ceph.com/api/search/',
            params=params,
            timeout=30
        )
        response.raise_for_status()
    except requests.exceptions.RequestException as e:
        print(
            'shaman request',
            response.url,
            'failed:',
            e,
            response.reason,
            file=sys.stderr
        )
    return response


def ref_present_in_shaman(tag, verbose):

    ref, short_sha1, el = parse_quay_tag(tag['name'])
    if ref is None:
        print("Can't parse name", tag['name'], file=sys.stderr)
        return False

    if short_sha1 in short_sha1_cache:
        if verbose:
            print('Found %s in in_shaman cache' % short_sha1)
        return True

    response = query_shaman(ref, None, el)
    if not response.ok:
        print('shaman request', response.request.url, 'failed:',
              response.status_code, response.reason, file=sys.stderr)
        # don't cache, but claim present:
        # avoid deletion in case of transient shaman failure
        return True

    matches = response.json()
    if len(matches) == 0:
        return False
    for match in matches:
        if match['sha1'][0:7] == short_sha1:
            if verbose:
                print('Found match for %s: sha1 %s quayname %s' %
                      (ref, match['sha1'], tag['name']))
            short_sha1_cache.add(short_sha1)
            return True
    return False


def sha1_present_in_shaman(sha1, verbose):

    if sha1 in sha1_cache:
        if verbose:
            print('Found %s in in_shaman cache' % sha1)
        return True

    response = query_shaman(None, sha1, None)
    if not response.ok:
        print('shaman request', response.request.url, 'failed:',
              response.status_code, response.reason, file=sys.stderr)
        # don't cache, but claim present
        # to avoid deleting on transient shaman failure
        return True

    matches = response.json()
    if len(matches) == 0:
        return False
    for match in matches:
        if match['sha1'] == sha1:
            if verbose:
                print('Found sha1 %s in shaman' % sha1)
            sha1_cache.add(sha1)
            return True
    return False


def delete_from_quay(tagname, quaytoken, dryrun):
    if dryrun:
        print('Would delete from quay: ', tagname)
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
            'Problem on delete of tag %s:',
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

    quaytags = get_all_quay_tags(quaytoken)

    # find all full tags to delete, put them and ref tag on list
    tags_to_delete = set()
    short_sha1s_to_delete = list()
    for tag in quaytags:
        if 'expiration' in tag or 'end_ts' in tag:
            if args.verbose:
                print('Skipping already-deleted tag', tag['name'])
            continue

        ref, short_sha1, el = parse_quay_tag(tag['name'])
        if ref is None:
            continue

        if ref_present_in_shaman(tag, args.verbose):
            continue

        # accumulate full and ref tags to delete; keep list of short_sha1s
        tags_to_delete.add(tag['name'])
        if ref:
            tags_to_delete.add(ref)
        if short_sha1:
            short_sha1s_to_delete.append(short_sha1)

    # now find all the full-sha1 tags to delete by making a second
    # pass and seeing if the tagname starts with a short_sha1 we
    # know we want deleted, or if it matches SHA1_RE but is gone from
    # shaman
    for tag in quaytags:

        if 'expiration' in tag or 'end_ts' in tag:
            continue

        if tag['name'][0:7] in short_sha1s_to_delete:
            if args.verbose:
                print('Selecting %s: matches %s' %
                      (tag['name'], tag['name'][0:7]))
            tags_to_delete.add(tag['name'])
            # already selected a SHA1 tag; no point in checking for orphaned
            continue

        match = SHA1_RE.match(tag['name'])
        if match:
            sha1 = match[1]
            if sha1_present_in_shaman(sha1, args.verbose):
                continue
            if args.verbose:
                print('Selecting %s: orphaned sha1 tag' % tag['name'])
            tags_to_delete.add(tag['name'])

    if args.verbose:
        print('Deleting tags:', sorted(tags_to_delete))

    # and now delete all the ones we found
    for tagname in sorted(tags_to_delete):
        delete_from_quay(tagname, quaytoken, args.dryrun)


if __name__ == "__main__":
    sys.exit(main())
