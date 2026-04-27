#!/usr/bin/env bash
# Stop hook: defers to the `gingko` CLI binary, which reads the hook
# payload from stdin, summarizes the transcript tail, and emits the
# bail JSON on stdout.
set -eu

case "$(uname -s 2>/dev/null)" in
CYGWIN* | MINGW* | MSYS*) exit 0 ;;
esac

export PATH="$HOME/.gingko/bin:$PATH"

if ! command -v gingko >/dev/null 2>&1; then
	echo '{"continue": true, "suppressOutput": true}'
	exit 0
fi

exec gingko hook session-stop
