#!/bin/bash

# Purge orphaned Pulp distributions/publications and stale unlisted repos
# per purge-policy.yaml.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

log() {
    echo "[pulp_cleanup] $*" >&2
}

if [ $# -lt 1 ] || [ -z "${1}" ]; then
    log "ERROR: project name required"
    exit 1
fi

if [ -z "${WORKSPACE:-}" ] || [ ! -d "${WORKSPACE}" ]; then
    log "ERROR: WORKSPACE is not set or not a directory"
    exit 1
fi

readonly PROJECT="$1"
readonly PURGE_POLICY_FILE="${WORKSPACE}/scripts/purge-policy.yaml"
readonly PURGE_POLICY_PY="${WORKSPACE}/scripts/purge_policy.py"
readonly NOTIFY_SHAMAN_SCRIPT="${WORKSPACE}/scripts/notify_shaman_pulp_repo.sh"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly PULP_SERVER_URL="${PULP_SERVER_URL:-https://pulp.front.sepia.ceph.com}"

readonly LABEL="ref"
readonly PULP_LIST_LIMIT=1000
readonly PULP_TYPES=(rpm deb)

# Default protection time in minutes
readonly PROTECTION_TIME=1440

DEFAULT_POLICY_JSON=""
REF_POLICY_JSON=""
PULP_DESTROY_FAILURES=0
declare -A SHAMAN_NOTIFIED_URLS=()

load_purge_policy_section() {
    local project="$1"
    local label="$2"
    local output

    if [ ! -f "${PURGE_POLICY_FILE}" ]; then
        log "ERROR: Purge policy file not found: ${PURGE_POLICY_FILE}"
        return 1
    fi

    if ! output=$(
        python3 "${PURGE_POLICY_PY}" \
            --project "${project}" --label "${label}" \
            --file "${PURGE_POLICY_FILE}" 2>&1
    ); then
        log "ERROR: Failed to read ${label} policy for ${project}: ${output}"
        return 1
    fi

    printf '%s\n' "${output}"
}

load_purge_policies() {
    local project="$1"

    if ! DEFAULT_POLICY_JSON=$(
        load_purge_policy_section "${project}" default
    ); then
        return 1
    fi
    if ! REF_POLICY_JSON=$(load_purge_policy_section "${project}" ref); then
        return 1
    fi
}

read_default_purge_policy() {
    local -n _days="$1"

    _days=$(echo "${DEFAULT_POLICY_JSON}" | jq -r '.days')
}

fetch_pulp_resource_json() {
    local type="$1"
    local resource="$2"
    local project="$3"
    local label_select="$4"
    local pulp_output

    if ! pulp_output=$(
        pulp "${type}" "${resource}" list \
            --limit "${PULP_LIST_LIMIT}" \
            --ordering 'pulp_last_updated' \
            --label-select project="${project}","${label_select}" \
            2>&1
    ); then
        log "ERROR: Failed to list ${type} ${resource}: ${pulp_output}"
        return 1
    fi

    sed -n '/^\[/,$p' <<< "${pulp_output}"
}

fetch_pulp_list_json() {
    local type="$1"
    local resource="$2"
    local pulp_output

    if ! pulp_output=$(
        pulp "${type}" "${resource}" list \
            --limit "${PULP_LIST_LIMIT}" \
            "${@:3}" \
            2>&1
    ); then
        log "ERROR: Failed to list ${type} ${resource}: ${pulp_output}"
        return 1
    fi

    sed -n '/^\[/,$p' <<< "${pulp_output}"
}

list_repositories() {
    local type="$1"
    local project="$2"
    local label_select="$3"

    fetch_pulp_resource_json "${type}" "repository" "${project}" \
        "${label_select}"
}

build_unlisted_label_select() {
    local label="$1"
    local -a policy_refs=("${@:2}")

    printf "${label}!=%s\n" "${policy_refs[@]}" | paste -sd, -
}

list_distributions_for_label_select() {
    local type="$1"
    local project="$2"
    local label_select="$3"
    local dists_json

    if ! dists_json=$(
        fetch_pulp_resource_json "${type}" "distribution" "${project}" \
            "${label_select}"
    ); then
        printf '[]\n'
        return 0
    fi

    if ! echo "${dists_json}" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log "WARNING: Invalid ${type} distribution list" \
            "for label_select=${label_select}"
        printf '[]\n'
        return 0
    fi

    echo "${dists_json}" | jq -c 'sort_by(.pulp_last_updated)'
}

fetch_pulp_show_json() {
    local type="$1"
    local resource="$2"
    local href="$3"
    local pulp_output

    if ! pulp_output=$(
        pulp "${type}" "${resource}" show --href "${href}" 2>&1
    ); then
        log "WARNING: Failed to read ${type} ${resource}" \
            "${href}: ${pulp_output}"
        return 1
    fi

    sed -n '/^{/,$p' <<< "${pulp_output}"
}

repository_version_exists() {
    local type="$1"
    local version_href="$2"
    local repository_href version_num

    if [[ ! "${version_href}" =~ ^(.+)/versions/([0-9]+)/?$ ]]; then
        log "WARNING: Unrecognized repository version href: ${version_href}"
        return 1
    fi

    repository_href="${BASH_REMATCH[1]}/"
    version_num="${BASH_REMATCH[2]}"

    if pulp "${type}" repository version show \
            --repository-href "${repository_href}" \
            --version "${version_num}" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

get_publication_orphan_status() {
    local type="$1"
    local pub_href="$2"
    local pub_json repo_version

    if [ -z "${pub_href}" ]; then
        printf 'yes\n'
        return 0
    fi

    if ! pub_json=$(fetch_pulp_show_json "${type}" publication "${pub_href}"); then
        printf 'unknown\n'
        return 0
    fi

    if ! repo_version=$(
        echo "${pub_json}" | jq -r '.repository_version // empty'
    ); then
        log "WARNING: Failed to parse repository_version for ${pub_href}"
        printf 'unknown\n'
        return 0
    fi

    if [ -z "${repo_version}" ]; then
        printf 'yes\n'
        return 0
    fi

    if repository_version_exists "${type}" "${repo_version}"; then
        printf 'no\n'
        return 0
    fi

    printf 'yes\n'
}

select_orphaned_distribution_names() {
    local type="$1"
    local dists_json="$2"
    local -A pub_orphan_cache=()
    local dist_name pub_href cache_key orphan_status

    while IFS=$'\t' read -r dist_name pub_href; do
        [ -z "${dist_name}" ] && continue

        cache_key="${pub_href:-__empty_publication__}"

        if [ -z "${pub_orphan_cache[$cache_key]+x}" ]; then
            pub_orphan_cache["${cache_key}"]=$(
                get_publication_orphan_status "${type}" "${pub_href}"
            )
        fi
        orphan_status="${pub_orphan_cache[$cache_key]}"

        if [ "${orphan_status}" = "yes" ]; then
            printf '%s\n' "${dist_name}"
        fi
    done < <(
        echo "${dists_json}" \
            | jq -r '.[] | [.name, .publication // ""] | @tsv'
    )
}

list_distributions_for_repository() {
    local type="$1"
    local project="$2"
    local repo_name="$3"
    local dists_json

    if [ "${type}" = "rpm" ]; then
        if ! dists_json=$(
            fetch_pulp_list_json "${type}" distribution \
                --name-contains "${repo_name}" \
                --ordering 'pulp_last_updated'
        ); then
            printf '[]\n'
            return 0
        fi
        echo "${dists_json}" | jq -c 'sort_by(.pulp_last_updated)'
        return 0
    fi

    # deb distribution list has no --name-contains; filter client-side by name
    if ! dists_json=$(
        fetch_pulp_list_json "${type}" distribution \
            --ordering 'pulp_last_updated' \
            --label-select "project=${project}"
    ); then
        printf '[]\n'
        return 0
    fi
    echo "${dists_json}" | jq -c --arg repo "${repo_name}" '
        [.[] | select(.name | contains($repo))]
        | sort_by(.pulp_last_updated)
    '
}

is_resource_stale() {
    local timestamp="$1"
    local days="$2"

    jq -e -n --arg ts "${timestamp}" --arg days "${days}" '
        ($ts | split(".")[0] + "Z" | fromdateiso8601)
        < (now - ($days | tonumber) * 86400)
    ' >/dev/null
}

distribution_names_from_json() {
    local dists_json="$1"

    echo "${dists_json}" | jq -r '.[].name'
}

fetch_distribution_show_json() {
    local type="$1"
    local lookup_flag="$2"
    local name="$3"
    local pulp_output

    if ! pulp_output=$(
        pulp "${type}" distribution show "${lookup_flag}" "${name}" 2>&1
    ); then
        log "WARNING: Failed to read ${type} distribution" \
            "${name}: ${pulp_output}"
        return 1
    fi

    sed -n '/^{/,$p' <<< "${pulp_output}"
}

shaman_url_from_base_path() {
    local base_path="$1"
    local flavor_path

    base_path="${base_path#/}"
    base_path="${base_path%/}"
    flavor_path="${base_path%/*}"
    if [ -z "${flavor_path}" ] || [ "${flavor_path}" = "${base_path}" ]; then
        return 1
    fi

    printf '%s/pulp/content/%s/\n' \
        "${PULP_SERVER_URL%/}" "${flavor_path}"
}

distribution_shaman_fields_from_json() {
    local dist_json="$1"
    local type="$2"
    local name="$3"
    local base_path shaman_url
    local project ref sha1 distro distro_version flavor arch

    base_path=$(echo "${dist_json}" | jq -r '.base_path // empty')
    project=$(echo "${dist_json}" | jq -r '.pulp_labels.project // empty')
    ref=$(echo "${dist_json}" | jq -r '.pulp_labels.ref // empty')
    sha1=$(echo "${dist_json}" | jq -r '.pulp_labels.sha1 // empty')
    distro=$(echo "${dist_json}" | jq -r '.pulp_labels.distro // empty')
    distro_version=$(
        echo "${dist_json}" | jq -r '.pulp_labels.distro_version // empty'
    )
    flavor=$(echo "${dist_json}" | jq -r '.pulp_labels.flavors // empty')
    arch=$(echo "${dist_json}" | jq -r '.pulp_labels.arch // empty')

    if [ -z "${base_path}" ] || [ -z "${project}" ] || [ -z "${ref}" ] \
            || [ -z "${sha1}" ] || [ -z "${distro}" ] \
            || [ -z "${distro_version}" ] || [ -z "${flavor}" ] \
            || [ -z "${arch}" ]; then
        log "WARNING: Incomplete shaman labels/base_path for" \
            "${type} distribution ${name}; skipping shaman notify"
        return 1
    fi

    if ! shaman_url=$(shaman_url_from_base_path "${base_path}"); then
        log "WARNING: Failed to derive shaman URL from base_path" \
            "${base_path} for ${type} distribution ${name}"
        return 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${project}" "${ref}" "${sha1}" "${distro}" \
        "${distro_version}" "${flavor}" "${arch}" "${shaman_url}"
}

shaman_key_distributions_remain() {
    local project="$1"
    local ref="$2"
    local sha1="$3"
    local distro="$4"
    local distro_version="$5"
    local flavor="$6"
    local type label_select dists_json count

    label_select="project=${project},ref=${ref},sha1=${sha1}"
    label_select="${label_select},distro=${distro}"
    label_select="${label_select},distro_version=${distro_version}"
    label_select="${label_select},flavors=${flavor}"

    for type in "${PULP_TYPES[@]}"; do
        if ! dists_json=$(
            fetch_pulp_list_json "${type}" distribution \
                --label-select "${label_select}"
        ); then
            # Fail open: assume siblings remain so we do not delete shaman
            # records while Pulp listing is broken.
            return 0
        fi
        count=$(echo "${dists_json}" | jq 'length')
        if [ "${count}" -gt 0 ]; then
            return 0
        fi
    done

    return 1
}

notify_shaman_pulp_repo_deleted() {
    local pkg_type="$1"
    local project="$2"
    local ref="$3"
    local sha1="$4"
    local distro="$5"
    local distro_version="$6"
    local flavor="$7"
    local arch="$8"
    local shaman_url="$9"

    if [ "${DRY_RUN}" = "true" ]; then
        return 0
    fi

    if [ -z "${SHAMAN_API_USER:-}" ] || [ -z "${SHAMAN_API_KEY:-}" ]; then
        log "WARNING: SHAMAN_API_USER/SHAMAN_API_KEY unset;" \
            "skipping shaman notify for ${shaman_url}"
        return 0
    fi

    if [ ! -f "${NOTIFY_SHAMAN_SCRIPT}" ]; then
        log "WARNING: Missing shaman notify script:" \
            "${NOTIFY_SHAMAN_SCRIPT}"
        return 0
    fi

    if [ -n "${SHAMAN_NOTIFIED_URLS[${shaman_url}]+x}" ]; then
        log "shaman url=${shaman_url} action=skip_already_notified"
        return 0
    fi

    if shaman_key_distributions_remain \
            "${project}" "${ref}" "${sha1}" "${distro}" \
            "${distro_version}" "${flavor}"; then
        log "shaman url=${shaman_url} action=skip_sibling_dists_remain"
        return 0
    fi

    log "Notifying shaman deleted for ${shaman_url}"
    if ! BRANCH="${ref}" SHA1="${sha1}" FLAVOR="${flavor}" \
            OS_PKG_TYPE="${pkg_type}" \
            "${NOTIFY_SHAMAN_SCRIPT}" deleted "${project}" "${distro}" \
            "${distro_version}" "${arch}" "${shaman_url}"; then
        log "WARNING: Failed to notify shaman deleted for ${shaman_url}"
        return 0
    fi

    SHAMAN_NOTIFIED_URLS["${shaman_url}"]=1
}

destroy_pulp_publication() {
    local type="$1"
    local pub_href="$2"

    [ -z "${pub_href}" ] && return 0

    if [ "${DRY_RUN}" = "true" ]; then
        log "[DRY RUN] Would destroy ${type} publication: ${pub_href}"
        return 0
    fi

    log "Destroying ${type} publication: ${pub_href}"
    if ! pulp "${type}" publication destroy --href "${pub_href}"; then
        log "ERROR: Failed to destroy ${type} publication: ${pub_href}"
    fi
}

destroy_pulp_resources() {
    local type="$1"
    local resource="$2"
    local resource_list="$3"
    local name lookup_flag pub_href dist_json
    local shaman_project shaman_ref shaman_sha1 shaman_distro
    local shaman_distro_version shaman_flavor shaman_arch shaman_url
    local shaman_fields

    PULP_DESTROY_FAILURES=0

    # pulp-cli looks up rpm distributions with --distribution; everything
    # else (deb distributions, rpm/deb repositories) uses --name.
    lookup_flag="--name"
    if [ "${type}" = "rpm" ] && [ "${resource}" = "distribution" ]; then
        lookup_flag="--distribution"
    fi

    if [ -z "${resource_list}" ]; then
        return 0
    fi

    while IFS= read -r name; do
        [ -z "${name}" ] && continue
        pub_href=""
        dist_json=""
        shaman_fields=""
        shaman_project=""
        shaman_ref=""
        shaman_sha1=""
        shaman_distro=""
        shaman_distro_version=""
        shaman_flavor=""
        shaman_arch=""
        shaman_url=""
        if [ "${resource}" = "distribution" ]; then
            # One show: publication href + shaman metadata before destroy.
            if dist_json=$(
                fetch_distribution_show_json \
                    "${type}" "${lookup_flag}" "${name}"
            ); then
                pub_href=$(
                    echo "${dist_json}" | jq -r '.publication // empty'
                )
                if [ -z "${pub_href}" ]; then
                    log "WARNING: No publication href for" \
                        "${type} distribution ${name}"
                fi
                if shaman_fields=$(
                    distribution_shaman_fields_from_json \
                        "${dist_json}" "${type}" "${name}"
                ); then
                    IFS=$'\t' read -r shaman_project shaman_ref \
                        shaman_sha1 shaman_distro shaman_distro_version \
                        shaman_flavor shaman_arch shaman_url \
                        <<< "${shaman_fields}"
                fi
            fi
        fi

        if [ "${DRY_RUN}" = "true" ]; then
            log "[DRY RUN] Would destroy ${type} ${resource}: ${name}"
            if [ -n "${pub_href}" ]; then
                destroy_pulp_publication "${type}" "${pub_href}"
            fi
            continue
        fi

        log "Destroying ${type} ${resource}: ${name}"
        if ! pulp "${type}" "${resource}" destroy \
                "${lookup_flag}" "${name}"; then
            log "WARNING: Failed to destroy ${type} ${resource}: ${name}"
            PULP_DESTROY_FAILURES=$((PULP_DESTROY_FAILURES + 1))
            continue
        fi

        if [ "${resource}" = "distribution" ] && [ -n "${pub_href}" ]; then
            destroy_pulp_publication "${type}" "${pub_href}"
        fi

        if [ "${resource}" = "distribution" ] && [ -n "${shaman_url}" ]; then
            notify_shaman_pulp_repo_deleted \
                "${type}" "${shaman_project}" "${shaman_ref}" \
                "${shaman_sha1}" "${shaman_distro}" \
                "${shaman_distro_version}" "${shaman_flavor}" \
                "${shaman_arch}" "${shaman_url}"
        fi
    done <<< "${resource_list}"
}

purge_orphaned_distributions() {
    local type="$1"
    local project="$2"
    local label_select="$3"
    local log_label="$4"
    local dists_json dist_count candidates orphaned_count

    dists_json=$(
        list_distributions_for_label_select \
            "${type}" "${project}" "${label_select}"
    )
    dist_count=$(echo "${dists_json}" | jq 'length')
    if [ "${dist_count}" -ge "${PULP_LIST_LIMIT}" ]; then
        log "WARNING: ${log_label} type=${type}" \
            "has >= ${PULP_LIST_LIMIT} distributions; list may be truncated"
    fi

    candidates=$(
        select_orphaned_distribution_names "${type}" "${dists_json}"
    )
    if [ -n "${candidates}" ]; then
        orphaned_count=$(printf '%s\n' "${candidates}" | grep -c . || true)
    else
        orphaned_count=0
    fi

    log "${log_label} type=${type} dists=${dist_count}" \
        "orphaned=${orphaned_count} action=purge_orphaned_dists"
    destroy_pulp_resources "${type}" "distribution" "${candidates}"
}

purge_stale_unlisted_repo() {
    local type="$1"
    local project="$2"
    local repo_name="$3"
    local repo_last_updated="$4"
    local days="$5"
    local dists_json dist_names dist_count action

    if ! is_resource_stale "${repo_last_updated}" "${days}"; then
        log "unlisted repo=${repo_name} days=${days} action=skip_fresh_repo"
        return 0
    fi

    dists_json=$(
        list_distributions_for_repository "${type}" "${project}" "${repo_name}"
    )
    dist_names=$(distribution_names_from_json "${dists_json}")
    dist_count=$(echo "${dists_json}" | jq 'length')

    destroy_pulp_resources "${type}" "distribution" "${dist_names}"
    if [ "${PULP_DESTROY_FAILURES}" -eq 0 ]; then
        destroy_pulp_resources "${type}" "repository" "${repo_name}"
        action="purge_stale_unlisted_repo"
    else
        log "WARNING: unlisted repo=${repo_name}" \
            "dist_destroy_failures=${PULP_DESTROY_FAILURES}" \
            "skipping repository destroy"
        action="purge_stale_unlisted_repo_partial"
    fi

    log "unlisted repo=${repo_name} days=${days} dists=${dist_count}" \
        "action=${action}"
}

run_listed_repo_cleanup() {
    local project="$1"
    local label="$2"
    local ref type
    local -a policy_refs=("${@:3}")

    for ref in "${policy_refs[@]}"; do
        log "Purging listed ref=${ref}"
        for type in "${PULP_TYPES[@]}"; do
            purge_orphaned_distributions \
                "${type}" "${project}" "${label}=${ref}" "ref=${ref}"
        done
    done
}

run_unlisted_repo_cleanup() {
    local project="$1"
    local label="$2"
    local days="$3"
    local _label_select type repos_json repo_name repo_updated
    local -a policy_refs=("${@:4}")

    _label_select=$(build_unlisted_label_select "${label}" "${policy_refs[@]}")
    if [ -z "${_label_select}" ]; then
        log "ERROR: Failed to build label selector from purge policy"
        return 1
    fi
    log "Purging unlisted refs days=${days} label_select=${_label_select}"

    for type in "${PULP_TYPES[@]}"; do
        purge_orphaned_distributions \
            "${type}" "${project}" "${_label_select}" "unlisted"
    done

    for type in "${PULP_TYPES[@]}"; do
        if ! repos_json=$(
            list_repositories "${type}" "${project}" "${_label_select}"
        ); then
            return 1
        fi
        while IFS=$'\t' read -r repo_name repo_updated; do
            [ -z "${repo_name}" ] && continue
            purge_stale_unlisted_repo \
                "${type}" "${project}" "${repo_name}" "${repo_updated}" \
                "${days}"
        done < <(
            echo "${repos_json}" \
                | jq -r '.[] | [.name, .pulp_last_updated] | @tsv'
        )
    done
}

run_package_cleanup() {
    local project="$1"
    local label="$2"
    local days
    local -a policy_refs=()

    if ! load_purge_policies "${project}"; then
        return 1
    fi

    mapfile -t policy_refs < <(echo "${REF_POLICY_JSON}" | jq -r 'keys[]')
    if [ "${#policy_refs[@]}" -eq 0 ]; then
        log "ERROR: No protected ${label} entries for project ${project}"
        return 1
    fi

    read_default_purge_policy days
    log "default days: ${days}"

    run_listed_repo_cleanup "${project}" "${label}" "${policy_refs[@]}"
    run_unlisted_repo_cleanup \
        "${project}" "${label}" "${days}" "${policy_refs[@]}"
}

run_orphan_cleanup() {
    if [ "${DRY_RUN}" = "true" ]; then
        log "DRY RUN: skipping orphan cleanup"
        return 0
    fi

    log "Applying orphan content purge policy"
    if ! pulp orphan cleanup \
            --protection-time "${PROTECTION_TIME}"; then
        log "ERROR: Failed to run orphan cleanup"
        return 1
    fi
    log "Orphan cleanup completed"
}

log "Cleaning up project: ${PROJECT}"

if [ "${DRY_RUN}" = "true" ]; then
    log "DRY RUN enabled: no Pulp resources will be destroyed"
fi

log "Running package cleanup"
run_package_cleanup "${PROJECT}" "${LABEL}"

log "Running orphan cleanup"
run_orphan_cleanup
