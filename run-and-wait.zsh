#!/bin/zsh

emulate -L zsh

echo Running "$@"...

"$@"

read -q "?Hit any key"
