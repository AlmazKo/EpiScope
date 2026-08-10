# AI Insights

EpiScope's analytics layer over the session fleet. Local-first: numbers come
from the index, narrative from headless `claude -p`. Nothing leaves the machine.
Positioning: observability & monitoring first — this is the analytics layer on
top of the telemetry we already collect, not a bolt-on report.

## Shipped

### Automatic reports
- **Daily** — every morning (~09:00, hidden `dailyInsightsHour`), covering the
  previous day. **Weekly** — Monday mornings, a separate report over the past 7
  days (both fire on Monday). Each is ONE consolidated, crystallized report
  (`prompt-insights.md`): TL;DR, needs-attention, cost & savings, anomalies,
  patterns/hotspots, per-project health, CLAUDE.md candidates.
- A push notification opens Insights on tap.

### Embedded, fleet-level mode
Insights live **inside the main window** as a mode (like deep search), reached
from the ✦ toolbar button — always available, never tied to a selected session
(conceptually we work with the whole fleet). The mode is deliberately bare: the
runs list on the left, the report on the right, and a Back button. There are no
run / manage buttons — reports arrive on their own. A run is managed from the
runs-list right-click menu (Copy / Reveal / Delete); entering the mode lands on
the latest run.

- **Controls — only two, by design:** Settings → *Automatic Insights* (on/off)
  and *Analysis Model* (Sonnet 4.6 [default] / Sonnet 5 / Opus 5 / Opus 4.8 /
  Haiku 4.5).
  No other customization.
- Debug: Settings → *Run Recalculation* forces a run now
  (`defaults write almazko.EpiScope debugMode -bool YES`).

### Interval attribution (work in the window, not lifetime)
The catalog attributes metrics to the report's interval — daily = yesterday,
weekly = 7 days, on-demand = the chosen scope. `TranscriptExtractor.windowedStats`
sums usage / lines / turns from transcript records timestamped inside the window
(assistant dedup by requestId, lines from structuredPatch), so a long-open
session contributes only its in-window work, not its whole life. Cost uses the
entry's model pricing. `foldUsage` (token accounting) is left untouched.

### Reuse the index, don't re-parse
- **Catalog numbers** come straight from `SessionIndexEntry` (cost, tokens,
  turns, lines, model, span) — no re-derivation.
- **Tool-activity** is cached in the index (`SessionIndexEntry.toolSummary`,
  computed once in `deepScan`) and read from there — reports don't re-parse the
  transcript for it.
- **Deterministic signals** from the indexed numbers are surfaced in the catalog
  directly: cache-read blowup (`Nx`) and the effort setting.
- The LLM run does narrative / judgment, not data collection.

### Insights Lab (internal, not shipped)
During design we ran an *Insights Lab*: 8 single-angle variants (anomaly, cost,
rca, taxonomy, hotspots, grade, digest, claude-md), each reusing the
catalog+packets pipeline with its own prompt, so every analytics angle could be
compared on the same substrate. That exploration is how the one consolidated
`prompt-insights.md` was crystallized. The Lab, manual scope runs and the Ask
field have all been **removed from the product** — the shipped surface is
automatic-only. (The variant prompts still exist as user overrides under
`~/Library/Application Support/EpiScope/prompts/lab-*.md` for offline
experimentation via the `claude` CLI.)

## Method guardrails
- Deterministic / statistics first; the LLM only narrates and advises.
- Ground every LLM claim in the deterministic numbers. Honest metrics: no
  single-metric ranking; perm-wait is capped real-stall time, idle-open is
  away-from-keyboard.

## Roadmap (not yet)
- First-class `SessionSignals` (stuck-loop, revert, test-fail-loop, orphaned
  process, rework/churn) cached in the index → richer patterns without re-parse.
- Day-bucketed metrics in `foldUsage` so windowed attribution reads from the
  index instead of a per-report windowed scan.
- Failure clustering (embeddings + HDBSCAN), NL query over telemetry, alert
  correlation, cost forecast; optional local SLM for volume tasks.
- Windowed perm-wait / idle; packet selection by in-window cost; codex / desktop
  interval attribution.
