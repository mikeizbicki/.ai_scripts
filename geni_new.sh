# geni_new.sh
#
# This file should be sourced from .bashrc.
# It defines a single function `geni` which is a minimal coding agent
# built as a thin wrapper around simonw's `llm` cli tool and `git am`.

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
    # STEP 3: build the system prompt
    ####################
    # We tell the llm to emit a single mbox-formatted patch.
    # The schema we describe is the *minimum* that `git am` actually needs;
    # see `man git-format-patch` for the full format.
    local system_prompt
    system_prompt="$(cat <<'EOF'
You are a coding agent. The user will describe a change they want made to
a git repository. You must respond with a single patch in git mbox format
(the format produced by `git format-patch`) and NOTHING else.

The response MUST follow this exact structure:

    From: Geni <geni@localhost>
    Date: <RFC 2822 date>
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
- The Subject line MUST start with `[geni] `.
- Use standard unified diff syntax with `--- a/...` and `+++ b/...` headers.
- For new files use `--- /dev/null` and `+++ b/path`.
    - You must also specify the mode of the new file
- For deleted files use `--- a/path` and `+++ /dev/null`.
- Hunk line numbers do not have to be exact (git will recount them),
  but the context lines must be recognizable in the current file.
- Include 2-3 lines of unchanged context around each change.
    - These context lines must exactly match the original document.
      (Including whitespace, quotation marks, and other punctuation.)
- Prefer small, focused patches.
EOF
)"

    ####################
    # STEP 4: warm-start the assistant's reply
    ####################
    # By pre-filling the first few lines of the response we:
    #   (a) lock in the correct mbox headers so the llm cannot wander off
    #       into markdown or prose, and
    #   (b) inject the *real* current date, which llms are notoriously
    #       bad at producing themselves.
    # `date -R` prints an RFC 2822 date, which is exactly what mbox wants.
    local warmstart
    warmstart="$(cat <<EOF
From: Geni <geni@localhost>
Date: $(date -R)
Subject: [geni]
EOF
)"

    ####################
    # STEP 5: invoke the llm
    ####################
    # We pass the user's request as positional args to llm.
    # stderr is captured separately so we can show it only on failure.
    #
    # NOTE: the exact flag to warm-start a response varies between llm
    # backends. The `-o prefill ...` option works for Anthropic models
    # via the llm-anthropic plugin. If your backend does not support
    # prefill, you can instead `printf` the warmstart into the patch
    # file before appending the llm output.
    echo "geni: calling llm..." >&2
    if ! llm -s "$system_prompt" \
             -o prefill "$warmstart" \
             "$@" \
             >"$patch_file" 2>"$err_file"; then
        echo "geni: error: llm invocation failed" >&2
        echo "----- llm stderr -----" >&2
        cat "$err_file" >&2
        echo "----------------------" >&2
        return 1
    fi

    # Some backends do not echo the prefill back into stdout.
    # To be safe, ensure the patch file actually starts with the
    # expected mbox header. If not, prepend the warmstart ourselves.
    if ! head -n1 "$patch_file" | grep -q '^From: '; then
        local tmp="$geni_dir/patch.mbox.tmp"
        { printf '%s\n' "$warmstart"; cat "$patch_file"; } >"$tmp"
        mv "$tmp" "$patch_file"
    fi

    ####################
    # STEP 6: show the patch to the user
    ####################
    # Always print what we are about to apply.
    # Wehn `git am` fails this helps the user figure out why.
    echo "geni: generated patch saved to $patch_file" >&2
    echo "----- patch -----" >&2
    cat "$patch_file" >&2
    echo "-----------------" >&2

    ####################
    # STEP 7: apply the patch (and create the commit) with git am
    ####################
    # --ignore-whitespace: tolerate whitespace differences in context
    # --recount:           recompute hunk line counts from the actual diff,
    #                      so the llm does not need to count lines correctly
    #
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
    # STEP 8: success
    ####################
    # Show a short summary of the commit we just made.
    echo "geni: applied successfully" >&2
    git show HEAD --stat --format='%h %s'
}

git-am-recount() {
    local mbox="$1" tmp
    tmp=$(mktemp -d)
    git mailsplit -b -o"$tmp" "$mbox" >/dev/null
    for msg in "$tmp"/[0-9]*; do
        git mailinfo "$tmp/m" "$tmp/p" < "$msg" > "$tmp/i"
        git apply --recount --ignore-whitespace -C0 "$tmp/p" || { rm -rf "$tmp"; return 1; }
        git add -A
        local a e d s
        a=$(sed -n 's/^Author: //p' "$tmp/i")
        e=$(sed -n 's/^Email: //p' "$tmp/i")
        d=$(sed -n 's/^Date: //p' "$tmp/i")
        s=$(sed -n 's/^Subject: //p' "$tmp/i")
        { echo "$s"; echo; cat "$tmp/m"; } | git commit -F - --author="$a <$e>" --date="$d"
    done
    rm -rf "$tmp"
}
