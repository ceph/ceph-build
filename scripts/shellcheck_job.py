#!/usr/bin/env python3
import argparse
import pathlib
import subprocess
import sys
import xmltodict


def parse_args(args: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument(
        "job_xml",
        nargs="*",
        help="The job XML file(s) to process",
    )
    return parser.parse_args(args)


def main():
    args = parse_args(sys.argv[1:])
    success = True
    for job_xml in args.job_xml:
        path = pathlib.Path(job_xml)
        assert path.exists
        print("#" * 79)
        print(f"## Processing job {job_xml}")
        job_obj = xmltodict.parse(path.read_text())
        print("#" * 79)
        success = success and process_job(job_obj)
    return 0 if success else 1


def process_job(job_obj: dict) -> bool:
    success = True
    for item in find(job_obj, "command"):
        print("#" + "-" * 78)
        print(f"# Running shellcheck on {item[0]}")
        print("#" + "-" * 78)
        script = item[1]
        if not script.startswith("#!"):
            script = "#!/bin/bash\n" + script
        proc = subprocess.Popen(
            ["shellcheck", "--severity", "error", "-"],
            stdin=subprocess.PIPE,
            encoding="utf-8",
        )
        proc.communicate(input=script)
        success = proc.returncode == 0 and success
    return success


def find(obj: dict, key: str, result=None, path="") -> list[tuple]:
    if result is None:
        result = []
    if key in obj:
        result.append((path, obj[key]))
        return result
    for k, v in obj.items():
        if isinstance(v, dict):
            if "." in k:
                subpath = f'{path}."{k}"'
            else:
                subpath = f"{path}.{k}"
            maybe_result = find(v, key, result, subpath)
            if maybe_result is not result:
                result.append((subpath, maybe_result[-1]))
    return result


if __name__ == "__main__":
    sys.exit(main())
