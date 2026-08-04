#!/usr/bin/env bash
# episcope-hook v1 — Claude Code state-signal bridge for EpiScope.
#
# Records a state signal for the session that fired the hook, keyed by
# the CC session id (terminal-agnostic), read from the hook's stdin
# JSON. Consumers read ~/.claude/state — EpiScope's TerminalTracker
# turns the signals into badges, notifications and cc-states.json.
#
# Managed automatically by EpiScope (installed/updated on launch): the
# installer only overwrites this file while the marker in the first
# comment line is intact — a customised copy is left alone.
#
# Usage: tab-state.sh thinking | needs_permission | done | idle

STATE="${1:-idle}"
SID=$(/usr/bin/env python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: pass' 2>/dev/null)
[ -z "$SID" ] && exit 0
# The id becomes a filename we write and delete — a real one is a uuid, so
# anything with a separator in it is not a session we should act on.
case "$SID" in *[!A-Za-z0-9._-]*) exit 0 ;; esac

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null
SIG="$STATE_DIR/sig-$SID"

case "$STATE" in
  thinking|needs_permission|done)
    printf '%s\n' "$STATE" > "$SIG"
    ;;
  idle|*)
    rm -f "$SIG"
    ;;
esac
true
