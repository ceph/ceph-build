#!/bin/bash

# Purge stale Pulp repositories and distributions per purge-policy.yaml.

set -euo pipefail

readonly PROJECT="$1"
readonly PURGE_POLICY_FILE="${WORKSPACE}/scripts/purge-policy.yaml"

readonly LABEL="ref"
readonly PULP_LIST_LIMIT=1000
readonly PULP_TYPES=(rpm deb)
readonly PULP_RESOURCES=(distribution repository)

# Default protection time in hours
readonly PROTECTION_TIME=24

log() {
    echo "[pulp_cleanup] $*" >&2
}

get_policy_refs() {
    local project="$1"
    local label="$2"

    yq -r ".${project}.${label} | keys[]" "${PURGE_POLICY_FILE}"
}

read_default_purge_policy() {
    local project="$1"
    local -n _days="$2"
    local policy_line

    policy_line=$(
        yq -r \
            ".${project}.default | [(.days // \"\")] | @tsv" \
            "${PURGE_POLICY_FILE}"
    )
    IFS=$'\t' read -r _days <<< "${policy_line}"
}

fetch_pulp_resource_json() {
    local type="$1"
    local resource="$2"
    local project="$3"
    local label_select="$4"

    pulp "${type}" "${resource}" list \
        --limit "${PULP_LIST_LIMIT}" \
        --ordering '-pulp_created' \
        --label-select project="${project}","${label_select}" \
        2>&1 | sed -n '/^\[/,$p'
}

filter_resource_names_by_age() {
    local pulp_json="$1"
    local days="$2"

    if [ -z "${days}" ]; then
        echo "${pulp_json}" | jq -r '.[].name'
        return 0
    fi

    echo "${pulp_json}" | jq -r --arg days "${days}" '
        .[]
        | select(
            (.pulp_created | split(".")[0] + "Z" | fromdateiso8601)
            < (now - ($days | tonumber) * 86400)
          )
        | .name
    '
}

list_stale_pulp_resources() {
    local type="$1"
    local resource="$2"
    local project="$3"
    local label_select="$4"
    local days="$5"
    local pulp_json resource_list

    pulp_json=$(
        fetch_pulp_resource_json \
            "${type}" "${resource}" "${project}" "${label_select}"
    )
    resource_list=$(
        filter_resource_names_by_age "${pulp_json}" "${days}"
    )
    echo "${resource_list}"
}

destroy_pulp_resources() {
    local type="$1"
    local resource="$2"
    local resource_list="$3"
    local name

    if [ -z "${resource_list}" ]; then
        return 0
    fi

    while IFS= read -r name; do
        [ -z "${name}" ] && continue
        log "Destroying ${type} ${resource}: ${name}"
        if ! pulp "${type}" "${resource}" destroy \
                --name "${name}"; then
            log "ERROR: Failed to destroy ${type} ${resource}: ${name}"
            return 1
        fi
    done <<< "${resource_list}"
}

collect_stale_resources_for_ref() {
    local project="$1"
    local label_select="$2"
    local days="$3"
    local type resource key

    declare -n _stale_resources="$4"

    for type in "${PULP_TYPES[@]}"; do
        for resource in "${PULP_RESOURCES[@]}"; do
            key="${type}_${resource}"
            _stale_resources[$key]=$(
                list_stale_pulp_resources \
                    "${type}" "${resource}" "${project}" \
                    "${label_select}" "${days}"
            )
            log "${key}: ${_stale_resources[$key]:-}"
        done
    done
}

purge_resources() {
    local project="$1"
    local label_select="$2"
    local days="$3"
    local type resource

    declare -A stale_resources=()
    log "Purging days=${days:-unset} label_select=${label_select}"
    collect_stale_resources_for_ref "${project}" "${label_select}" "${days}" \
        stale_resources

    log "stale_resources: ${stale_resources[@]}"

    for type in "${PULP_TYPES[@]}"; do
        destroy_pulp_resources "${type}" "distribution" \
            "${stale_resources[${type}_distribution]:-}"
    done
    for type in "${PULP_TYPES[@]}"; do
        destroy_pulp_resources "${type}" "repository" \
            "${stale_resources[${type}_repository]:-}"
    done
}

run_package_cleanup() {
    local project="$1"
    local label="$2"
    local days

    mapfile -t policy_refs < <(get_policy_refs "${project}" "${label}")
    _label_select=$(
        printf "${label}!=%s\n" "${policy_refs[@]}" | paste -sd, -
    )
    log "label_select: ${_label_select}"

    read_default_purge_policy "${project}" days
    log "days: ${days}"

    purge_resources "${project}" "${_label_select}" "${days}"
}

run_orphan_cleanup() {
    log "Applying orphan content purge policy"
    if ! pulp orphan cleanup \
            --protection-time "${PROTECTION_TIME}"; then
        log "ERROR: Failed to run orphan cleanup"
        return 1
    fi
    log "Orphan cleanup completed"
}

log "Cleaning up project: ${PROJECT}"

log "Running package cleanup"
run_package_cleanup "${PROJECT}" "${LABEL}"

log "Running orphan cleanup"
run_orphan_cleanup
