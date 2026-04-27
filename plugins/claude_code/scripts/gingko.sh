#!/usr/bin/env bash
# Thin wrapper around the `gingko` CLI binary. Subcommands map 1:1 onto
# `gingko memory <subcommand>`. Bootstrap is responsible for placing the
# binary on $PATH; this wrapper only resolves it and execs.
set -eu

export PATH="$HOME/.gingko/bin:$PATH"

if ! command -v gingko >/dev/null 2>&1; then
	echo "[gingko] binary not found on PATH; run the SessionStart bootstrap to install it" >&2
	exit 1
fi

exec gingko memory "$@"
