# This file defines the function `geni` which is a minimal coding agent
# built as a thin wrapper around simonw's `llm` cli tool and `git am`.
# It is intended as a beginner-friendly intro to the "unix philosophy"
# and how AI coding agents work.

# source the llm_utils.sh helper script
geni_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$geni_script_dir/shell/llm_utils.sh"

function geni() {

    ####################
    # STEP 1: sanity check the git repo
    ####################
    # `git am` refuses to run if the working tree or index is dirty,
    # so we check up front to give a clearer error message.
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "geni: error: not inside a git repository" >&2
        return 1
    fi
    if ! git diff --quiet --cached; then
        echo "geni: error: staging area is non-empty; commit or reset first" >&2
        return 1
    fi
    if ! git diff --quiet; then
        echo "geni: error: working tree has uncommitted changes" >&2
        return 1
    fi

    ####################
    # STEP 2: set up a place to stash intermediate files
    ####################
    # Everything goes under .git/.geni so it survives across invocations
    # and can be inspected when debugging a failed patch.
    # `git rev-parse --git-dir` works even from subdirectories of the repo.
    local geni_dir
    geni_dir="$(git rev-parse --git-dir)/.geni"
    mkdir -p "$geni_dir"

    local patch_file="$geni_dir/patch.mbox"
    local err_file="$geni_dir/llm_stderr"

    ####################
    # STEP 3: invoke the llm
    ####################
    # We pass the user's request as positional args to llm.
    # stderr is captured separately so we can show it only on failure.
    # Use a subshell so `set -o pipefail` doesn't leak into the caller's shell.
    if ! (
        set -o pipefail
        llm_wrapper -s "$(geni_prompt)" \
            "$@" \
        | geni_tee >"$patch_file"
    ); then
        echo "geni: error: llm invocation failed" >&2
        return 1
    fi

    ####################
    # STEP 4: apply the patch (and create the commit) with git am
    ####################
    # On failure, `git am` leaves the repo in a "middle of am" state;
    # we abort it so the user can retry cleanly.
    if ! git-am-recount "$patch_file"; then
    #if ! git am --ignore-whitespace -C0 "$patch_file"; then
        echo "geni: error: git am failed to apply the patch" >&2
        echo "geni: aborting the failed am so the repo is clean again" >&2
        git am --abort 2>/dev/null
        echo "geni: inspect the patch at: $patch_file" >&2
        echo "geni: you can manually fix it and re-run: git am --ignore-whitespace -C0 '$patch_file'" >&2
        return 1
    fi

    ####################
    # STEP 5: success
    ####################
    # Show a short summary of the commit we just made.
    git show HEAD --stat --format='%h %s'
}


# git apply supports a --recount flag that makes patches more flexible;
# git am does not support the flag;
# the code below is a re-implementation of git am that does support the flag
git-am-recount() {
    local mbox="$1" tmp
    tmp=$(mktemp -d)
    # LLMs sometimes emit reasoning/preamble before the actual patch.
    # Strip anything before the first 'From:' header so mailsplit can
    # recognize the message. We do this on a copy so $mbox (the raw LLM
    # output) is preserved for debugging.
    sed -n '/^From:/,$p' "$mbox" > "$tmp/cleaned.mbox"
    local count
    count=$(git mailsplit -b -o"$tmp" "$tmp/cleaned.mbox")
    if [[ -z "$count" || "$count" -eq 0 ]]; then
        echo "git-am-recount: no valid mbox messages found in patch" >&2
        rm -rf "$tmp"
        return 1
    fi
    for msg in "$tmp"/[0-9]*; do
        git mailinfo "$tmp/m" "$tmp/p" < "$msg" > "$tmp/i"
        git apply --recount --ignore-whitespace -C0 "$tmp/p" || { rm -rf "$tmp"; return 1; }
        git add -A
        local a e d s
        a=$(sed -n 's/^Author: //p' "$tmp/i")
        e=$(sed -n 's/^Email: //p' "$tmp/i")
        d=$(sed -n 's/^Date: //p' "$tmp/i")
        s=$(sed -n 's/^Subject: //p' "$tmp/i")
        { echo "$s"; echo; cat "$tmp/m"; } | git commit --quiet -F - --author="$a <$e>" --date="$d"
    done
    rm -rf "$tmp"
}

# We tell the llm to emit a single mbox-formatted patch.
# The schema we describe is the *minimum* that `git am` actually needs;
# see `man git-format-patch` for the full format.
function geni_prompt() {
    cat <<EOF
You are a coding agent. The user will describe a change they want made to
a git repository. You must respond with a single patch in git mbox format
(the format produced by `git format-patch`) and NOTHING else.

The response MUST follow this exact structure:

    From: Geni <geni@localhost>
    Date: $(date -R)
    Subject: [geni] imperative summary, <50 chars>

    <optional longer explanation paragraph>

    ---
    diff --git a/path/to/file b/path/to/file
    --- a/path/to/file
    +++ b/path/to/file
    @@ -<old_start>,<old_count> +<new_start>,<new_count> @@
     context line
    -removed line
    +added line
     context line

Rules:
- Do NOT wrap your response in markdown code fences.
- Do NOT include any prose before or after the patch.
- The first line of your response MUST begin with 'From:'. Do not output any reasoning, explanation, or whitespace before it.
- The Subject line MUST start with '[geni] '.
- Use standard unified diff syntax with '--- a/...' and '+++ b/...' headers.
- For new files use '--- /dev/null' and '+++ b/path'.
    - You must also specify the mode of the new file
      (Add the text "new file mode 100644")
- For deleted files use '--- a/path' and '+++ /dev/null'.
- Hunk line numbers do not have to be exact (git will recount them),
  but the context lines must be recognizable in the current file.
- Include 2-3 lines of unchanged context around each change.
    - These context lines must exactly match the original document.
      (Including whitespace, quotation marks, and other punctuation.)
- Prefer small, focused patches.

Use the following information to help you write the code:

$ git ls-files
$(git ls-files)
EOF
}


# geni_tee streams the llm output through to stdout while printing a
# human-readable progress indicator to stderr. It is adapted from the
# yaml-oriented version in shell/geni.sh to instead understand the
# unified-diff / mbox format that this version of geni uses.
function geni_tee() {
    printf "${__ORANGE}request sent... " >&2

    local first_line=true
    local output=""
    local current_path=""
    local in_hunk=false
    local line_counter=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" == true ]]; then
            printf "receiving..." >&2
            first_line=false
        fi

        output+="$line"$'\n'

        # NOTE:
        # the code below "dynamically parses" the unified diff output;
        # it is not fully correct, but is close enough for a progress display.
        # we do not use a full diff parser because we want to stream the
        # progress as the data arrives. Any misparse here affects only the
        # progress indicator, not the final patch that gets applied.

        # Detect a new file in the diff: "diff --git a/foo b/foo"
        if [[ "$line" =~ ^diff\ --git\ a/(.+)\ b/(.+)$ ]]; then
            current_path="${BASH_REMATCH[2]}"
            in_hunk=false
            line_counter=0
            continue
        fi

        # Detect a new-file marker: "--- /dev/null" on the previous-style line
        # means the next +++ b/path is a brand new file.
        if [[ "$line" =~ ^\+\+\+\ b/(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
            continue
        fi

        # Detect "new file mode" marker -> announce a full new file
        if [[ "$line" =~ ^new\ file\ mode ]]; then
            printf " $current_path(new)..." >&2
            in_hunk=false
            line_counter=0
            continue
        fi

        # Detect a hunk header: "@@ -1,2 +1,3 @@"
        if [[ "$line" =~ ^@@ ]]; then
            if [[ "$in_hunk" == false && -n "$current_path" ]]; then
                printf " $current_path(patch)..." >&2
            fi
            in_hunk=true
            line_counter=0
            continue
        fi

        # Print a dot every 10 lines while we're inside a hunk / file body.
        if [[ -n "$current_path" ]]; then
            ((line_counter++))
            if (( line_counter % 10 == 0 )); then
                printf "." >&2
            fi
        fi
    done
    printf "\n" >&2
    printf '%s' "$output"
}
