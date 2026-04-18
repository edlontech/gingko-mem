#!/usr/bin/env bash
set -euo pipefail

GINGKO="$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh"

if ! "$GINGKO" status >/dev/null 2>&1; then
	exit 0
fi

"$GINGKO" ensure-project >/dev/null
"$GINGKO" start-session "Claude Code session" >/dev/null

if "$GINGKO" summaries-enabled 2>/dev/null; then
	payload=$("$GINGKO" session-primer)
	summaries_mode=1
else
	payload=$("$GINGKO" latest-memories-md 100)
	summaries_mode=0
fi

if [ -n "$payload" ] && [ "$payload" != "null" ]; then
	content=$(echo "$payload" | jq -r '.content // empty' 2>/dev/null || true)
	if [ -n "$content" ]; then
		if [ "$summaries_mode" -eq 1 ]; then
			context="$content"
			mem_count=$(echo "$content" | grep -c '### Memory' || true)
			msg="[gingko] primed session context (${mem_count} recent memories)"
		else
			context="## Previous Gingko Memories

The following are your most recent memories from previous sessions in this project:

${content}

Use \`$GINGKO append-step '<observation>' '<action>'\` to record new memories during this session.

IMPORTANT: You MUST invoke the \`gingko-memory\` skill at the start of this session to learn how to properly interact with the Gingko memory system."
			mem_count=$(echo "$content" | grep -c '### Memory' || true)
			msg="[gingko] Loaded ${mem_count} recent memories into session context"
		fi

		jq -n \
			--arg ctx "$context" \
			--arg msg "$msg" \
			'{
        hookSpecificOutput: {
          hookEventName: "SessionStart",
          additionalContext: $ctx
        },
        systemMessage: $msg
      }'
	fi
fi
