#!/bin/sh
# Nightly activity summary. Run by launchd at 23:59; safe to run by hand.
#
# launchd gives a job almost no environment — not your shell's PATH, and not
# ANTHROPIC_API_KEY. The key is read from a 0600 file rather than baked into the
# plist, because ~/Library/LaunchAgents is world-readable by default.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$HOME/Library/Application Support/LocalObserver/summary.env"

# Sourcing an env file with a blank key would clobber a key already exported in
# the shell, so an interactive run keeps whatever it came in with.
INHERITED="${ANTHROPIC_API_KEY:-}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -z "${ANTHROPIC_API_KEY:-}" ] && ANTHROPIC_API_KEY="$INHERITED"
export ANTHROPIC_API_KEY

BIN="$REPO/.build/release/ObserverSummary"
[ -x "$BIN" ] || BIN="$REPO/.build/debug/ObserverSummary"
[ -x "$BIN" ] || { echo "no ObserverSummary binary — run: swift build -c release" >&2; exit 1; }

echo "--- $(date '+%Y-%m-%d %H:%M:%S %Z') ---"
exec "$BIN" "$@"
