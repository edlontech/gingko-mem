#!/usr/bin/env bash
set -eu

# SessionStart bootstrap: ensures the gingko binary is installed and the
# service is running before the main session-start hook runs. Failures
# are logged but never block the session — the downstream hook already
# degrades gracefully when gingko is unreachable.

URL="${GINGKO_URL:-http://localhost:8008}"
export PATH="$HOME/.gingko/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

if ! bash "$CLAUDE_PLUGIN_ROOT/scripts/smart-install.sh"; then
	echo "[gingko] smart-install failed; continuing without bootstrap" >&2
	exit 0
fi

if curl -sf -m 2 "$URL/health" >/dev/null 2>&1; then
	exit 0
fi

if command -v gingko >/dev/null 2>&1; then
	gingko service install >/dev/null 2>&1 || true
	gingko service start >/dev/null 2>&1 || true
fi

for _ in $(seq 1 20); do
	if curl -sf -m 1 "$URL/health" >/dev/null 2>&1; then
		exit 0
	fi
	sleep 1
done

echo "[gingko] service did not become healthy at $URL within 20s" >&2
exit 0
