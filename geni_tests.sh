# the variables below contain example YAML responses from the LLM
# they can be used to test the __GENIUS__process_response function in geni.sh
# by running a command like
#
# echo "$__GENIUS_test1" | __GENIUS__process_response

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


