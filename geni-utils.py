#!/usr/bin/env python3
import json
import re
import sys

import yaml


def fuzzy_yaml_fixer(raw: str) -> str:
    r'''
    Fix YAML input by stripping top-level code fences if present.

    The conversion is "fuzzy" in that it strips only a wrapping pair of
    top-level markdown code fences. Indented code fences inside YAML block
    scalars are preserved as data.

    >>> print(fuzzy_yaml_fixer("""
    ... message: hello
    ... """))
    message: hello

    >>> print(fuzzy_yaml_fixer("""
    ... ```yaml
    ... message: hello
    ... ```
    ... """))
    message: hello

    >>> print(fuzzy_yaml_fixer("""
    ... ```
    ... message: hello
    ... ```
    ... """))
    message: hello

    >>> print(fuzzy_yaml_fixer("""
    ... this text should get removed
    ... ```
    ... message: hello
    ... ```
    ... """))
    message: hello

    >>> print(fuzzy_yaml_fixer("""
    ... body: |
    ...   ```yaml
    ...   not a fence
    ...   ```
    ... """))
    body: |
      ```yaml
      not a fence
      ```
    '''
    lines = raw.split("\n")

    first_fence = None
    last_fence = None
    for i, line in enumerate(lines):
        if re.match(r"^```(ya?ml)?\s*$", line, re.IGNORECASE):
            if first_fence is None:
                first_fence = i
            else:
                last_fence = i

    if first_fence is not None and last_fence is not None:
        raw = "\n".join(lines[first_fence + 1:last_fence])

    return raw.strip()


def main() -> int:
    fixed_yaml = fuzzy_yaml_fixer(sys.stdin.read())
    sys.stdout.write(json.dumps(yaml.safe_load(fixed_yaml)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
