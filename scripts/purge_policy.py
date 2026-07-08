#!/usr/bin/env python3
"""Read and validate purge-policy.yaml for shell scripts.

Loads a labeled section from purge-policy.yaml and prints it as JSON on stdout.
Callers (cleanup.sh, pulp_upload.sh) use jq to extract days and keep_minimum.

Policy layout::

    <project>:
      default:
        days: <int>           # required; fallback for labeled entries
        keep_minimum: <int>   # required; fallback for labeled entries
      <label>:                # e.g. ref, branch
        <name>:
          days: <int>         # optional; falls back to default.days
          keep_minimum: <int> # optional; falls back to default.keep_minimum

Examples::

    # Default retention for a project
    purge_policy.py --project ceph --label default --file purge-policy.yaml

    # Listed branches/refs and their overrides
    purge_policy.py --project ceph --label ref --file purge-policy.yaml

Validation:
  - default: requires days and keep_minimum (positive integers)
  - other labels: non-empty mapping; each entry must be a mapping with valid
    optional days/keep_minimum; effective values after default fallback must
    be positive integers; default section must exist
"""

import argparse
import json
import sys
from pathlib import Path

import yaml


def positive_int(value, path: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{path} must be a positive integer, got: {value!r}")
    return value


def validate_default(section: dict, project: str) -> dict:
    path = f"{project}.default"
    if not isinstance(section, dict) or not section:
        raise ValueError(f"{path} must be a non-empty mapping")

    if "days" not in section:
        raise ValueError(f"{path}.days is required")
    if "keep_minimum" not in section:
        raise ValueError(f"{path}.keep_minimum is required")

    positive_int(section["days"], f"{path}.days")
    positive_int(section["keep_minimum"], f"{path}.keep_minimum")
    return section


def validate_labeled_entries(
    label: str,
    section: dict,
    project: str,
    default: dict,
) -> dict:
    path = f"{project}.{label}"
    if not isinstance(section, dict) or not section:
        raise ValueError(f"no {label} entries for project {project}")

    validate_default(default, project)

    for name, entry in section.items():
        entry_path = f"{path}.{name}"
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"invalid entry name in {path}: {name!r}")
        if not isinstance(entry, dict):
            raise ValueError(f"{entry_path} must be a mapping")

        if "days" in entry:
            positive_int(entry["days"], f"{entry_path}.days")
        if "keep_minimum" in entry:
            positive_int(entry["keep_minimum"], f"{entry_path}.keep_minimum")

        positive_int(
            entry.get("days", default["days"]),
            f"effective days for {entry_path}",
        )
        positive_int(
            entry.get("keep_minimum", default["keep_minimum"]),
            f"effective keep_minimum for {entry_path}",
        )

    return section


def validate_label_section(
    label: str,
    section: dict,
    project: str,
    project_section: dict,
) -> dict:
    if label == "default":
        return validate_default(section, project)

    default = project_section.get("default")
    if not isinstance(default, dict):
        raise ValueError(
            f"{project}.default is required when loading {label} policy"
        )
    return validate_labeled_entries(label, section, project, default)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--project",
        required=True,
        help="Top-level project key in purge-policy.yaml (e.g. ceph)",
    )
    parser.add_argument(
        "--label",
        required=True,
        help=(
            "Section under the project to return: 'default' or a labeled "
            "mapping such as 'ref' or 'branch'"
        ),
    )
    parser.add_argument(
        "--file",
        type=Path,
        required=True,
        help="Path to purge-policy.yaml",
    )
    args = parser.parse_args()

    if not args.file.is_file():
        print(f"purge policy not found: {args.file}", file=sys.stderr)
        sys.exit(1)

    with args.file.open() as fh:
        policy = yaml.safe_load(fh)

    if not isinstance(policy, dict):
        print(f"invalid purge policy: {args.file}", file=sys.stderr)
        sys.exit(1)

    project_section = policy.get(args.project)
    if not isinstance(project_section, dict):
        print(
            f"project not found in purge policy: {args.project}",
            file=sys.stderr,
        )
        sys.exit(1)

    label_section = project_section.get(args.label)
    if label_section is None:
        print(
            f"label {args.label!r} not found for project {args.project}",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        label_section = validate_label_section(
            args.label,
            label_section,
            args.project,
            project_section,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)

    json.dump(label_section, sys.stdout)
    print()


if __name__ == "__main__":
    main()
