#!/bin/bash
if [ $# -ne 2 ]; then
  echo "Usage: $(basename $0) [disable|enable] BRANCH"
  echo
  echo "Example: \`$(basename $0) disable quincy"
  echo
  exit 1
else
  BRANCH="$2"
  if [ "$1" == "disable" ]; then
    ACTION='{"allow_force_pushes":false,"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}'
  elif [ "$1" == "enable" ]; then
    ACTION='{"required_status_checks":{"strict":false,"checks":[{"context":"Docs: build check","app_id":null},{"context":"Unmodified Submodules","app_id":null},{"context":"ceph API tests","app_id":null},{"context":"make check","app_id":null},{"context":"Signed-off-by","app_id":null}]},"required_pull_request_reviews":{"dismiss_stale_reviews":false,"require_code_owner_reviews":false,"required_approving_review_count":1},"required_signatures":false,"enforce_admins":true,"required_linear_history":false,"allow_force_pushes":false,"allow_deletions":false,"required_conversation_resolution":false,"restrictions":null,"allow_force_pushes":false}'
  else
    echo "Unknown option: $1"
  fi
fi

OAUTH2_USER=$GITHUB_USER
OAUTH2_TOKEN=$GITHUB_TOKEN
OWNER=ceph
REPO=ceph

curl -X PUT -u $OAUTH2_USER:$OAUTH2_TOKEN -H "Accept: application/vnd.github.luke-cage-preview+json" https://api.github.com/repos/$OWNER/$REPO/branches/$BRANCH/protection -d "$ACTION"
