#!/usr/bin/env bash
# Post a note to a Redmine issue. Usage: redmine_post_note.sh <issue_id> <note_file>
# Requires: REDMINE_API_KEY in environment.
set -euo pipefail
ISSUE_ID="${1:?}"; NOTE_FILE="${2:?}"; REDMINE_URL="${REDMINE_URL:-https://tracker.ceph.com}"
[[ -z "${REDMINE_API_KEY:-}" ]] && { echo "REDMINE_API_KEY not set."; exit 0; }
[[ ! -f "$NOTE_FILE" ]] && { echo "Note file not found: $NOTE_FILE"; exit 1; }
NOTE_JSON=$(python3 -c "import json,sys; f=open(sys.argv[1]); print(json.dumps({'issue':{'notes':f.read()}}))" "$NOTE_FILE")
HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/redmine_resp.json -X PUT \
  -H "X-Redmine-API-Key: $REDMINE_API_KEY" -H "Content-Type: application/json" \
  -d "$NOTE_JSON" "${REDMINE_URL}/issues/${ISSUE_ID}.json")
[[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" ]] && { echo "HTTP $HTTP_CODE"; cat /tmp/redmine_resp.json; exit 1; }
echo "Posted note to ${REDMINE_URL}/issues/${ISSUE_ID}"
