#!/bin/bash
# This file should be sourced to get access to the functions in the shell

# this is a CSV format where the columns are:
# model_name, input_cost (per 1_000_000 tokens), output_cost (per 1_000_000 tokens)
MODEL_PRICES="
opus-4.6        , 5.00   , 25.00
opus-4.5        , 5.00   , 25.00
sonnet-4.5      , 2.00   , 15.00
sonnet-4.0      , 3.00   , 15.00
haiku-4.5       , 1.00   ,  5.00
gpt-5.4         , 2.50   , 15.00
gpt-5.2	        , 1.75	 , 14.00
gpt-5.1	        , 1.25	 , 10.00
gpt-5-mini	    , 0.25	 ,  2.00
gpt-5-nano	    , 0.05	 ,  0.40
gpt-4o          , 2.50   , 10.00
gpt-4o-mini     , 0.15   ,  0.60
"

alias haiku="llm_interactive -m claude-haiku-4.5"
alias sonnet="llm_interactive -m claude-sonnet-4.5"
alias opus="llm_interactive -m claude-opus-4.5"
alias gpt="llm_interactive -m gpt-5.2"
alias gpt-mini="llm_interactive -m gpt-5-mini"
alias gpt-nano="llm_interactive -m gpt-5-nano"

function llm_interactive() {
    llm_wrapper "$@" | info
}

function llm_pipe() {
    llm_wrapper "$@" | pipe_helper
}

function llm_wrapper() {(

    ####################
    # STEP1:
    # first we do bash-magic to parse arguments
    # and calculate the pricing for the selected model
    ####################

    # parse arguments to figure out model
    model="claude-opus-4.5"
    args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m=*|--model=*)
                model="${1#*=}"
                shift
                ;;
            -m|--model)
                model="$2"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${args[@]}"

    # Lookup pricing for model
    cost_input=0
    cost_output=0
    matched_model=""
    max_cost=0
    match_count=0

    while IFS=, read -r m ci co; do
        [[ -z "$m" ]] && continue
        m_trimmed=$(echo $m)
        if [[ "$model" == *"$m_trimmed"* ]]; then
            ((match_count++))
            total_cost=$(echo "$ci + $co" | bc -l)
            if (( $(echo "$total_cost > $max_cost" | bc -l) )); then
                max_cost="$total_cost"
                cost_input="$ci"
                cost_output="$co"
                matched_model="$m"
            fi
        fi
    done <<< "$MODEL_PRICES"

    if [[ $match_count -gt 1 ]]; then
        echo "Warning: multiple pricing matches for '$model', using most expensive: $matched_model" >&2
    elif [[ $match_count -eq 0 ]]; then
        echo "Warning: unknown model '$model', cost will show as \$0" >&2
    fi

    ####################
    # STEP2:
    # Now we do the actual interesting LLM stuff
    ####################

    system_prompt="Keep your response short, between 1-20 lines. Focus on a high signal to noise ratio. If the question is about a computer, respond for the following system: $(uname -a)."

    # Capture stderr while preserving stdout
    local stderr_file=$(mktemp)
    trap "rm -f '$stderr_file'" EXIT
    llm -s "$system_prompt" -m "$model" "$@" -u 2>"$stderr_file"
    stderr_content=$(cat "$stderr_file")
    local exit_code=$?
    latest_cid=$(llm logs list -n 1 --json | jq -r '.[] | .conversation_id' 2>/dev/null)
    # NOTE:
    # There is a minor race condition here.
    # The llm logs command above extracts the cid of the most recent conversation, which is almost certainly the conversation from the llm call above.
    # But it is possible that a concurrently running llm process terminates after the llm and before llm logs.
    # This shouldn't be a major concern in practice because this function is designed to be run interactively by a user and not inside a script.

    #echo "$stderr_content" | xclip -selection clipboard

    # Try to extract token usage from stderr
    if [[ $stderr_content =~ Token\ usage:\ ([0-9,]+)\ input,\ ([0-9,]+)\ output ]]; then
        input_tokens="${BASH_REMATCH[1]//,/}"
        output_tokens="${BASH_REMATCH[2]//,/}"
        cost_input=$(echo "scale=10; $cost_input * $input_tokens / 1000000" | bc -l)
        cost_output=$(echo "scale=10; $cost_output * $output_tokens / 1000000" | bc -l)
        cost_total=$(echo "scale=10; $cost_input + $cost_output" | bc -l)
        printf "\ncost: $%.4f (input: $%0.4f, output: $%0.4f) --cid=$latest_cid\n" "$cost_total" "$cost_input" "$cost_output" >&2
    else
        # If pattern doesn't match, display the stderr content
        if [[ -n $stderr_content ]]; then
            echo "$stderr_content" >&2
        fi
        input_tokens=""
        output_tokens=""
    fi

    return $exit_code
) # the function is enclosed in a subshell to trigger the TRAP for cleanup
}

################################################################################
# misc utils
################################################################################

function pipe_helper() {
    # some functions take a long time to generate their output;
    # this helper can be used to monitor the progress of these functions;
    # it prints a . to stderr periodically as it receives lines from stdin
    printf "request sent... " >&2
    
    local line_count=0
    local first_line=true
    local output=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" == true ]]; then
            printf "receiving..." >&2
            first_line=false
        fi
        
        output+="$line"$'\n'
        ((line_count++))
        if (( line_count % 10 == 0 )); then
            printf '.' >&2
        fi
    done
    echo >&2
    echo "$output"
}

__BLUE='\033[38;5;39m'
__ORANGE='\033[38;5;208m'
__RED='\033[38;5;196m'
__RESET='\033[0m'

function info() {
    if [ -z "$1" ]; then
        printf "${__BLUE}%s${__RESET}\n" "$(cat)"
    else
        printf "${__BLUE}%s${__RESET}\n" "$*"
    fi
}

function warning() {
}

function error() {
    printf "ERROR: " >&2
    print_color 196 "$@" >&2  # red
}

################################################################################
# sanity checks
################################################################################

function __check_dependencies() {
    local tools=(llm files-to-prompt ttok jq bc jsonschema python3 wiggle patch)
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || warning ".ai_scripts missing dependency: $tool"
    done
}
__check_dependencies
