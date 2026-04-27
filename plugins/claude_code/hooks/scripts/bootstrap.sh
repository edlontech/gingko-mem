#!/usr/bin/env bash
set -eu

# SessionStart bootstrap: ensures the gingko binary is installed and the
# service is running before the main session-start hook runs. Failures
# are surfaced to the user via systemMessage but never block the session —
# the downstream hook already degrades gracefully when gingko is unreachable.

URL="${GINGKO_URL:-http://localhost:8008}"
export PATH="$HOME/.gingko/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

json_escape() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '"%s"' "$s"
}

emit_msg() {
	printf '{"systemMessage":%s}\n' "$(json_escape "$1")"
	exit 0
}

if ! install_log=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/smart-install.sh" 2>&1); then
	emit_msg "[gingko] smart-install failed; continuing without bootstrap
$install_log"
fi

if curl -sf -m 2 "$URL/health" >/dev/null 2>&1; then
	[ -n "$install_log" ] && emit_msg "$install_log"
	exit 0
fi

if ! command -v gingko >/dev/null 2>&1; then
	msg="[gingko] CLI not found on PATH; cannot bootstrap service"
	[ -n "$install_log" ] && msg="$install_log
$msg"
	emit_msg "$msg"
fi

if gingko service installed >/dev/null 2>&1; then
	msg="[gingko] service is installed but stopped; run 'gingko service start' to restart"
	[ -n "$install_log" ] && msg="$install_log
$msg"
	emit_msg "$msg"
fi

gingko service install >/dev/null 2>&1 || true
gingko service start >/dev/null 2>&1 || true

for _ in $(seq 1 20); do
	if curl -sf -m 1 "$URL/health" >/dev/null 2>&1; then
		msg="[gingko] service started at $URL"
		[ -n "$install_log" ] && msg="$install_log
$msg"
		emit_msg "$msg"
	fi
	sleep 1
done

msg="[gingko] service did not become healthy at $URL within 20s"
[ -n "$install_log" ] && msg="$install_log
$msg"
emit_msg "$msg"
