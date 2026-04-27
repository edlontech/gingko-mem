#!/usr/bin/env bash
# SessionEnd hook: defers to the `gingko` CLI binary, which commits the
# active session and clears the on-disk pointer.
set -eu

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*) exit 0 ;;
esac

export PATH="$HOME/.gingko/bin:$PATH"

command -v gingko >/dev/null 2>&1 || exit 0

exec gingko hook session-end
