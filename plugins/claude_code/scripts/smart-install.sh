#!/usr/bin/env bash
set -eu

# Idempotent installer: downloads the gingko binary matching the plugin
# version into $GINGKO_HOME/bin/gingko, verifies SHA256, and records a
# marker so subsequent runs are no-ops until the plugin is upgraded.

GINGKO_HOME="${GINGKO_HOME:-$HOME/.gingko}"
GINGKO_BIN_DIR="$GINGKO_HOME/bin"
GINGKO_BIN="$GINGKO_BIN_DIR/gingko"
MARKER="$GINGKO_HOME/.install-version"
REPO="edlontech/gingko"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
	echo "[gingko] CLAUDE_PLUGIN_ROOT not set" >&2
	exit 1
fi

PLUGIN_JSON="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	echo "[gingko] plugin.json not found at $PLUGIN_JSON" >&2
	exit 1
fi

VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)
if [ -z "$VERSION" ]; then
	echo "[gingko] could not parse version from $PLUGIN_JSON" >&2
	exit 1
fi
TAG="v$VERSION"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$VERSION" ] && [ -x "$GINGKO_BIN" ]; then
	exit 0
fi

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS-$ARCH" in
	Darwin-arm64) TARGET="macos_silicon" ;;
	Linux-x86_64) TARGET="linux" ;;
	Linux-aarch64 | Linux-arm64) TARGET="linux_arm" ;;
	*)
		echo "[gingko] unsupported platform: $OS-$ARCH" >&2
		exit 1
		;;
esac

ARTIFACT="gingko_${TARGET}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
URL="${BASE}/${ARTIFACT}"
SUM_URL="${BASE}/SHA256SUMS"

echo "[gingko] installing $VERSION for $TARGET (one-time download, ~50MB)" >&2

mkdir -p "$GINGKO_BIN_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL "$URL" -o "$TMP/$ARTIFACT"; then
	echo "[gingko] download failed: $URL" >&2
	exit 1
fi

if ! curl -fsSL "$SUM_URL" -o "$TMP/SHA256SUMS"; then
	echo "[gingko] checksum download failed: $SUM_URL" >&2
	exit 1
fi

EXPECTED=$(awk -v f="$ARTIFACT" '$2 == f || $2 == "*"f {print $1; exit}' "$TMP/SHA256SUMS")
if [ -z "$EXPECTED" ]; then
	echo "[gingko] no checksum entry for $ARTIFACT in SHA256SUMS" >&2
	exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
	ACTUAL=$(sha256sum "$TMP/$ARTIFACT" | awk '{print $1}')
else
	ACTUAL=$(shasum -a 256 "$TMP/$ARTIFACT" | awk '{print $1}')
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
	echo "[gingko] checksum mismatch (expected=$EXPECTED actual=$ACTUAL)" >&2
	exit 1
fi

mv "$TMP/$ARTIFACT" "$GINGKO_BIN"
chmod +x "$GINGKO_BIN"
echo "$VERSION" >"$MARKER"

echo "[gingko] installed $VERSION to $GINGKO_BIN" >&2
