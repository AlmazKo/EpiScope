#!/usr/bin/env python3
"""Build demo-fleet.json from the real session index.

Marketing screenshots need believable numbers, and the only believable numbers
are the real ones: token counts, cache blowups, line churn, session spans and
the long tail of tiny sessions are all shapes that invented data gets wrong.

So this copies the index entries **verbatim** and rewrites only the five fields
that name the work — cwd, title, name, git branch, transcript path. Session ids
are kept on purpose: they hash into each row's colour, so the staged table is
coloured exactly like the real one.

Reads the index of whoever runs it, so its output never leaves this machine:

    ./make-demo-fleet.py            # rebuild the document
    ./make-demo-fleet.py --stdout   # preview without writing

Then `defaults write almazko.EpiScope demoFleet -bool YES` and relaunch.
"""

import json
import os
import sys
import zlib

INDEX = os.path.expanduser("~/Library/Application Support/EpiScope/sessions.json")
DOC = os.path.expanduser("~/Library/Application Support/EpiScope/demo-fleet.json")

# Real project -> the name it wears in a screenshot. Anything unlisted falls
# back to a generic slug, so a new project can never leak by being forgotten.
PROJECTS = {
    "projects/fx": "projects/exchange-core",
    "projects/rem": "projects/remit",
    "projects/rem/ios/RemCode": "projects/remit/ios/RemitApp",
    "projects/prime-front-server": "projects/orders-gateway",
    "projects/prime-server": "projects/orders-service",
    "projects/prime/front/server": "projects/orders-gateway/web",
    "projects/prime-web-admin": "projects/admin-console",
    "projects/trade-tools": "projects/market-tools",
    "projects/raven": "projects/falcon",
    "projects/Asteroid": "projects/comet",
    "projects/feed-server": "projects/feed-service",
    "projects/mt5-server": "projects/quotes-bridge",
    # Kept on purpose: the product monitoring itself reads well in a screenshot.
    "projects/EpiScope": "projects/EpiScope",
    "tmp": "tmp",
}

# Assigned by a hash of the session id, so regenerating keeps every row's title
# stable and two runs produce the same screenshot.
TITLES = [
    "Add per-tenant rate limiting to the public endpoints",
    "Backfill the migration for archived invoices",
    "Convert the settlement job to the new netting rules",
    "Why does checkout retry twice on a declined card?",
    "Split the ingest worker into its own process",
    "Trace the crash in the trip-history list",
    "Regenerate the dark palette from the new brand sheet",
    "Pin the runner image and re-run the failed matrix",
    "Cache the instrument list between quote polls",
    "Make the reconciliation report streamable",
    "Drop the legacy webhook retry queue",
    "Move the session store behind an interface",
    "Fix the off-by-one in the pagination cursor",
    "Add structured logging to the payout path",
    "Rewrite the fixture loader to stream",
    "Find the leak in the websocket reconnect loop",
    "Port the admin filters to the new query builder",
    "Explain why the nightly job doubled in cost",
    "Add a health check that actually touches the database",
    "Deduplicate the order events by request id",
    "Tighten the retry budget on the pricing client",
    "Replace the polling loop with a change feed",
    "Document the failure modes of the settlement job",
    "Extract the tenant resolver from the middleware",
    "Make the migration idempotent",
    "Batch the notification writes",
    "Reduce the cold start of the quotes bridge",
    "Audit which endpoints still accept the legacy token",
    "Rework the error taxonomy for the public API",
    "Add a regression test for the netting edge case",
]

BRANCHES = ["main", "develop", "feature/rate-limits", "feature/netting",
            "fix/pagination-cursor", "chore/runner-image"]

# The rows that carry a live badge, applied to the most recently active
# sessions. Everything else reads as history — which is what a fleet looks like.
LIVE = [
    {"status": "busy", "busySeconds": 16, "terminal": "ghostty"},
    {"status": "waiting", "terminal": "kitty"},
    {"status": "busy", "busySeconds": 145, "terminal": "iterm2"},
    {"status": "idle", "terminal": "terminal"},
    {"status": "idle", "terminal": "ghostty"},
    {"status": "finished", "terminal": "kitty"},
]

HOME = os.path.expanduser("~")

# Insights mode and the details view are written here rather than in Swift, so
# one run of this script produces a complete document. Editing a screenshot's
# wording means editing this file (or the JSON) — not rebuilding the app.
INSIGHTS = [
    {
        "title": "Daily — yesterday across 9 projects",
        "type": "insights", "hoursAgo": 3, "model": "claude-sonnet-4-6",
        "costUSD": 0.38, "durationSec": 74, "turns": 12,
        "markdown": """## TL;DR

Yesterday cost **$212** across 9 projects and 47 sessions — 18% above your
7-day median, almost entirely from one long run in `ledger-service`.

## Needs attention

- **`ledger-service` re-read its context 31×.** One session spent $58 on cache
  reads alone while converting the settlement job. Splitting that task at the
  netting-rules boundary would have kept each turn under the cache ceiling.
- **Two sessions sat on a permission prompt for over 20 minutes**
  (`orders-gateway`, `storefront`). Both were waiting on the same
  `Bash(psql *)` call — an allow rule would remove the stall.

## Cost and where it went

| Project | Sessions | Cost | Share |
|---|---|---|---|
| ledger-service | 6 | $94 | 44% |
| orders-gateway | 14 | $51 | 24% |
| storefront | 11 | $38 | 18% |
| everything else | 16 | $29 | 14% |

Opus handled 71% of the spend but only 34% of the turns. The `design-tokens`
work ran entirely on Haiku for $1.40 — the same shape of task in `storefront`
ran on Opus for $23.

## Patterns

- Sessions that start after 18:00 are **2.4× more likely** to end in a revert.
- `orders-gateway` has been touched by 14 sessions in 3 days without a single
  one closing the migration — the work is being restarted, not continued.

## CLAUDE.md candidates

- "Run migrations against the shadow schema first" — re-explained by hand in 4
  separate sessions.
- "The settlement job is generated; edit the template, not the output" — one
  session spent 40 minutes editing generated code.
""",
    },
    {
        "title": "Weekly — the last 7 days",
        "type": "insights", "hoursAgo": 51, "model": "claude-sonnet-4-6",
        "costUSD": 0.91, "durationSec": 133, "turns": 19,
        "markdown": """## TL;DR

**$1,284** over 7 days, 312 sessions, 11 projects. Spend is flat week over week
while output rose 22% — the Haiku migration for routine edits is paying for
itself.

## Anomalies

- Tuesday cost 3× Monday for the same number of turns. Every expensive session
  that day was reading the whole `ledger-service` fixture directory into context.
- One session in `infra` ran for 4 hours and produced 12 lines.

## Per-project health

| Project | Trend | Note |
|---|---|---|
| orders-gateway | steady | healthy turn/cost ratio |
| ledger-service | rising | cache blowup, see daily |
| storefront | falling | mostly closed out |
| remit/ios | new | first week of agent work |
""",
    },
]

CONVERSATION = [
    {"role": "user", "text": "Add per-tenant rate limiting to the public endpoints"},
    {"role": "assistant", "text": """I'll start by finding where the public routes are declared and how the tenant
is resolved on each request.

The router mounts everything under `api/public/` and resolves the tenant in
`TenantMiddleware` before any handler runs, so the limit can key off
`request.tenant.id` without touching the handlers.

Three things to decide first:

1. **Where the counter lives.** Redis is already in the request path for
   sessions, so a sliding window there costs no new infrastructure.
2. **What the limit applies to.** Per tenant, or per tenant *and* endpoint? The
   abuse you described is one tenant hammering one report endpoint, so
   per-pair is the tighter fit.
3. **What a rejected request returns.** `429` with `Retry-After` is what the
   client SDK already understands."""},
    {"role": "user", "text": "Per tenant and endpoint. Use Redis."},
    {"role": "assistant", "text": """Done. `RateLimiter` implements a sliding window over Redis sorted sets, keyed
`rl:{tenant}:{route}`, and `TenantMiddleware` calls it right after it resolves
the tenant.

Notable details:

- The window is trimmed with `ZREMRANGEBYSCORE` in the same pipeline as the
  insert, so a hot key never accumulates.
- Limits come from `config/rate_limits.yml` with a default of `600/min`; the
  report endpoint is pinned to `60/min`.
- A Redis outage **fails open** and logs — a cache being down should not take
  the API down with it.

```python
async def check(self, tenant: str, route: str) -> Decision:
    key = f"rl:{tenant}:{route}"
    now = time.time()
    async with self.redis.pipeline() as pipe:
        pipe.zremrangebyscore(key, 0, now - self.window)
        pipe.zadd(key, {uuid4().hex: now})
        pipe.zcard(key)
        pipe.expire(key, self.window)
        _, _, used, _ = await pipe.execute()
    return Decision(allowed=used <= self.limit_for(route),
                    retry_after=self.window)
```

Tests cover the boundary (exactly at the limit passes, one over is rejected),
window expiry, and the fail-open path. All 41 pass."""},
    {"role": "user", "text": "What happens if two requests land in the same millisecond?"},
    {"role": "assistant", "text": """They both count. The member is a fresh UUID rather than the timestamp, so two
inserts at an identical score are two distinct members and `ZCARD` sees both.

That is deliberate — keying by timestamp would silently collapse simultaneous
requests into one, which is exactly the burst the limiter exists to catch."""},
]


def anonymise_cwd(cwd):
    rel = cwd[len(HOME) + 1:] if cwd.startswith(HOME + "/") else cwd.lstrip("/")
    if rel in PROJECTS:
        return HOME + "/" + PROJECTS[rel]
    # Longest known prefix wins, so worktrees and subdirs follow their parent.
    for real, fake in sorted(PROJECTS.items(), key=lambda kv: -len(kv[0])):
        if rel.startswith(real + "/"):
            return HOME + "/" + fake + "/" + rel[len(real) + 1:]
    if cwd.startswith("/private/"):
        return cwd
    return HOME + "/projects/service-%d" % (zlib.crc32(rel.encode()) % 90 + 10)


def main():
    index = json.load(open(INDEX))
    entries = index["entries"]

    for e in entries:
        h = zlib.crc32((e.get("sessionId") or "").encode())
        e["cwd"] = anonymise_cwd(e.get("cwd", ""))
        # A session with no title keeps none — the dashes in the real table are
        # part of how it looks.
        if e.get("title"):
            e["title"] = TITLES[h % len(TITLES)]
        if e.get("name"):
            e["name"] = "wt-%d" % (h % 40)
        if e.get("lastGitBranch"):
            e["lastGitBranch"] = BRANCHES[h % len(BRANCHES)]
        # Holds the real project path; the demo layer never reads a transcript
        # from disk, so it can just go.
        e.pop("transcriptPath", None)

    live_pool = sorted(entries, key=lambda e: e.get("lastActivity") or 0, reverse=True)
    live = []
    for spec, e in zip(LIVE, live_pool):
        row = dict(spec)
        row["sessionId"] = e["sessionId"]
        # A live row with no title looks broken; give the visible ones one.
        if not e.get("title"):
            e["title"] = TITLES[zlib.crc32(e["sessionId"].encode()) % len(TITLES)]
        live.append(row)

    doc = {"entries": entries, "live": live,
           "insights": INSIGHTS, "conversation": CONVERSATION}

    out = json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=True)
    if "--stdout" in sys.argv:
        print(out[:4000])
        return
    open(DOC, "w").write(out)
    print("wrote %s — %d entries verbatim, %d live" % (DOC, len(entries), len(live)))


if __name__ == "__main__":
    main()
