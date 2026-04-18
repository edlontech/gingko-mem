#!/usr/bin/env bash
set -euo pipefail

GINGKO_URL="${GINGKO_URL:-http://localhost:8008}"

get_project_id() {
	local remote
	remote=$(git remote get-url origin 2>/dev/null || echo "")
	if [ -n "$remote" ]; then
		echo "$remote" | sed 's/\.git$//' | awk -F'[/:]' '{print $(NF-1) "--" $NF}'
	else
		basename "$PWD"
	fi
}

session_file() {
	local project_id
	project_id=$(get_project_id)
	echo "/tmp/gingko-session-${project_id}"
}

get_session_id() {
	local sf
	sf=$(session_file)
	if [ -f "$sf" ]; then
		cat "$sf"
	else
		echo ""
	fi
}

api_call() {
	curl -s -f --max-time 5 "$@" 2>/dev/null || true
}

api_post() {
	local url="$1"
	local body
	body="${2:-"{}"}"
	api_call -X POST -H "Content-Type: application/json" -d "$body" "$url"
}

cmd_project_id() {
	get_project_id
}

cmd_ensure_project() {
	local project_id
	project_id=$(get_project_id)
	api_post "${GINGKO_URL}/api/projects/${project_id}/open"
}

cmd_start_session() {
	local goal="${1:-Claude Code session}"
	local project_id
	project_id=$(get_project_id)
	local body
	body=$(jq -cn --arg goal "$goal" --arg agent "claude-code" '{goal: $goal, agent: $agent}')
	local response
	response=$(api_post "${GINGKO_URL}/api/projects/${project_id}/sessions" "$body")
	if [ -n "$response" ]; then
		local session_id
		session_id=$(echo "$response" | jq -r '.session_id // empty')
		if [ -n "$session_id" ]; then
			echo "$session_id" >"$(session_file)"
		fi
		echo "$response"
	fi
}

cmd_append_step() {
	local observation="${1:-}"
	local action="${2:-}"
	local session_id
	session_id=$(get_session_id)
	if [ -z "$session_id" ]; then
		return 0
	fi
	local obs_json act_json
	obs_json=$(echo -n "$observation" | jq -Rs .)
	act_json=$(echo -n "$action" | jq -Rs .)
	local body
	body="{\"observation\":${obs_json},\"action\":${act_json}}"
	api_post "${GINGKO_URL}/api/sessions/${session_id}/steps" "$body"
}

cmd_close_session() {
	local session_id
	session_id=$(get_session_id)
	if [ -z "$session_id" ]; then
		return 0
	fi
	api_post "${GINGKO_URL}/api/sessions/${session_id}/commit"
	rm -f "$(session_file)"
}

cmd_recall() {
	local query="${1:-}"
	local project_id
	project_id=$(get_project_id)
	api_call -G --data-urlencode "query=${query}" "${GINGKO_URL}/api/projects/${project_id}/recall"
}

cmd_get_node() {
	local node_id="${1:-}"
	local project_id
	project_id=$(get_project_id)
	api_call "${GINGKO_URL}/api/projects/${project_id}/nodes/${node_id}"
}

cmd_latest_memories() {
	local top_k="${1:-30}"
	local project_id
	project_id=$(get_project_id)
	api_call "${GINGKO_URL}/api/projects/${project_id}/latest?top_k=${top_k}"
}

cmd_latest_memories_md() {
	local top_k="${1:-30}"
	local project_id
	project_id=$(get_project_id)
	api_call "${GINGKO_URL}/api/projects/${project_id}/latest?top_k=${top_k}&format=markdown"
}

cmd_session_primer() {
	local project_id
	project_id=$(get_project_id)
	api_call "${GINGKO_URL}/api/projects/${project_id}/session_primer"
}

cmd_summaries_enabled() {
	curl -s -f --max-time 5 "${GINGKO_URL}/api/summaries/status" >/dev/null 2>&1
}

cmd_status() {
	if curl -s -f --max-time 3 "${GINGKO_URL}/" >/dev/null 2>&1; then
		echo "Gingko reachable at ${GINGKO_URL}"
		exit 0
	else
		exit 1
	fi
}

command="${1:-help}"
shift || true

case "$command" in
project-id) cmd_project_id ;;
session-id) get_session_id ;;
ensure-project) cmd_ensure_project ;;
start-session) cmd_start_session "$@" ;;
append-step) cmd_append_step "$@" ;;
close-session) cmd_close_session ;;
recall) cmd_recall "$@" ;;
get-node) cmd_get_node "$@" ;;
latest-memories) cmd_latest_memories "$@" ;;
latest-memories-md) cmd_latest_memories_md "$@" ;;
session-primer) cmd_session_primer ;;
summaries-enabled) cmd_summaries_enabled ;;
status) cmd_status ;;
*)
	echo "Usage: gingko.sh <command> [args]"
	echo ""
	echo "Commands:"
	echo "  project-id              Derive project ID from git remote"
	echo "  ensure-project          Open/ensure project exists"
	echo "  start-session [goal]    Start a new memory session"
	echo "  append-step <obs> <act> Append a step to current session"
	echo "  close-session           Commit and close current session"
	echo "  recall <query>          Search project memories"
	echo "  get-node <node_id>      Get a specific node"
	echo "  latest-memories [top_k] Get latest memories as JSON (default 30)"
	echo "  latest-memories-md [top_k] Get latest memories as markdown (default 30)"
	echo "  session-primer          Fetch the composed session primer document"
	echo "  summaries-enabled       Probe whether the summaries feature is enabled"
	echo "  status                  Check if Gingko server is reachable"
	exit 1
	;;
esac
