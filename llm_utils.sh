# This file should be sourced from .bashrc

function fancyllm() {(
    #model=anthropic/claude-sonnet-4-0
    #cost_input=3
    #cost_output=15

    model=anthropic/claude-opus-4-5-20251101
    cost_input=5
    cost_output=25

    #model=anthropic/claude-sonnet-4-5-20251101
    #cost_input=2
    #cost_output=15
#
    #model=anthropic/claude-haiki-4-5-20251101
    #cost_input=1
    #cost_output=5

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
        printf "cost: $%.4f (input: $%0.4f, output: $%0.4f) --cid=$latest_cid\n" "$cost_total" "$cost_input" "$cost_output" >&2
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

