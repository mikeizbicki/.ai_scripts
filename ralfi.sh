#!/bin/bash
# This file should be sourced from .bashrc
# It provides the `ralfi` command for iterative test-driven code generation.
#
# NAME ORIGIN:
# "ralfi" is the Latin vocative of "ralfus", a Latinization of "ralph".
# A "ralph loop" repeatedly calls an LLM until tests pass.
# Like geni, you are commanding a spirit to do your bidding.

# Ensure geni.sh is available (ralfi depends on geni)
source "$(dirname "${BASH_SOURCE[0]}")/geni.sh"

# Maximum number of iterations before giving up.
# This prevents infinite loops when the LLM cannot solve the problem.
# Users can override this with: RALFI_MAX_ITERATIONS=20 ralfi ...
RALFI_MAX_ITERATIONS="${RALFI_MAX_ITERATIONS:-10}"

function ralfi() {
    ####################
    # STEP 0: Parse arguments
    ####################
    # Usage: ralfi <test_command> [geni_args...] <<< "initial prompt"
    #
    # The test_command can be:
    #   - A path to an executable script (e.g., ./test.sh)
    #   - A shell command string (e.g., "python -m pytest tests/")
    #
    # All additional arguments are forwarded to geni.
    # The initial prompt comes from stdin (supports heredocs, pipes, etc.)

    if [ $# -lt 1 ]; then
        error 'usage: ralfi <test_command> [geni_args...] <<< "prompt"'
        hint 'example: ralfi "./test.sh" <<< "implement the foo function"'
        hint 'example: ralfi "pytest tests/" -m gpt-4o <<< "fix the tests"'
        return 1
    fi

    local test_cmd="$1"
    shift
    # Remaining args ($@) will be passed to geni

    ####################
    # STEP 1: Validate test command
    ####################
    # We need to determine if test_cmd is a file path or a shell command.
    # If it looks like a path (contains / or starts with .), verify it's executable.
    # Otherwise, verify the command exists via `command -v`.

    if [[ "$test_cmd" == ./* || "$test_cmd" == /* || "$test_cmd" == ../* ]]; then
        # Looks like a path
        if [ ! -e "$test_cmd" ]; then
            error "test file does not exist: $test_cmd"
            return 1
        fi
        if [ ! -x "$test_cmd" ]; then
            error "test file is not executable: $test_cmd"
            hint "run: chmod +x $test_cmd"
            return 1
        fi
    else
        # Shell command - extract the first word to check if it exists
        local first_word="${test_cmd%% *}"
        if ! command -v "$first_word" &>/dev/null; then
            error "command not found: $first_word"
            return 1
        fi
    fi

    ####################
    # STEP 2: Verify tests currently fail
    ####################
    # This is a sanity check. If tests already pass, there's nothing to do.
    # We capture output here to show it to the user if tests unexpectedly pass.

    echo "${__ORANGE}Running initial test to verify it fails...${__RESET}"
    local test_output
    test_output=$(eval "$test_cmd" 2>&1)
    local test_exit_code=$?

    if [ $test_exit_code -eq 0 ]; then
        error "tests already pass - nothing to do"
        hint "ralfi expects failing tests that need to be fixed"
        return 1
    fi

    echo "${__BLUE}Tests fail as expected (exit code: $test_exit_code). Starting ralfi loop.${__RESET}"

    ####################
    # STEP 3: Read initial prompt from stdin
    ####################
    # We consume stdin now because we'll need it for the first geni call.
    # Subsequent calls use -c to continue the conversation.

    local initial_prompt
    initial_prompt=$(cat)

    if [ -z "$initial_prompt" ]; then
        error "no prompt provided"
        hint 'provide a prompt via stdin: ralfi "test_cmd" <<< "your prompt"'
        return 1
    fi

    ####################
    # STEP 4: Ensure git repo is clean
    ####################
    # We need a clean state because we'll be creating branches and merging.
    # This is stricter than geni's check - we don't allow dirty repos at all.

    if ! git rev-parse --git-dir &>/dev/null; then
        error "not in a git repository"
        return 1
    fi

    if [ -n "$(git status --porcelain)" ]; then
        error "git repo is dirty - commit or stash changes first"
        hint "ralfi creates branches and merges, so it needs a clean state"
        return 1
    fi

    ####################
    # STEP 5: Create working branch
    ####################
    # We do all work in a separate branch so the user can easily:
    #   - See what changed (git diff main..ralfi_xxx)
    #   - Abort if something goes wrong (git checkout main; git branch -D ralfi_xxx)
    #   - Review before merging (if we don't auto-merge)
    #
    # Timestamp format: YYYYMMDD_HHMMSS (git-safe, no special chars)

    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD)
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    local working_branch="ralfi_${timestamp}"

    if ! git checkout -b "$working_branch" 2>/dev/null; then
        error "failed to create branch: $working_branch"
        return 1
    fi

    echo "${__BLUE}Created working branch: $working_branch${__RESET}"

    ####################
    # STEP 6: Initial geni call
    ####################
    # The first call uses the user's prompt directly.
    # We pass all extra arguments ($@) to geni.

    local iteration=1
    echo "${__ORANGE}[ralfi] Iteration $iteration${__RESET}"

    # Run geni with the initial prompt
    # Note: We use echo and pipe rather than <<< to preserve newlines properly
    if ! echo "$initial_prompt" | geni "$@"; then
        error "geni failed on iteration $iteration"
        __ralfi_abort "$original_branch" "$working_branch"
        return 1
    fi

    ####################
    # STEP 7: Main loop - iterate until tests pass
    ####################
    # After each geni call, run tests.
    # If they fail, construct a new prompt with the failure output and continue.
    # We use geni -c to continue the conversation, maintaining context.

    while true; do
        # Run tests and capture output
        echo "${__ORANGE}Running tests...${__RESET}"
        test_output=$(eval "$test_cmd" 2>&1)
        test_exit_code=$?

        if [ $test_exit_code -eq 0 ]; then
            echo "${__GREEN}Tests pass!${__RESET}"
            break
        fi

        iteration=$((iteration + 1))

        if [ $iteration -gt $RALFI_MAX_ITERATIONS ]; then
            error "max iterations ($RALFI_MAX_ITERATIONS) reached"
            hint "tests still failing - manual intervention required"
            hint "you are on branch '$working_branch' with partial progress"
            hint "set RALFI_MAX_ITERATIONS to increase the limit"
            # Don't abort - leave user on working branch with progress
            return 1
        fi

        echo "${__ORANGE}[ralfi] Iteration $iteration (tests failed with exit code $test_exit_code)${__RESET}"

        # Construct continuation prompt with test failure details
        # We include both the command and its output so the LLM has full context.
        # Truncate very long outputs to avoid token limits.
        local max_output_lines=100
        local truncated_output
        if [ "$(echo "$test_output" | wc -l)" -gt $max_output_lines ]; then
            truncated_output=$(echo "$test_output" | tail -n $max_output_lines)
            truncated_output="[... truncated to last $max_output_lines lines ...]
$truncated_output"
        else
            truncated_output="$test_output"
        fi

        local continuation_prompt="The previous changes did not fix the failing tests.

Test command: $test_cmd
Exit code: $test_exit_code

Test output:
\`\`\`
$truncated_output
\`\`\`

Please analyze the test failures and make the necessary fixes."

        # Continue conversation with -c flag
        # The -c flag must come before other args to be recognized by llm
        if ! echo "$continuation_prompt" | geni -c "$@"; then
            error "geni failed on iteration $iteration"
            hint "you are on branch '$working_branch' with partial progress"
            return 1
        fi
    done

    ####################
    # STEP 8: Finalize - merge back to original branch
    ####################
    # Strategy depends on number of iterations:
    #   - 1 iteration: simple fast-forward merge (preserves the single commit)
    #   - >1 iterations: squash into one commit with summary message
    #
    # The squash case uses llm to generate a good summary of all changes.

    local num_commits
    num_commits=$(git rev-list --count "$original_branch".."$working_branch")

    if [ "$num_commits" -eq 0 ]; then
        # Edge case: geni made no commits (shouldn't happen, but handle it)
        warning "no commits were made"
        git checkout "$original_branch"
        git branch -D "$working_branch"
        return 0
    fi

    if [ "$num_commits" -eq 1 ]; then
        # Simple case: fast-forward merge preserves the single [geni] commit
        echo "${__BLUE}Single iteration - fast-forward merging...${__RESET}"
        git checkout "$original_branch"
        git merge --ff-only "$working_branch"
        git branch -d "$working_branch"
    else
        # Multiple iterations: squash and generate summary
        echo "${__BLUE}Multiple iterations ($num_commits commits) - squashing...${__RESET}"

        # Collect all commit messages and diffs for the summary prompt
        local all_commits
        all_commits=$(git log --reverse --format="=== Commit: %s ===%n%b" "$original_branch".."$working_branch")
        
        local overall_diff
        overall_diff=$(git diff "$original_branch".."$working_branch")

        # Use llm to generate a summary commit message
        # We use the same model/settings that geni would use by default
        local summary_prompt="You are summarizing a series of iterative code changes made to fix failing tests.

The following commits were made:
$all_commits

The overall diff of all changes:
\`\`\`diff
$overall_diff
\`\`\`

Write a concise commit message (max 50 chars for subject line) summarizing what was accomplished.
Focus on the end result, not the iteration process.
Output ONLY the commit message, nothing else."

        echo "${__ORANGE}Generating summary commit message...${__RESET}"
        local summary_message
        summary_message=$(echo "$summary_prompt" | llm 2>/dev/null)
        
        if [ -z "$summary_message" ]; then
            # Fallback if llm fails
            summary_message="Fix failing tests (ralfi: $num_commits iterations)"
        fi

        # Prepend [ralfi] tag
        summary_message="[ralfi] $summary_message"

        # Perform the squash
        # We reset to original branch state, then commit all working branch changes
        local working_tree_state
        working_tree_state=$(git rev-parse "$working_branch")
        
        git checkout "$original_branch"
        
        # Soft reset to get working branch changes staged
        git merge --squash "$working_branch"
        git commit -m "$summary_message"

        # Clean up working branch
        git branch -D "$working_branch"

        echo "${__BLUE}$summary_message${__RESET}"
    fi

    echo "${__GREEN}[ralfi] Completed successfully in $iteration iteration(s)${__RESET}"
    git show HEAD --format="" --stat
}

####################
# Helper: Abort and return to original branch
####################
# Used when something goes wrong during the loop.
# Leaves the working branch intact so user can inspect/recover.

function __ralfi_abort() {
    local original_branch="$1"
    local working_branch="$2"
    
    warning "aborting ralfi"
    hint "working branch '$working_branch' preserved for inspection"
    hint "to return to original: git checkout $original_branch"
    hint "to delete working branch: git branch -D $working_branch"
}
