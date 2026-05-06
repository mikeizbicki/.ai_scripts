#!/bin/bash

# This function is useful for preprocesssing LLM prompts.
# It outputs each line of stdin.
# For each line that begins with a shell prompt '$',
# it additionally outputs the command's stdin/stdout to stdout.
# This results in the output of the commands also being included in the prompt.
# For example:
#
#   $ expand_shell_markdown <<'EOF'
#   Help me interpret the following command:
#   $ uname -a
#   What OS am I using?
#   EOF
#
# will generate output like the following:
#
#   Help me interpret the following command:
#   ```bash
#   $ uname -a
#   Linux laptop1 5.10.0-33-amd64 #1 SMP Debian 5.10.226-1 (2024-10-03) x86_64 GNU/Linux
#   ```
#   What OS am I using?
#
# Using the later output, an LLM can actually answer the posed question.
expand_shell_markdown() {
    local in_codeblock=false

    while IFS= read -r line; do
        if [[ $line == \$* ]]; then
            if [[ $in_codeblock == false ]]; then
                echo '```bash'
                in_codeblock=true
            fi
            echo "$line"
            eval "${line#\$}" 2>&1
        else
            if [[ $in_codeblock == true ]]; then
                echo '```'
                in_codeblock=false
            fi
            echo "$line"
        fi
    done

    # Close any open code block at the end
    if [[ $in_codeblock == true ]]; then
        echo '```'
    fi
}

function wtf() {
    # first we use kitty to get the content of our terminal session;
    screen_text=$(kitty @ get-text --extent=screen --self | head -n -1)
    screen_text=$(echo "$screen_text" | head -n -1)
    # NOTE: 
    # The kitty @ get-text command outputs the current contents of the screen to stdout. This content will contain the wtf command that has been typed into the terminal, which we remove with the 'head -n -1' command. This helps the LLM not get confused.

    # Many programs print files and line numbers in their error messages.
    # The following code scans the screen_text variable for any file names + line number combos,
    # and extracts portions of those files to add to the context.
    files_lines=$(echo "$screen_text" | grep "File \"" | sed 's/.*File "\([^"]*\)", line \([0-9]*\).*/\1:\2/')
    files_context=$(while IFS=: read -r filepath linenum; do
        #echo $filepath $linenum
        # Get relative path from current directory
        relpath=$(realpath --relative-to="$(pwd)" "$filepath" 2>/dev/null)

        # Check if file is within current directory (doesn't start with ../)
        if [[ "$relpath" != ../* ]] && [[ -f "$filepath" ]]; then
            echo "=== $filepath (around line $linenum) ==="
            # Show 10 lines before and after the error line, with line numbers
            startline=$((linenum-10 > 1 ? linenum-10 : 1))
            cat -n "$filepath" | sed -n "$startline,$((linenum+10))p"
            echo
        fi
    done <<< "$files_lines")

    prompt=$(cat <<EOF
The following is a copy/paste of my current terminal session.
There is an error message (or something else "weird"), and your job is to explain it.
Do not restate the error, only explain the cause and how to fix it.

\`\`\`
$screen_text
\`\`\`

Here is some potentially helpful system information.
All of the commands below were run after the terminal session above.

\`\`\`
$ uname -a
$(uname -a)
$ id
$(id)
$ pwd
$(pwd)
$ ls | head -n 50
$(ls | head -n 50)
$ ps | head -n 20
$(ps | head -n 20)
$ env | grep SSH
$(env | grep SSH)
\`\`\`

NOTE:
The head commands above may truncate the output of the informative commands. If that happens, and you need more output to understand the problem, say so.

$files_context

NOTE:
You must ensure the correctness of your response.
It is better to say that you do not understand the cause of an error (or that you need more information) than it is to state an incorrect cause of the error.
NEVER STATE FALSE INFORMATION.
EOF
)
    system='You are not having a conversation. Prioritize clarity and a high signal to noise ratio. Use technical terms as appropriate that a senior programmer would understand. Use markdown code blocks to format any code. The response should be as short as possible. Simple responses (e.g. describing a syntax error) can be 1 sentence. More complicated explanations can be 5-20 sentences.'
    model=groq/llama-3.3-70b-versatile
    #model=anthropic/claude-sonnet-4-0
    llm_blue -s "$system" --no-log -m "$model" "$prompt"
    #echo "$screen_text"
}

#function python3() { python3 "$@" || wtf; };
#alias python=python3

