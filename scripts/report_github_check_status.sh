report_github_check_status () {
    
    state="$1"             # success, failure, or pending
    context="$2"           # e.g. "jenkins/build"
    description="$3"       # e.g. "Build passed"
    sha="$4"               # Commit SHA
    target_url="$5"        # Optional link to Jenkins build
    owner="${6:-ceph}"     # Default to "ceph"
    repo="${7:-ceph}"      # Default to "ceph"
    
    if [[ -z "$GITHUB_TOKEN" ]]; then
      echo "GITHUB_TOKEN environment variable not set"
      exit 1
    fi
    
    if [[ -z "$state" || -z "$context" || -z "$description" || -z "$sha" ]]; then
      echo "Usage: $0 <state> <context> <description> <sha> <target_url> [owner] [repo]"
      exit 1
    fi
    
    payload=$(jq -nc \
      --arg state "$state" \
      --arg context "$context" \
      --arg description "$description" \
      --arg target_url "$target_url" \
      '{
        state: $state,
        context: $context,
        description: $description,
        target_url: ($target_url // null)
      }')
    
    curl --retry 5 --retry-delay 2 --retry-all-errors --fail -s -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "https://api.github.com/repos/$owner/$repo/statuses/$sha"
    
}

# If the script is executed (as opposed to sourced), run the function now
if [ "$(basename -- "${0#-}")" = "$(basename -- "${BASH_SOURCE}")" ]; then
  report_github_check_status "$@"
fi
