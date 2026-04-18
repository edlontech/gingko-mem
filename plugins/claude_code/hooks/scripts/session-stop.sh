#!/usr/bin/env bash
set -euo pipefail

GINGKO="$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh"
GINGKO_URL="${GINGKO_URL:-http://localhost:8008}"

bail() {
	echo '{"continue": true, "suppressOutput": true}'
	exit 0
}

create_session() {
	"$GINGKO" ensure-project >/dev/null 2>&1 || true
	"$GINGKO" start-session "Claude Code session (auto-created on stop)" >/dev/null 2>&1 || true
	"$GINGKO" session-id 2>/dev/null || true
}

summarize() {
	local sid="$1" body="$2"
	curl -s -f --max-time 10 \
		-X POST \
		-H "Content-Type: application/json" \
		-d "$body" \
		"${GINGKO_URL}/api/sessions/${sid}/summarize" 2>/dev/null
}

input=$(cat)

"$GINGKO" status >/dev/null 2>&1 || bail

transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
[ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] && bail

last_message=$(tail -c 8000 "$transcript_path" 2>/dev/null || true)
[ -z "$last_message" ] && bail

content_json=$(echo -n "$last_message" | jq -Rs .)
body="{\"content\":${content_json}}"

session_id=$("$GINGKO" session-id 2>/dev/null || true)

if [ -n "$session_id" ]; then
	if summarize "$session_id" "$body" >/dev/null; then
		bail
	fi
fi

session_id=$(create_session)
[ -z "$session_id" ] && bail

summarize "$session_id" "$body" >/dev/null 2>&1 || true

bail
