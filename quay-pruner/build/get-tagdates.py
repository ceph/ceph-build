#!/usr/bin/env python3

import argparse
import json
import sys
import util
from collections import defaultdict

QUAYBASE = "https://quay.ceph.io/api/v1"
REPO = "ceph-ci/ceph"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--start', type=int, default=1,
                        help="start page (of 100 tags)")
    parser.add_argument('-p', '--pages', type=int, default=100000,
                        help="number of pages")
    parser.add_argument('-v', '--verbose', action='count',
                        help="say more (-vv for more info)")
    return parser.parse_args()


def main():
    args = parse_args()

    print(f'Getting tags from {util.QUAYBASE}{util.REPO}', file=sys.stderr)
    quaytags, digest_to_tags = util.get_all_quay_tags(None, args.start, args.pages)

    tagdates = defaultdict(str)
    for tag in quaytags:
        digest = tag['manifest_digest']
        tagdates[digest] = tag['last_modified']

    counter = 0
    max = len(digest_to_tags)

    print('[')
    for digest, alltags in digest_to_tags.items():
        d = dict()
        d['tags'] = alltags
        if len(alltags) == 1:
            d['orphan'] = True
        d['age_in_days'] = util.days_diff(tagdates[digest])
        d['digest'] = digest
        print(json.dumps(d), end='')
        counter += 1
        if counter < max:
            print(",")
    print('\n]')
    exit(0)


if __name__ == "__main__":
    sys.exit(main())
