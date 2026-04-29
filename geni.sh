#!/bin/bash
# This file should be sourced from .bashrc

# NOTE:
# All variables should be prefixed with __GENIUS__.
# This ensures that there will be no name conflicts with other variables when sourcing into the .bashrc file.

__GENIUS__MAX_FILE_LINES=300
__GENIUS__MAX_DISPLAY_SIZE=20

# ensure llm_utils.sh available
source "$(dirname "${BASH_SOURCE[0]}")/llm_utils.sh"

# geni is the main public interface
function geni() {
    # geni will be automatically making commits,
    # so we want git in a sane state before running
    if git status --porcelain | grep -q '^[MADRC]'; then
        error 'the staging area is non-empty'
        return 1
    fi
    if git status --porcelain | grep -Eq '^(\?\?|.[MD])'; then
        warning 'git repo dirty'
    fi

    llm_wrapper -s "$(geni_prompt)" "$@" | pipe_helper | __GENIUS__process_response
}

################################################################################
# construct the system prompt
################################################################################

__GENIUS__RESPONSE_SCHEMA='
type: object
required: ["files_to_write", "message"]
properties:
  files_to_write:
    type: array
    items:
      type: object
      oneOf:
        - "required": ["patch_contents"]
        - "required": ["file_contents"]
      not:
        required: ["patch_contents", "file_contents"]
      properties:
        path:
          type: string
          pattern: "^[a-zA-Z0-9_.][a-zA-Z0-9_./-]*(/[a-zA-Z0-9_.][a-zA-Z0-9_./-]*)*$"
          description:
            The path must be relative and not contain directory traversal (..).
        patch_contents:
          type: string
          description:
            A unified diff describing the changes to make to the specified file. This field should be non-null when the changes are relatively localized in the file and so the diff is much smaller than the overall file size.
        file_contents:
          type: string
          description:
            The exact contents of the file to write. If editing a file, you must make as few changes as possible in order to accomplish the specified task. For example, you must preserve any comments or poorly formatted code that is present in the original file unless specifically asked to change them.
  message:
    type: string
    description: |
      A commit message for the changes in Tim Pope style. The message should have a 1 line imperative subject (<50 chars). Complicated commits can also have an additional paragraph up to 5 sentences. The message should be helpful to a programmer reviewing git logs, be as succinct as possible, and should focus on the *why* of the changes.
'

function geni_prompt() {
    # NOTE:
    # this is a function and not a variable so that it gets rebuilt on every invokation;
    # this for example ensures that the result of `git ls-files` is current
    # this is global so that it is easy to inspect the value of the prompt
    if [ -s "AGENTS.md" ]; then
        agents_prompt="$ cat AGENTS.md
$(cat "AGENTS.md")"
    fi
    cat <<EOF
You are a coding agent. You will write files to achieve the tasks that the user specifies in their queries. Your response should always be in pure YAML and conform to the following schema:
\`\`\`$__GENIUS__RESPONSE_SCHEMA\`\`\`

The response must be pure YAML; no markdown code blocks and no other explanations.

Example response for writing files:
\`\`\`
response_type: write_files
files_to_write:
  - path: src/main.py
    file_contents: |
      print("hello")
message: |
  Add main entry point
\`\`\`

Example response for answering:
\`\`\`
response_type: answer
message: |
  The error occurs because...
\`\`\`

Use the following information to help guide your response.
\`\`\`
$ uname -a
$(uname -a)
$agents_prompt
$ git ls-files
$(git ls-files)
\`\`\`
EOF
}

################################################################################
# process the output of the LLM
################################################################################

function __GENIUS__YAML2JSON() {
    python3 -c '
import sys, yaml, json, re

raw = sys.stdin.read()

# Try to extract from markdown code blocks (matched pairs)
match = re.search(r"```(?:ya?ml)?\s*\n(.*?)\n```", raw, re.DOTALL | re.IGNORECASE)
if match:
    raw = match.group(1)
else:
    # Handle uneven code block - discard everything after single ```
    if "```" in raw:
        raw = raw.split("```")[0]

raw = raw.strip()
json.dump(yaml.safe_load(raw), sys.stdout)
' 2>/dev/null
}

function __GENIUS__git_diff() {
    fulldiff=$(git show HEAD --format="" --stat --patch | awk '
/^ [^ ].*\|.*[+-]/ { stats[$1] = $0; next }
/^ *[0-9]+ file/ { next }
/^diff --git/ { file = $NF; sub(/b\//, "", file); if (stats[file]) print "\n" stats[file]; next }
/^index |^---|^\+\+\+/ { next }
/^@@ / { split($0, a, /[-+@ ,]+/); n = a[4]; next }
/^-/  { printf "%4d -%s\n", n, substr($0,2) }
/^\+/ { printf "%4d +%s\n", n++, substr($0,2) }
/^ / { printf "%4d  %s\n", n++, substr($0,2) }
')
    if [ "$(echo "$fulldiff" | wc -l)" -gt "$__GENIUS__MAX_DISPLAY_SIZE" ]; then
        git show HEAD --format="" --stat
    else
        echo "$fulldiff"
    fi
}

function __GENIUS__cleandiff() {
    awk '
/^---/ || /^\+\+\+/ { next }
/^@@/ {
    split($2,old,","); oline=int(substr(old[1],2))*-1
    split($3,new,","); nline=int(substr(new[1],2))-1
    next
}
/^-/ { printf "- %3d  │ %s\n", ++oline, substr($0,2); next }
/^\+/ { printf "+ %3d  │ %s\n", ++nline, substr($0,2); next }
/^ / { ++oline; printf "  %3d  │ %s\n", ++nline, substr($0,2) }
'
}

function __GENIUS__process_response() {
    input=$(cat)
    git_dir=$(git rev-parse --git-dir)
    echo "$input" > "$git_dir"/.geni.raw
    echo "$json_response" > "$git_dir"/.geni.raw.json

    json_response=$(echo "$input" | __GENIUS__YAML2JSON)
    if [ $? -ne 0 ]; then
        error 'failed to parse llm output as YAML'
        error "HINT: '$git_dir/.geni.raw' contains the raw llm output"
        error "HINT: '$git_dir/.geni.raw.json' contains the converted json"
        return 1
    fi
    schema=$(echo "$__GENIUS__RESPONSE_SCHEMA" | __GENIUS__YAML2JSON)

    # validate schema
    if ! (jsonschema -i <(echo "$json_response") <(echo "$schema")) >/dev/null 2>&1; then
        error 'llm response failed jsonschema check'
        error "HINT: '$git_dir/.geni.raw' contains the raw llm output"
        error "HINT: '$git_dir/.geni.raw.json' contains the converted json"
        return 1
    fi

    response_type=$(echo "$json_response" | jq -r .response_type)

    if [ "$response_type" = "write_files" ]; then
        has_failure=false
        # loop over each file that we might write
        num_files=$(echo "$json_response" | jq '.files_to_write | length')
        for ((i=0; i<num_files; i++)); do
            path=$(echo "$json_response" | jq -r ".files_to_write[$i].path")

            mkdir -p "$(dirname "$path")"

            # compute the new file contents;
            # if the contents was given in the response, just extract from json;
            # else (a diff was given in the response), then we compute file_contents from the diff
            if echo "$json_response" | jq -e ".files_to_write[$i].file_contents != null" > /dev/null; then
                file_contents=$(echo "$json_response" | jq -r ".files_to_write[$i].file_contents")
            else
                patch_contents=$(echo "$json_response" | jq -r ".files_to_write[$i].patch_contents")
                file_contents=$(echo "$patch_contents" | patch --fuzz=3 --output=- "$path" 2>/dev/null)
                if [ $? -ne 0 ]; then
                    warning "patch failed for '$path', using wiggle"
                    file_contents=$(wiggle --merge "$path" <(echo "$patch_contents") 2>/dev/null)
                    if [ $? -ne 0 ]; then
                        error 'wiggle was unable to apply patch'
                        has_failure=true
                    else
                        warning 'wiggle applied patch successfully'
                    fi
                fi
            fi

            # apply the changes
            if [ -e "$path" ]; then
                action='edited'
                diff_output=$(diff -u "$path" <(echo "$file_contents") | __GENIUS__cleandiff)

                # backup $path if dirty
                dirty=false
                if ! git ls-files --error-unmatch "$path" 2>/dev/null >/dev/null; then
                    warning "'$path' not in repo."
                    dirty=true
                fi
                if ! (git diff --quiet "$path" && git diff --cached --quiet "$path") ; then
                    warning "'$path' has uncommitted changes"
                    dirty=true
                fi
                if [ "$dirty" = "true" ]; then
                    temp=$(mktemp)
                    cat "$path" > "$temp"
                    warning "existing file will be overwritten"
                    warning "backup created at '$temp'"
                fi

                # edit file
                echo "$file_contents" > "$path"
                git add "$path"
            else
                action='created'
                diff_output=$(diff -u /dev/null <(echo "$file_contents") | __GENIUS__cleandiff)

                # create file
                echo "$file_contents" > "$path"
                git add "$path"
            fi
        done

        # NOTE:
        # Latin purists may object to using the vocative "geni" in the commit message
        # (because the message is not directly calling on the "genius" daemon).
        # But we actually using the genitive of possession
        # (to say that this commit belongs to "genius").
        # It just so happens that geni is both the vocative and genitive form of genius.
        msg=$(echo "$json_response" | jq -r .message)
        echo -e "${__BLUE}$msg${__RESET}"
        if [ "$has_failure" = "false" ]; then
            git commit --quiet -m "[geni] $msg" 2>/dev/null 1>/dev/null
            if [ $? -ne 0 ]; then
                error 'git commit failed'
            else
                __GENIUS__git_diff
            fi
        else
            error 'not running git commit'
        fi

    # any other response_type, just output the message
    else
        msg=$(echo "$json_response" | jq -r .message)
        echo -e "${__BLUE}$msg${__RESET}"
    fi
}

function pipe_helper() {
    # some functions take a long time to generate their output;
    # this helper can be used to monitor the progress of these functions;
    # it inspects the YAML stream to show file write progress
    printf "${__ORANGE}request sent... " >&2
    
    local first_line=true
    local output=""
    local in_files_section=false
    local current_path=""
    local write_type=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" == true ]]; then
            printf "receiving..." >&2
            first_line=false
        fi
        
        output+="$line"$'\n'
        
        # Detect files_to_write section
        if [[ "$line" =~ ^files_to_write: ]]; then
            in_files_section=true
            continue
        fi
        
        # Detect end of files section (new top-level key)
        if [[ "$in_files_section" == true && "$line" =~ ^[a-z_]+: && ! "$line" =~ ^[[:space:]] ]]; then
            in_files_section=false
        fi
        
        if [[ "$in_files_section" == true ]]; then
            # Capture path
            if [[ "$line" =~ ^[[:space:]]+-?[[:space:]]*path:[[:space:]]*(.+)$ ]]; then
                current_path="${BASH_REMATCH[1]}"
            fi
            
            # Detect file_contents (full write)
            if [[ "$line" =~ ^[[:space:]]+file_contents: ]]; then
                printf " $current_path(full)..." >&2
            fi
            
            # Detect patch_contents (patch)
            if [[ "$line" =~ ^[[:space:]]+patch_contents: ]]; then
                printf " $current_path(patch)..." >&2
            fi
        fi
    done
    printf "\n" >&2
    echo "$output"
}
