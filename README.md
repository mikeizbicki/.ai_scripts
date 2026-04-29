# Scripts for working with LLMs from the command line

## Setup

These scripts are designed to live in your home folder and be sourced from your bashrc file.
They can be installed with the following commands:
```
$ cd "$HOME"
$ git clone https://github.com/mikeizbicki/.ai_scripts
$ echo >> .bashrc <<'EOF'
source .ai_scripts/geni.sh
EOF
```

## Examples

### llm

The scripts define a number of aliases around the `llm` command that automatically call the appropriate model and compute cost for a query based on token usage.
For example
```
$ opus 'hello'
Hello! How can I help you today?

cost: $0.0008 (input: $0.0005, output: $0.0003) --cid=01kqawtph82nvh7y9cbwpzwk5v
```

### geni

The `geni` command is a wrapper around the `llm` command that automatically commits writes files to the disk and creates appropriate commit messages.
```
$ mkdir tmp
$ cd tmp
$ git init
$ geni 'create a file primes.py that prints the first 100 prime numbers'
request sent... receiving... primes.py(full)...
cost: $0.0000 (input: $0.0000, output: $0.0000) --cid=01kqawy4dwayne80cnpzrdcv35

Add primes.py to print first 100 primes
 primes.py | 19 +++++++++++++++++++
 1 file changed, 19 insertions(+)
$ geni -c 'add doctests'
request sent... receiving... primes.py(full)...
cost: $0.0000 (input: $0.0000, output: $0.0000) --cid=01kqawy4dwayne80cnpzrdcv35

Add doctests to primes.py
 primes.py | 27 +++++++++++++++++++++++++--
 1 file changed, 25 insertions(+), 2 deletions(-)
$ git log
commit 63a4c6a80c5b643dee532ca6be5f5ebea47fca4b (HEAD -> master)
Author: Mike Izbicki <mike@izbicki.me>
Date:   Tue Apr 28 13:37:28 2026 -0700

    [geni] Add doctests to primes.py

commit 738ef38e1b818528c1d2f392173e94672553c11f
Author: Mike Izbicki <mike@izbicki.me>
Date:   Tue Apr 28 13:36:54 2026 -0700

    [geni] Add primes.py to print first 100 primes
```

Openrouter maintains a list of most popular AI coding models:
1. <https://openrouter.ai/collections/programming>
