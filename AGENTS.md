# Agent Guidelines

## Philosophy

The purpose of this repo is primarily educational.
- The target audience is 2nd-semester CS students who have some python background but are new to the shell.
- Prefer simple code, even when complex code is faster/more concise.
- Prioritize correctness (e.g. enforcing security boundaries, handling edge cases with shell quoting)
- Provide detailed comments that explain the *why*.

## Project structure

- python/
    - contains non-LLM code for processing output
    - all "interesting" code should be put in side-effect-free functions that can be easily tested with doctests
    - any IO code should be a thin wrapper around the pure functions
    - these scripts will always take their main input via stdin, and use flags (via argparse) to control behavior
    - every python file corresponds to a single shell program
        - the pyproject.toml must always be kept up-to-date
- shell/
    - contains the actual shell scripts that are a thin wrapper around llm 
- tests/
    - contains integration test scripts for the shell scripts (python always tested via doctests)
