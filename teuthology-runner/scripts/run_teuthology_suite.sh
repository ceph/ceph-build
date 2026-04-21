#!/usr/bin/env bash
# Run teuthology-suite with fixed argv, intended for Jenkins (nightly cadence).
# Required env: VIRTUALENV_PATH, SUITE_NAME, CEPH_BRANCH, CEPH_SHA1
# Optional: TEUTH_CONFIG_OVERRIDE_YAML (legacy: OVERRIDE_YAML), MACHINE_TYPE, CEPH_REPO, SUITE_LIMIT, SUITE_JOB_THRESHOLD, SUITE_SUBSET,
# SUITE_REPO, SUITE_SHA, SUITE_PRIORITY (-p), SUITE_KERNEL, SUITE_FILTER, SUITE_FLAVOR, SUITE_FORCE_PRIORITY
set -euo pipefail

: "${VIRTUALENV_PATH:?VIRTUALENV_PATH must be set}"
: "${SUITE_NAME:?SUITE_NAME must be set}"
: "${CEPH_BRANCH:?CEPH_BRANCH must be set}"
: "${CEPH_SHA1:?CEPH_SHA1 must be set}"

if [[ ! "${SUITE_NAME}" =~ ^[a-zA-Z0-9_/:-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_NAME: ${SUITE_NAME}" >&2
  exit 1
fi
if [[ ! "${CEPH_BRANCH}" =~ ^[a-zA-Z0-9/._-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid CEPH_BRANCH: ${CEPH_BRANCH}" >&2
  exit 1
fi
if [[ "${CEPH_SHA1}" == "unknown" ]]; then
  :
elif [[ ! "${CEPH_SHA1}" =~ ^[a-fA-F0-9]+$ ]] || [[ ${#CEPH_SHA1} -lt 7 ]]; then
  echo "run_teuthology_suite.sh: invalid CEPH_SHA1: ${CEPH_SHA1}" >&2
  exit 1
fi

TEUTHOLOGY_SUITE="${VIRTUALENV_PATH}/bin/teuthology-suite"
if [[ ! -f "${TEUTHOLOGY_SUITE}" ]]; then
  echo "run_teuthology_suite.sh: teuthology-suite not found: ${TEUTHOLOGY_SUITE}" >&2
  exit 1
fi

MACHINE_TYPE="${MACHINE_TYPE:-trial}"
CEPH_REPO="${CEPH_REPO:-https://github.com/ceph/ceph.git}"
SUITE_LIMIT="${SUITE_LIMIT:-1}"

if [[ ! "${MACHINE_TYPE}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid MACHINE_TYPE: ${MACHINE_TYPE}" >&2
  exit 1
fi
if [[ ! "${SUITE_LIMIT}" =~ ^[0-9]+$ ]] || [[ "${SUITE_LIMIT}" == "0" ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_LIMIT (positive integer): ${SUITE_LIMIT}" >&2
  exit 1
fi

if [[ -n "${SUITE_REPO:-}" ]] && [[ ! "${SUITE_REPO}" =~ ^[a-zA-Z0-9@.:/_-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_REPO: ${SUITE_REPO}" >&2
  exit 1
fi
if [[ -n "${SUITE_SHA:-}" ]]; then
  if [[ ! "${SUITE_SHA}" =~ ^[a-fA-F0-9]+$ ]] || [[ ${#SUITE_SHA} -lt 7 ]]; then
    echo "run_teuthology_suite.sh: invalid SUITE_SHA: ${SUITE_SHA}" >&2
    exit 1
  fi
fi

if [[ -n "${SUITE_JOB_THRESHOLD:-}" ]]; then
  if [[ ! "${SUITE_JOB_THRESHOLD}" =~ ^[0-9]+$ ]]; then
    echo "run_teuthology_suite.sh: invalid SUITE_JOB_THRESHOLD (non-negative integer): ${SUITE_JOB_THRESHOLD}" >&2
    exit 1
  fi
fi
if [[ -n "${SUITE_SUBSET:-}" ]]; then
  if [[ ! "${SUITE_SUBSET}" =~ ^[0-9]+/[0-9]+$ ]]; then
    echo "run_teuthology_suite.sh: invalid SUITE_SUBSET (expected N/M, e.g. 1/10000): ${SUITE_SUBSET}" >&2
    exit 1
  fi
fi

if [[ -n "${SUITE_PRIORITY:-}" ]]; then
  if [[ ! "${SUITE_PRIORITY}" =~ ^[0-9]+$ ]]; then
    echo "run_teuthology_suite.sh: invalid SUITE_PRIORITY: ${SUITE_PRIORITY}" >&2
    exit 1
  fi
fi
if [[ -n "${SUITE_KERNEL:-}" ]] && [[ ! "${SUITE_KERNEL}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_KERNEL: ${SUITE_KERNEL}" >&2
  exit 1
fi
if [[ -n "${SUITE_FILTER:-}" ]] && [[ ! "${SUITE_FILTER}" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_FILTER: ${SUITE_FILTER}" >&2
  exit 1
fi
if [[ -n "${SUITE_FLAVOR:-}" ]] && [[ ! "${SUITE_FLAVOR}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "run_teuthology_suite.sh: invalid SUITE_FLAVOR: ${SUITE_FLAVOR}" >&2
  exit 1
fi

set -- \
  "${TEUTHOLOGY_SUITE}" \
  --suite "${SUITE_NAME}" \
  --machine-type "${MACHINE_TYPE}" \
  --ceph "${CEPH_BRANCH}" \
  --ceph-repo "${CEPH_REPO}" \
  --limit "${SUITE_LIMIT}"

if [[ -n "${SUITE_PRIORITY:-}" ]]; then
  set -- "$@" -p "${SUITE_PRIORITY}"
fi
if [[ -n "${SUITE_JOB_THRESHOLD:-}" ]]; then
  set -- "$@" --job-threshold "${SUITE_JOB_THRESHOLD}"
fi
if [[ -n "${SUITE_SUBSET:-}" ]]; then
  set -- "$@" --subset "${SUITE_SUBSET}"
fi

set -- "$@" --sha1 "${CEPH_SHA1}"

if [[ -n "${SUITE_REPO:-}" ]]; then
  set -- "$@" --suite-repo "${SUITE_REPO}"
fi
if [[ -n "${SUITE_SHA:-}" ]]; then
  set -- "$@" --suite-sha1 "${SUITE_SHA}"
fi
if [[ -n "${SUITE_FILTER:-}" ]]; then
  set -- "$@" --filter "${SUITE_FILTER}"
fi
if [[ -n "${SUITE_FLAVOR:-}" ]]; then
  set -- "$@" --flavor "${SUITE_FLAVOR}"
fi
if [[ -n "${SUITE_KERNEL:-}" ]]; then
  set -- "$@" --kernel "${SUITE_KERNEL}"
fi
if [[ "${SUITE_FORCE_PRIORITY:-}" == "true" ]]; then
  set -- "$@" --force-priority
fi
TEUTH_CFG_OVERRIDE="${TEUTH_CONFIG_OVERRIDE_YAML:-${OVERRIDE_YAML:-}}"
if [[ -n "${TEUTH_CFG_OVERRIDE}" ]]; then
  set -- "$@" "${TEUTH_CFG_OVERRIDE}"
fi

exec "$@"
