# This file should be sourced from .bashrc



# NOTE:
# All variables should be prefixed with __GENIUS__.
# This ensures that there will be no name conflicts with other variables when sourcing into the .bashrc file.

__GENIUS__MAX_FILE_LINES=300
__GENIUS__MAX_DISPLAY_SIZE=20

################################################################################
# ensure llm_utils.sh available
################################################################################

source "$(dirname "${BASH_SOURCE[0]}")/llm_utils.sh"

################################################################################
# construct the system prompt
################################################################################

__GENIUS__RESPONSE_SCHEMA='
type: object
required: ["response_type", "message"]
properties:
  response_type:
    type: string
    enum: ["write_files", "more_info_needed", "answer"]
    description:
      If "write_files", then files_to_write must have at least one entry.
      If "more_info_needed" or "answer", then files_to_write should be empty.
      Select "answer" if the user asked a question and you are answering the question.
      Select "more_info_needed" if you need more information to either write files of answer the question.
  files_to_write:
    type: array
    items:
      type: object
      properties:
        path:
          type: string
          pattern: "^[a-zA-Z0-9_][a-zA-Z0-9_./-]*(/[a-zA-Z0-9_][a-zA-Z0-9_./-]*)*$"
          description:
            The path must be relative, and it may not include any hidden files.
        contents:
          type: string
          description:
            The exact contents of the file to write. Do not write to a file present in "git ls-files" unless you were given that file as input. If editing a file, you must make as few changes as possible in order to accomplish the specified task. For example, you must preserve any comments or poorly formatted code that is present in the original file unless specifically asked to change them.
            If the modified file would be greater than about '$__GENIUS__MAX_FILE_LINES', then suggest a plan for splitting the file into multiple files and only write the file if the user explicitly states they want to.
  message:
    type: string
    description: |
      If status_code is "success", provide a commit message for the changes in Tim Pope style. The message should have a 1 line imperative subject (<50 chars). Complicated commits can also have an additional paragraph up to 5 sentences. The message should be helpful to a programmer reviewing git logs, be as succinct as possible, and should focus on the *why* of the changes.
      If status_code is "response", then provide a short response between 1-20 sentences that answers the question. Use markdown formatting and appropriate technical jargon. Focus on a high signal-to-noise ratio.
      If status_code is "more_info_needed", ask a series of questions that the user should answer to help write the files/answer the question. The response should be between 1-5 questions, each question between 1-3 sentences (and as short as possible).
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
# construct the system prompt
################################################################################

function message() {
    printf "\033[94m"
    cat
    printf "\033[0m"
}

function print_color() {
    local color="$1"
    shift
    printf "\033[38;5;%sm" "$color"
    if [ -z "$1" ]; then
        cat
    else
        echo "$*"
    fi
    printf "\033[0m"
}

function info() {
    print_color 39 "$@"  # blue
}

function warning() {
    printf "WARNING: " >&2
    print_color 208 "$@" >&2  # orange
}

function error() {
    printf "ERROR: " >&2
    print_color 196 "$@" >&2  # red
}

function __GENIUS__ensure_git_sane() {
    if ! [ -z "$(git status --porcelain)" ]; then
        return 1
    fi
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

function __GENIUS__YAML2JSON() {
    python3 -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'
}

__GENIUS__test1=$(cat <<EOF
response_type: answer
files_to_write: []
message: |
  Based on the files listed, this project appears to be a configuration and scripts setup primarily focused on a Linux environment. The presence of xmonad configuration files suggests that it is likely tailored for a custom tiling window manager setup. Additionally, the existence of various scripts for networking (like VPN and SSHFS) and potentially for dual screen setups indicates that this project may be intended to enhance productivity and manage system preferences for a developer or power user working with multiple displays and remote connections.
EOF
)

__GENIUS__test2=$(cat <<EOF
response_type: "write_files"
files_to_write:
  - path: "hello.md"
    contents: |
      # Exemplum
      
      *salve munde*
  - path: "hello.html"
    contents: |
        <html>
        <head>
        <title>Exemplum</title>
        </head>
        <body>
        <h1>Exemplum</h1>
        <p><em>salve munde</em></p>
        </body>
        </html>
message: "Created files hello.md and hello.html."
EOF
)

__GENIUS__test3=$(cat <<EOF
response_type: "write_files"
files_to_write:
  - path: "../hello.md" # directory traversals should fail json schema test
    contents: |
      # Exemplum
      
      *salve munde*
message: "Created files hello.md and hello.html."
EOF
)

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

    json_response=$(echo "$input" | __GENIUS__YAML2JSON)
    schema=$(echo "$__GENIUS__RESPONSE_SCHEMA" | __GENIUS__YAML2JSON)

    # validate schema
    if ! (jsonschema -i <(echo "$json_response") <(echo "$schema")) >/dev/null 2>&1; then
        echo "$input" > .geni.raw
        echo "$json_response" > .geni.raw.json

        error 'llm response failed jsonschema check'
        error 'HINT: .geni.raw contains the raw llm output'
        error 'HINT: .geni.raw.json contains the converted json'

        return
    fi

    response_type=$(echo "$json_response" | jq -r .response_type)

    if [ "$response_type" = "write_files" ]; then
        # loop over each file that we might write
        num_files=$(echo "$json_response" | jq '.files_to_write | length')
        for ((i=0; i<num_files; i++)); do
            path=$(echo "$json_response" | jq -r ".files_to_write[$i].path")
            contents=$(echo "$json_response" | jq -r ".files_to_write[$i].contents")
            if [ -e "$path" ]; then
                action='edited'
                diff_output=$(diff -u "$path" <(echo "$contents") | __GENIUS__cleandiff)

                # backup $path if dirty
                dirty=false
                if ! git ls-files --error-unmatch "$path" 2>/dev/null; then
                    echo "WARNING: '$path' not in repo."
                    dirty=true
                fi
                if ! (git diff --quiet "$path" && git diff --cached --quiet "$path") ; then
                    echo "WARNING: '$path' has uncommitted changes"
                    dirty=true
                fi
                if [ "$dirty" = "true" ]; then
                    temp=$(mktemp)
                    cat "$path" > "$temp"
                    echo "WARNING: existing file will be overwritten"
                    echo "WARNING: backup created at '$temp'"
                fi

                # edit file
                echo "$contents" > "$path"
                git add "$path"
            else
                action='created'
                diff_output=$(diff -u /dev/null <(echo "$contents") | __GENIUS__cleandiff)

                # create file
                echo "$contents" > "$path"
                git add "$path"
            fi

            # display action summary
            add_lines=$(echo "$diff_output" | grep -c '^+')
            sub_lines=$(echo "$diff_output" | grep -c '^-')
            #echo "$action: '$path' (+$add_lines -$sub_lines lines)"
            #echo "$diff_output" | head -n $__GENIUS__MAX_DISPLAY_SIZE
        done

        # NOTE:
        # Latin purists may object to using the vocative "geni" in the commit message
        # (because the message is not directly calling on the "genius" daemon).
        # But we actually using the genitive of possession
        # (to say that this commit belongs to "genius").
        # It just so happens that geni is both the vocative and genitive form of genius.
        msg=$(echo "$json_response" | jq -r .message)
        echo "$msg" | message
        git commit --quiet -m "[geni] $msg"
        __GENIUS__git_diff

    # any other response_type, just output the message
    else
        msg=$(echo "$json_response" | jq -r .message)
        echo "$msg" | message
    fi
}

function geni() {
    if ! __GENIUS__ensure_git_sane; then
        #git status
        warning 'git repo dirty'
        #return
    fi
    fancyllm -x -s "$(geni_prompt)" "$@" | __GENIUS__process_response
}
