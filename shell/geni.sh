# This file should be sourced from .bashrc
# All global vars/functions should be prefixed with geni_.
# This ensures that there will be no name conflicts.

# source the llm_utils.sh helper script
geni_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$geni_script_dir/llm_utils.sh"

# geni is the main public interface
function geni() {

    ####################
    # STEP1: ensure git repo sane
    ####################
    # geni will be automatically making commits,
    # so we want git in a sane state before running
    if git status --porcelain | grep -q '^[MADRC]'; then
        error 'the staging area is non-empty'
        return 1
    fi
    if git status --porcelain | grep -Eq '^(\?\?|.[MD])'; then
        warning 'git repo dirty'
    fi

    ####################
    # STEP2: generate/apply the patch
    ####################
    (
        # we store all intermediate results in the .git/.geni folder;
        # this allows inspecting the results if needed to debug errors;
        # the incantation below gets the .git folder for the current repo
        # even if we are currently in a subfolder
        geni_dir="$(git rev-parse --git-dir)"/.geni
        mkdir -p "$geni_dir"

        # llm_wrapper can sometimes take a long time (minutes);
        # geni_tee creates a "progress" bar for llm_wrapper;
        # by default, if statements only consider the last command in the pipeline;
        # the set -o pipefail option enforces that all commands must succeed to enter the if block;
        # this is a "global" property, so we wrap this code in a subshell
        # to avoid changing the default behavior for the caller of this function
        set -o pipefail
        out_file="$geni_dir"/llm_stdout
        err_file="$geni_dir"/llm_stderr
        if llm_wrapper -s "$(geni_prompt)" "$@" 2>"$err_file" | geni_tee > "$out_file"; then
            printf "${__ORANGE}$(cat "$err_file")${__RESET}\n"
            cat "$out_file" | fuzzy_yaml_fix | geni_process_yaml
        else
            error 'llm failed'
            printf "${__RED}$(sed -e 's/Error:/ERROR:/' "$err_file")${__RESET}\n" >&2
            return 1
        fi
    )
}

################################################################################
# construct the system prompt
################################################################################
geni_response_schema="$(cat "$geni_script_dir/geni-response-schema.yaml")"

function geni_prompt() {
    # NOTE:
    # this is a function and not a variable so that it gets rebuilt on every invokation;
    # this for example ensures that the result of `git ls-files` is current
    # this is global so that it is easy to inspect the value of the prompt
    if [ -s "AGENTS.md" ]; then
        agents_prompt="
$ cat AGENTS.md
$(cat AGENTS.md)
"
    fi
    cat <<EOF
You are a coding agent. You will write files to achieve the tasks that the user specifies in their queries. Your response should always be in pure YAML and conform to the following schema:

<schema>
$geni_response_schema
</schema>

Do not include any markdown codeblocks or other explanations.

<example>
files_to_write:
  - path: src/main.py
    file_contents: |
      print("hello")
      print("world")
message: |
  Add basic hello world
</example>

<example>
files_to_write:
  - path: src/utils.py
    file_patch:
      - find: |
          def old_function():
              return 1
        replace: |
          def old_function():
              return 2
message: |
  Update return value in old_function
</example>

<example>
clarification_needed:
  The file src/utils.py was not provided. Please share its contents
  so I can add the requested helper function.
</example>

Use the following information to help guide your response.

\`\`\`$agents_prompt
$ git ls-files
$(git ls-files)
\`\`\`

Never modify tests unless the instructions specifically say to.

When editing existing files, prefer using file_patch over file_contents to reduce token usage.
In file_patch, always include 2-3 lines of surrounding context in the 'find' field to ensure unique matches.
EOF
}

################################################################################
# process the output of the LLM
################################################################################

function geni_process_yaml() {
    input=$(cat)
    geni_dir="$(git rev-parse --git-dir)"/.geni

    ####################
    # STEP0: validate input
    ####################

    # validate YAML syntax by attempting to parse it
    if ! echo "$input" | yq '.' > /dev/null 2>&1; then
        error 'llm failed to generate valid YAML'
        hint 'usually the YAML is almost valid, but has a minor syntax error'
        hint "the file '$geni_dir/llm_stdout' contains the raw llm output"
        hint "you can manually correct the file, then run \`cat '$geni_dir/llm_stdout' | geni_process_yaml'\`"
        return 1
    fi

    # validate schema
    if ! echo "$input" | yq '.' | jsonschema <(yq '.' <(echo "$geni_response_schema") ) 2>"$geni_dir"/check-jsonschema_stderr; then
        error 'llm response failed jsonschema check'
        hint "the file '$geni_dir/llm_stdout' contains the raw llm output"
        hint "you can manually correct the file, then run \`cat '$geni_dir/llm_stdout' | geni_process_yaml'\`"
        return 1
    fi

    ####################
    # STEP1: process clarification_needed
    ####################

    clarification=$(echo "$input" | yq -r '.clarification_needed // empty')
    if [ -n "$clarification" ]; then
        printf "${__YELLOW}Clarification needed:${__RESET}\n"
        printf "${__BLUE}%s${__RESET}\n" "$clarification"
        return 2
    fi

    ####################
    # STEP2: process file changes
    ####################

    # process each file in the response
    has_failure=false
    num_files=$(echo "$input" | yq '.files_to_write | length')
    for ((i=0; i<num_files; i++)); do
        path=$(echo "$input" | yq -r ".files_to_write[$i].path")

        mkdir -p "$(dirname "$path")"

        # determine if this is a full write or a patch
        if [ "$(echo "$input" | yq -r ".files_to_write[$i].file_contents")" != "null" ]; then
            # Full file write
            file_contents=$(echo "$input" | yq -r ".files_to_write[$i].file_contents")
            
            # apply the changes
            if [ -e "$path" ]; then
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
            fi

            echo "$file_contents" > "$path"
            git add "$path"
        elif [ "$(echo "$input" | yq -r ".files_to_write[$i].file_patch")" != "null" ]; then
            # Patch operation
            if [ ! -e "$path" ]; then
                error "cannot patch '$path': file does not exist"
                has_failure=true
                continue
            fi

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

            # Extract patches and apply
            patches_json=$(echo "$input" | yq -r ".files_to_write[$i].file_patch | tojson")
            if ! echo "$patches_json" | patch_file "$path" 2>"$geni_dir"/patch_stderr; then
                error "patch failed for '$path'"
                cat "$geni_dir"/patch_stderr >&2
                has_failure=true
                continue
            fi
            git add "$path"
        fi
    done

    # commit the changes
    # NOTE:
    # Latin purists may object to using the vocative "geni" in the commit message
    # (because the message is not directly calling on the "genius" daemon).
    # But we actually using the genitive of possession
    # (to say that this commit belongs to "genius").
    # It just so happens that geni is both the vocative and genitive form of genius.
    commit_message="[geni] $(echo "$input" | yq -r '.message')"
    if [ "$has_failure" = "false" ]; then
        echo -e "${__BLUE}$commit_message${__RESET}"
        git commit --quiet -m "$commit_message" 2>/dev/null 1>/dev/null
        if [ $? -ne 0 ]; then
            error 'git commit failed for unknown reason'
            warning 'sanitize repo before proceeding'
            return 1
        else
            git show HEAD --format="" --stat
        fi
    else
        error 'not running git commit'
        warning 'sanitize repo before proceeding'
        git reset
        return 1
    fi
}

function geni_tee() {
    # some functions take a long time to generate their output;
    # this helper can be used to monitor the progress of these functions;
    # it inspects the YAML stream to show file write progress
    printf "${__ORANGE}request sent... " >&2
    
    local first_line=true
    local output=""
    local in_files_section=false
    local current_path=""
    local write_type=""
    local line_counter=0
    
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
        
        # NOTE:
        # the code below "dynamically parses" the YAML output;
        # it is not fully correct (in that there are valid YAML outputs that will not get matched),
        # but it is close-enough that it seems to always work for LLM output;
        # we do not use a standard YAML parser because these need the entire input
        # document to be present, and we want to parse the input as it comes in;
        # the mild incorrectness is acceptable here because the purpose of this
        # code is only to display the progress of the download from the LLM API,
        # any incorrect parses affect these progress messages
        # but not the final result (which uses a correct YAML parser)
        if [[ "$in_files_section" == true ]]; then
            # Capture path
            if [[ "$line" =~ ^[[:space:]]{0,4}-[[:space:]]*path:[[:space:]]*(.+)$ ]]; then
                current_path="${BASH_REMATCH[1]}"
                line_counter=0
            fi
            
            # Detect file_contents (full write)
            if [[ "$line" =~ ^[[:space:]]{0,4}file_contents: ]]; then
                printf " $current_path(full)..." >&2
                line_counter=0
            fi
            
            # Detect file_patch (patch)
            if [[ "$line" =~ ^[[:space:]]{0,4}file_patch: ]]; then
                printf " $current_path(patch)..." >&2
            fi
        fi
        
        # Print a dot every 10 lines
        if [[ "$in_files_section" == true && -n "$current_path" ]]; then
            ((line_counter++))
            if (( line_counter % 10 == 0 )); then
                printf "." >&2
            fi
        fi
    done
    printf "\n" >&2
    echo "$output"
}
