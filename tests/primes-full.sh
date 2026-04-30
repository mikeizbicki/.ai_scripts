#!/bin/bash

set -e

# source the geni.sh script
scriptpath=$(readlink -f "$0")
genipath="$(dirname "$scriptpath")/../geni.sh"
source "$genipath"

# move to a temp folder
tmpdir=$(mktemp -d) && cd "$tmpdir"
#tmpdir=$(mktemp -d) && cd "$tmpdir"&& trap "rm -rf $tmpdir" EXIT 

# print a prompt and run a command
run() {
    echo "\$ $*"
    "$@" || exit $?
    echo 
}

# the actual shell session starts here
run pwd
run git init
run sh -c "echo __pycache__ > .gitignore"
run git add .gitignore
run git commit -m 'add gitignore'
run geni 'create a file primes.py that computes the first 100 primes'
run python3 -m doctest primes.py
run geni -c 'add doctests (write full file)'
run python3 -m doctest primes.py
