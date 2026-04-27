#!/usr/bin/env bash
# SessionStart hook: defers to the `gingko` CLI binary, which emits the
# hook JSON contract on stdout. Bootstrap runs before this hook and is
# responsible for installing the binary.
set -eu

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*) exit 0 ;;
esac

export PATH="$HOME/.gingko/bin:$PATH"

command -v gingko >/dev/null 2>&1 || exit 0

exec gingko hook session-start
