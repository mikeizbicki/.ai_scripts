#!/usr/bin/env python3
"""
Apply find/replace patches to files.

This script reads a JSON patch specification from stdin and applies it to a file.
The patch format is a list of {find, replace} objects applied in order.
"""

import argparse
import json
import re
import sys
from typing import TypedDict


class PatchOperation(TypedDict):
    find: str
    replace: str


def normalize_whitespace(text: str) -> str:
    """
    Normalize whitespace for fuzzy matching.
    
    - Strips trailing whitespace from each line
    - Normalizes line endings to \\n
    
    >>> normalize_whitespace("hello  \\nworld\\t\\n")
    'hello\\nworld\\n'
    >>> normalize_whitespace("  foo  \\n  bar  ")
    '  foo\\n  bar'
    >>> normalize_whitespace("a\\r\\nb\\r\\n")
    'a\\nb\\n'
    """
    # Normalize line endings
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    # Strip trailing whitespace from each line
    lines = text.split('\n')
    lines = [line.rstrip() for line in lines]
    return '\n'.join(lines)


def apply_patches(content: str, patches: list[PatchOperation], fuzzy_match: bool = True) -> str:
    """
    Apply a list of find/replace patches to content.
    
    Each patch must match exactly one location in the content.
    Patches are applied in order, so later patches see the result of earlier ones.
    
    Args:
        content: The original file content
        patches: List of {find, replace} operations
        fuzzy_match: If True, normalize whitespace before matching
        
    Returns:
        The patched content
        
    Raises:
        ValueError: If a find string matches zero or multiple locations
        
    Basic usage:
    >>> apply_patches("hello world", [{"find": "world", "replace": "universe"}])
    'hello universe'
    
    Multiple patches applied in order:
    >>> apply_patches("a b c", [{"find": "a", "replace": "x"}, {"find": "x b", "replace": "y"}])
    'y c'
    
    Multiline patches:
    >>> content = "line1\\nline2\\nline3\\nline4"
    >>> patches = [{"find": "line2\\nline3", "replace": "new2\\nnew3"}]
    >>> apply_patches(content, patches)
    'line1\\nnew2\\nnew3\\nline4'
    
    Fuzzy matching ignores trailing whitespace:
    >>> apply_patches("hello  \\nworld", [{"find": "hello\\nworld", "replace": "hi"}], fuzzy_match=True)
    'hi'
    
    Exact matching fails on whitespace differences:
    >>> apply_patches("hello  \\nworld", [{"find": "hello\\nworld", "replace": "hi"}], fuzzy_match=False) # doctest: +ELLIPSIS
    Traceback (most recent call last):
        ...
    ValueError: PATCH_NOT_FOUND: Could not find text in file...
    
    Error when find matches nothing:
    >>> apply_patches("hello world", [{"find": "xyz", "replace": "abc"}]) # doctest: +ELLIPSIS
    Traceback (most recent call last):
        ...
    ValueError: PATCH_NOT_FOUND: Could not find text in file...
    
    Error when find matches multiple locations:
    >>> apply_patches("hello hello", [{"find": "hello", "replace": "hi"}]) # doctest: +ELLIPSIS
    Traceback (most recent call last):
        ...
    ValueError: PATCH_MULTIPLE_MATCHES: Found 2 matches for text...
    
    Empty find string should error:
    >>> apply_patches("hello", [{"find": "", "replace": "x"}]) # doctest: +ELLIPSIS
    Traceback (most recent call last):
        ...
    ValueError: PATCH_EMPTY_FIND: The 'find' field cannot be empty...
    
    Patches with context lines for uniqueness:
    >>> content = "def foo():\\n    x = 1\\n\\ndef bar():\\n    x = 1"
    >>> patches = [{"find": "def foo():\\n    x = 1", "replace": "def foo():\\n    x = 2"}]
    >>> print(apply_patches(content, patches))
    def foo():
        x = 2
    <BLANKLINE>
    def bar():
        x = 1
    
    Deleting text (replace with empty string):
    >>> apply_patches("a b c", [{"find": " b", "replace": ""}])
    'a c'
    
    Adding text where none existed (using context):
    >>> apply_patches("line1\\nline2", [{"find": "line1\\n", "replace": "line1\\nnewline\\n"}])
    'line1\\nnewline\\nline2'
    """
    result = content
    
    for i, patch in enumerate(patches):
        find_text = patch["find"]
        replace_text = patch["replace"]
        
        if not find_text:
            raise ValueError(
                f"PATCH_EMPTY_FIND: The 'find' field cannot be empty.\n"
                f"Patch index: {i}\n"
                f"FIX: Provide the exact text you want to find and replace."
            )
        
        if fuzzy_match:
            # Normalize both content and search text for matching
            normalized_result = normalize_whitespace(result)
            normalized_find = normalize_whitespace(find_text)
            
            # Find all occurrences in normalized text
            matches = list(re.finditer(re.escape(normalized_find), normalized_result))
            
            if len(matches) == 0:
                # Try to provide helpful context
                preview = find_text[:100] + "..." if len(find_text) > 100 else find_text
                raise ValueError(
                    f"PATCH_NOT_FOUND: Could not find text in file.\n"
                    f"Patch index: {i}\n"
                    f"Looking for:\n{preview}\n\n"
                    f"FIX: Ensure the 'find' text exactly matches the file content. "
                    f"Include 2-3 lines of surrounding context to ensure a unique match. "
                    f"Check for typos, extra/missing whitespace, or incorrect indentation."
                )
            
            if len(matches) > 1:
                preview = find_text[:100] + "..." if len(find_text) > 100 else find_text
                raise ValueError(
                    f"PATCH_MULTIPLE_MATCHES: Found {len(matches)} matches for text.\n"
                    f"Patch index: {i}\n"
                    f"Looking for:\n{preview}\n\n"
                    f"FIX: Include more surrounding context lines in the 'find' field "
                    f"to uniquely identify the location you want to change."
                )
            
            # Map normalized position back to original
            # We need to find the corresponding position in the original text
            norm_start = matches[0].start()
            norm_end = matches[0].end()
            
            # Build mapping from normalized positions to original positions
            orig_pos = 0
            norm_pos = 0
            orig_lines = result.split('\n')
            norm_to_orig_start = {}
            
            rebuilt = []
            for line in orig_lines:
                stripped = line.rstrip()
                for j, char in enumerate(stripped):
                    norm_to_orig_start[norm_pos] = orig_pos + j
                    norm_pos += 1
                norm_to_orig_start[norm_pos] = orig_pos + len(stripped)
                norm_pos += 1  # for newline
                orig_pos += len(line) + 1  # original line + newline
            
            # Handle the case where normalized text doesn't end with newline
            # but we're at the very end
            if norm_pos - 1 not in norm_to_orig_start:
                norm_to_orig_start[norm_pos - 1] = len(result)
            
            orig_start = norm_to_orig_start.get(norm_start, norm_start)
            orig_end = norm_to_orig_start.get(norm_end, norm_end)
            
            result = result[:orig_start] + replace_text + result[orig_end:]
        else:
            # Exact matching
            matches = list(re.finditer(re.escape(find_text), result))
            
            if len(matches) == 0:
                preview = find_text[:100] + "..." if len(find_text) > 100 else find_text
                raise ValueError(
                    f"PATCH_NOT_FOUND: Could not find text in file.\n"
                    f"Patch index: {i}\n"
                    f"Looking for:\n{preview}\n\n"
                    f"FIX: Ensure the 'find' text exactly matches the file content. "
                    f"Include 2-3 lines of surrounding context to ensure a unique match. "
                    f"Check for typos, extra/missing whitespace, or incorrect indentation."
                )
            
            if len(matches) > 1:
                preview = find_text[:100] + "..." if len(find_text) > 100 else find_text
                raise ValueError(
                    f"PATCH_MULTIPLE_MATCHES: Found {len(matches)} matches for text.\n"
                    f"Patch index: {i}\n"
                    f"Looking for:\n{preview}\n\n"
                    f"FIX: Include more surrounding context lines in the 'find' field "
                    f"to uniquely identify the location you want to change."
                )
            
            start = matches[0].start()
            end = matches[0].end()
            result = result[:start] + replace_text + result[end:]
    
    return result


def patch_file(filepath: str, patches: list[PatchOperation], fuzzy_match: bool = True) -> None:
    """
    Apply patches to a file atomically.
    
    Reads the file, applies all patches, and writes back only if all succeed.
    
    Args:
        filepath: Path to the file to patch
        patches: List of {find, replace} operations
        fuzzy_match: If True, normalize whitespace before matching
    """
    try:
        with open(filepath, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {filepath}", file=sys.stderr)
        print(f"FIX: Check that the file path is correct and the file exists.", file=sys.stderr)
        sys.exit(1)
    except IOError as e:
        print(f"ERROR: Could not read file {filepath}: {e}", file=sys.stderr)
        sys.exit(1)
    
    try:
        patched_content = apply_patches(content, patches, fuzzy_match=fuzzy_match)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(filepath, 'w') as f:
            f.write(patched_content)
    except IOError as e:
        print(f"ERROR: Could not write file {filepath}: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Apply find/replace patches to a file.",
        epilog="Reads patch JSON from stdin. Format: [{\"find\": \"...\", \"replace\": \"...\"}]"
    )
    parser.add_argument("filepath", help="Path to the file to patch")
    parser.add_argument(
        "--no-fuzzy-match",
        action="store_true",
        help="Disable fuzzy matching (require exact whitespace match)"
    )
    args = parser.parse_args()
    
    try:
        patch_json = sys.stdin.read()
        patches = json.loads(patch_json)
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON input: {e}", file=sys.stderr)
        print(f"FIX: Ensure stdin contains valid JSON array of patch objects.", file=sys.stderr)
        sys.exit(1)
    
    if not isinstance(patches, list):
        print(f"ERROR: Expected JSON array of patches, got {type(patches).__name__}", file=sys.stderr)
        sys.exit(1)
    
    patch_file(args.filepath, patches, fuzzy_match=not args.no_fuzzy_match)


if __name__ == "__main__":
    main()
