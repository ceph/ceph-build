#!/usr/bin/env python3

import argparse
import os
import sys
import util
from collections import defaultdict
import pprint

tags_done = set()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--start', type=int, default=1,
                        help="start page (of 100 tags)")
    parser.add_argument('-p', '--pages', type=int, default=100000,
                        help="number of pages")
    parser.add_argument('-n', '--dry-run', action='store_true',
                        help="don't actually delete")
    parser.add_argument('-v', '--verbose', action='count', default=0,
                        help="say more (-vv for more info)")
    return parser.parse_args()


def mark_all_done(tags):
    if isinstance(tags, (list, set, tuple)):
        tags_done.update(tags)
    else:
        tags_done.add(tags)


def main():
    args = parse_args()

    quaytoken = None
    if not args.dry_run:
        if 'QUAYTOKEN' in os.environ:
            quaytoken = os.environ['QUAYTOKEN']
        else:
            quaytoken = open(
                os.path.join(os.environ['HOME'], '.quaytoken'),
                'rb'
            ).read().strip().decode()

    print(f'Getting tags from {util.QUAYBASE}{util.REPO}', file=sys.stderr)
    quaytags, digest_to_tags = util.get_all_quay_tags(quaytoken, args.start, args.pages)

    tagstat = defaultdict(int)
    tagstat['total tags'] = len(quaytags)
    tagstat['unique_tags'] = len(digest_to_tags)
    pprint.pprint(tagstat)

    # Search through all the tags, matching digests so that we can consider
    # all of them at the same time.  Use the sha1 tag to search for the
    # packages on shaman; if we can't find that sha1 on shaman,
    # delete all the tags (IOW, shaman presence controls how long we keep the
    # corresponding container images).

    tags_to_delete = list()

    for qtag in quaytags:
        name = qtag['name']
        if 'expiration' in qtag or 'end_ts' in qtag:
            if args.verbose:
                print('Skipping deleted-or-overwritten tag %s' % name)
            tagstat['skipped'] += 1
            tagstat['skipped_already_deleted'] += 1
            continue

        sha1 = None
        digest = qtag['manifest_digest']
        alltags = digest_to_tags.get(digest)

        # collect all the info from all the tagnames
        if args.verbose:
            print(f'\nExamining {alltags}')

        if not alltags:
            return 0

        for t in alltags:

            if args.verbose:
                print(f'\nOn tag {t}')

            if t in tags_done:
                if args.verbose:
                    print(f'tag {t} already examined')
                continue

            parsed_sha1, sha1, fromtag, flav_or_arch = util.parse_sha1_quay_tag(t)
            if args.verbose > 1:
                print(f'{"" if parsed_sha1 else "NOT"} SHA1: {sha1=} {fromtag=} {flav_or_arch=}')

            if not (parsed_sha1):
                if args.verbose:
                    print(f'Assuming {t} is a branch tag, will skip')
                tagstat['skipped'] += 1
                tagstat['skipped_branchtag'] += 1
                mark_all_done(t)
                continue

            if args.verbose:
                print(f'Looking for {sha1} in shaman')

            if util.sha1_present_in_shaman(sha1, args.verbose):
                if args.verbose:
                    print(f'Skipping {t}, present in shaman')
                tagstat['skipped'] += 1
                tagstat['skipped_in_shaman'] += 1
                mark_all_done(alltags)

                continue

            if args.verbose:
                print(f'Marking {alltags} {qtag["last_modified"]} for deletion')
            tags_to_delete.append((alltags, qtag['last_modified']))
            tagstat['marked_for_delete'] += 1
            tagstat['subtags_marked_for_delete'] += len(alltags)
            mark_all_done(alltags)

    # and now delete all the ones we found
    for (alltags, date) in tags_to_delete:
        for tagname in alltags:
            util.delete_from_quay(tagname, date, quaytoken, args.dry_run)
        tagstat['deleted'] += 1
        tagstat['subtags_deleted'] += len(alltags)

    pprint.pprint(tagstat, sort_dicts=False)


if __name__ == "__main__":
    sys.exit(main())
