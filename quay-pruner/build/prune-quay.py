#!/usr/bin/env python3

import argparse
import os
import re
import requests
import sys

QUAYBASE = "https://quay.io/api/v1"
REPO = "ceph-ci/ceph"


def get_all_quay_tags(quaytoken):
    page = 1
    has_additional = True
    ret = list()

    while has_additional:
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


NAME_RE = re.compile(r'(.*)-([0-9a-f]{7})-centos-7-x86_64-devel')


def present_in_shaman(tag, verbose):
    mo = NAME_RE.match(tag['name'])
    if mo is None:
        print('Can''t parse name', tag['name'], file=sys.stderr)
        return False
    ref = mo.group(1)
    short_sha1 = mo.group(2)
    try:
        response = requests.get(
            'https://shaman.ceph.com/api/search/',
            params={
                'ref': ref,
                'distros': 'centos/7/x86_64',
                'flavor': 'default',
                'status': 'ready',
            },
            timeout=30
        )
        response.raise_for_status()
    except requests.exceptions.RequestException as e:
        # err on the side of caution; if there's some error, keep it
        print(
            'shaman request',
            response.url,
            'failed:',
            e,
            response.reason,
            file=sys.stderr
        )
    if not response.ok:
        print('shaman request', response.request.url, 'failed:',
              response.status_code, response.reason, file=sys.stderr)
        return True

    matches = response.json()
    if len(matches) == 0:
        return False
    for match in matches:
        if match['sha1'][0:7] == short_sha1:
            if verbose:
                print('Found matching build: ref %s sha1 %s quayname %s' %
                      (match['ref'], match['sha1'], tag['name']))
            return True
    return False


def delete_from_quay(tag, quaytoken, dryrun):
    if dryrun:
        print('Would delete from quay: ', tag['name'])
        return

    try:
        response = requests.delete(
            '/'.join((QUAYBASE, 'repository', REPO, 'tag', tag['name'])),
            headers={'Authorization': 'Bearer %s' % quaytoken},
            timeout=30,
        )
        response.raise_for_status()
        print('Deleted', tag['name'])
    except requests.exceptions.RequestException as e:
        print(
            'Problem on delete of tag %s:',
            tag['name'],
            e,
            response.reason,
            file=sys.stderr
        )


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-d', '--dryrun', action='store_true', help="don't actually delete")
    parser.add_argument('-v', '--verbose', action='store_true', help="say more")
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
    for tag in quaytags:
        if 'expiration' in tag or 'end_ts' in tag:
            if args.verbose:
                print('Skipping already-deleted tag', tag['name'])
            continue
        if present_in_shaman(tag, args.verbose):
            continue
        delete_from_quay(tag, quaytoken, args.dryrun)


if __name__ == "__main__":
    sys.exit(main())
