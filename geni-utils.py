#!/usr/bin/env python3
import json
import re
import sys

import yaml


def fuzzy_yaml_fixer(raw: str) -> str:
    r'''
    Fix YAML input by stripping top-level code fences or leading prose if present.

    The conversion is "fuzzy" in that it:
    1. Strips only a wrapping pair of top-level markdown code fences
    2. Strips leading English prose that appears before YAML content

    Indented code fences inside YAML block scalars are preserved as data.

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

    >>> print(fuzzy_yaml_fixer("""
    ... here is some thinking text from the llm output before the yaml
    ... yaml_starts_here: hello
    ... yaml_continues: hello
    ... """))
    yaml_starts_here: hello
    yaml_continues: hello

    >>> print(fuzzy_yaml_fixer("""
    ... here is some thinking text from the llm output before the yaml
    ...
    ... yaml_starts_here: hello
    ... yaml_continues: hello
    ... """))
    yaml_starts_here: hello
    yaml_continues: hello

    >>> print(fuzzy_yaml_fixer("""
    ... here is some thinking text from the llm output before the yaml
    ...
    ... sometimes there are multiple paragraphs
    ...
    ... yaml_starts_here: hello
    ... yaml_continues: hello
    ... """))
    yaml_starts_here: hello
    yaml_continues: hello

    >>> print(fuzzy_yaml_fixer("""
    ... Here is the YAML response:
    ... files_to_write:
    ...   - path: test.py
    ...     file_contents: |
    ...       print("hello")
    ... message: Add test
    ... """))
    files_to_write:
      - path: test.py
        file_contents: |
          print("hello")
    message: Add test
    '''
    lines = raw.split("\n")

    # Try to find matching top-level code fences (```yaml or ```)
    first_fence = None
    last_fence = None
    for i, line in enumerate(lines):
        if re.match(r"^```(ya?ml)?\s*$", line, re.IGNORECASE):
            if first_fence is None:
                first_fence = i
            else:
                last_fence = i

    # If we found a matching pair of fences, extract content between them
    if first_fence is not None and last_fence is not None:
        raw = "\n".join(lines[first_fence + 1:last_fence])
    else:
        # No code fences found, try to strip leading prose text by finding
        # the first line that looks like YAML (key: value or list item)
        lines = raw.strip().split("\n")
        yaml_start_pattern = re.compile(
            r'^([a-zA-Z_][a-zA-Z0-9_]*:\s|[a-zA-Z_][a-zA-Z0-9_]*:$|- )'
        )
        for i, line in enumerate(lines):
            if yaml_start_pattern.match(line):
                raw = "\n".join(lines[i:])
                break

    return raw.strip()


def main() -> int:
    fixed_yaml = fuzzy_yaml_fixer(sys.stdin.read())
    sys.stdout.write(json.dumps(yaml.safe_load(fixed_yaml)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
