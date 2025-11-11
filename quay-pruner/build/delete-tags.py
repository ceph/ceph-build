#!/usr/bin/env python3

import argparse
import os
import requests
import sys
import util


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--start', type=int, default=1,
                        help="start page (of 100 tags)")
    parser.add_argument('-p', '--pages', type=int, default=100000,
                        help="number of pages")
    parser.add_argument('-S', '--stragglers', type=int,
                        metavar="DAYS_OLD",
                        help="find stragglers and delete them")
    parser.add_argument('-n', '--dryrun', action='store_true',
                        help="don't actually delete")
    parser.add_argument('-v', '--verbose', action='count', default=0,
                        help="say more (-vv for more info)")
    parser.add_argument('deletetags', nargs='*')
    return parser.parse_args()


def main():
    args = parse_args()

    tags_to_delete = list()
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
    quaytags, digest_to_tags = util.get_all_quay_tags(quaytoken, args.start, args.pages)

    if args.stragglers:
        for tag in quaytags:
            date = tag['last_modified']
            if util.days_diff(date) >= args.stragglers:
                alltags = digest_to_tags[tag['manifest_digest']]
                if any([r in t for t in alltags for r in ('quincy', 'reef', 'squid', 'tentacle')]):
                    print(f'skipping {alltags}, looks distinguished')
                    continue
                '''
                if len(alltags) > 1:
                    print(f'{tag["name"]} has friends {alltags}, leaving for now')
                    continue
                '''
                print(f'Marking {tag["name"]}')
                tags_to_delete.append((alltags, date))
    else:
        for tag in args.deletetags:
            response = requests.get(
                '/'.join((util.QUAYBASE, 'repository', util.REPO, 'tag')),
                params=(f'filter_tag_name=eq:{tag}'),
                headers={'Authorization': 'Bearer %s' % quaytoken},
                timeout=30,
            )
            if response.status_code == 404:
                print(f'{tag} not found')
                continue
            response.raise_for_status()
            tagdata = response.json()['tags'][0]
            date = tagdata['last_modified']
            alltags = digest_to_tags[tagdata['manifest_digest']]
            tags_to_delete.append((alltags, date))

    # and now delete all the ones we found
    for alltags, date in tags_to_delete:
        for tagname in alltags:
            util.delete_from_quay(tagname, date, quaytoken, args.dryrun)


if __name__ == "__main__":
    sys.exit(main())
