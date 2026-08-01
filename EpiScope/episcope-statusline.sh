#!/usr/bin/env bash
# episcope-statusline v1 — EpiScope Claude Code integration.
#
# Claude Code pipes a JSON object to the status-line command on stdin.
# It carries the real, server-side rate-limit percentages under
# `rate_limits.{five_hour,seven_day}.used_percentage` — the same numbers
# /usage shows. This script stashes them in ~/.claude/state for EpiScope
# to read, then prints a compact status line (dir · model · limits).
#
# Managed automatically by EpiScope (installed/updated on launch); the
# installer only overwrites this file while the marker in this comment is
# intact.

INPUT=$(cat)
mkdir -p "$HOME/.claude/state" 2>/dev/null

printf '%s' "$INPUT" | /usr/bin/env python3 -c '
import json, os, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

rl = d.get("rate_limits") or {}
def num(key, field):
    v = (rl.get(key) or {}).get(field)
    return v if isinstance(v, (int, float)) else None
five, seven = num("five_hour", "used_percentage"), num("seven_day", "used_percentage")
five_r, seven_r = num("five_hour", "resets_at"), num("seven_day", "resets_at")

# Authoritative percentages (+ reset times) → state file (atomic).
# Claude pipes the status line many times and not every payload carries
# rate_limits; writing nulls then would blank the EpiScope gauges between
# updates. So only refresh when this render actually had limits, keep the
# last good value (and its timestamp) otherwise, and fill any missing
# field from what we already stored.
state = os.path.expanduser("~/.claude/state/cc-rate-limits.json")
if five is not None or seven is not None:
    prev = {}
    try:
        with open(state) as f:
            prev = json.load(f)
    except Exception:
        prev = {}
    def keep(cur, key):
        return cur if cur is not None else prev.get(key)
    try:
        tmp = state + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"updated": time.time(),
                       "five_hour": keep(five, "five_hour"),
                       "seven_day": keep(seven, "seven_day"),
                       "five_hour_reset": keep(five_r, "five_hour_reset"),
                       "seven_day_reset": keep(seven_r, "seven_day_reset")}, f)
        os.replace(tmp, state)
    except Exception:
        pass

# Compact, useful status line: directory · model · limits.
parts = []
ws = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
if ws:
    parts.append(os.path.basename(ws.rstrip("/")) or ws)
model = (d.get("model") or {}).get("display_name")
if model:
    parts.append(model)
lim = []
if five is not None:
    lim.append("5h %d%%" % round(five))
if seven is not None:
    lim.append("7d %d%%" % round(seven))
if lim:
    parts.append(" ".join(lim))
sys.stdout.write("  ·  ".join(parts))
'
