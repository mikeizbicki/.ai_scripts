#!/usr/bin/env python3
import json
import re
import sys

import yaml


def fuzzy_yaml_to_json(raw: str) -> str:
    r"""
    Convert YAML input into compact JSON while tolerating top-level code fences.

    The conversion is "fuzzy" in that it strips only a wrapping pair of
    top-level markdown code fences. Indented code fences inside YAML block
    scalars are preserved as data.

    >>> fuzzy_yaml_to_json(
    ...     "message: hello\n"
    ... )
    '{"message": "hello"}'

    >>> fuzzy_yaml_to_json(
    ...     "```yaml\n"
    ...     "message: hello\n"
    ...     "```\n"
    ... )
    '{"message": "hello"}'

    >>> fuzzy_yaml_to_json(
    ...     "```\n"
    ...     "message: hello\n"
    ...     "```\n"
    ... )
    '{"message": "hello"}'

    >>> fuzzy_yaml_to_json(
    ...     "body: |\n"
    ...     "  ```yaml\n"
    ...     "  not a fence\n"
    ...     "  ```\n"
    ... )
    '{"body": "```yaml\\nnot a fence\\n```\\n"}'
    """
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

    raw = raw.strip()
    return json.dumps(yaml.safe_load(raw))


def main() -> int:
    sys.stdout.write(fuzzy_yaml_to_json(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
