#!/usr/bin/env bash

GINGKO="${CLAUDE_PLUGIN_ROOT:-}/scripts/gingko.sh"

# Background the close so the hook exits before the CLI tears down
"$GINGKO" close-session >/dev/null 2>&1 &
exit 0
