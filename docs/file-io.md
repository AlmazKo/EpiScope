# Session file I/O

This document describes **which** files EpiScope reads and writes, **who** does
it, **when** (cadence, thread), **why**, and **how** (incrementally, gated on
mtime, atomically, and so on). The goal is to keep background consumption low
under frequent polling.

EpiScope has no session database of its own. The source of truth is the Claude
Code / Codex / Claude Desktop files under `~`. We read them, aggregate in
memory, and cache.

---

## 1. File map

### We read (other tools' files — the source of truth)

| Path | Contents | Reader | Purpose |
|---|---|---|---|
| `~/.claude/sessions/<pid>.json` | pid, sessionId, cwd, entrypoint, status, updatedAt, `jobId` / `parkedJobId` | `SessionStore` (shared) → `SessionMonitor`, `TerminalTracker`, `ParkedSessions` | the list of live CC sessions, their status and cwd; the only place a ⌃B-parked session names the background job that continued it |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | transcript (assistant records with usage, structuredPatch, cwd, gitBranch) | `SessionIndexer` (deepScan), `TokenChartView`, `LimitChart`, `SessionTimeline` (details), `TerminalTracker` (mtime-gated tail) | tokens, cost, changed lines, model; per-session aggregates; limit reconstruction; terminal API-error outcome |
| `~/.claude/state/cc-rate-limits.json` | real 5h / weekly limits (written by Claude's hooks and status line) | `LimitChart` | exact limits when they exist |
| `~/.claude/state/sig-<sid>`, `attended-<sid>` | hook signals and EpiScope acknowledgments | `SessionMonitor`, `TerminalTracker` (`computeState`) | session state and whether a finished or failed turn has been visited |
| `~/.claude/settings.json` | `effortLevel`, `hooks`, `statusLine` | `MainWindowController` (effort), `ClaudeHooks` (install) | show the effort; check and complete the integration |
| `~/.codex/sessions/**/rollout-*.jsonl` | Codex transcript, cumulative usage and rolling limits | `SessionIndexer`, `TokenChartView`, `LimitChart`, `SessionTimeline` (details), `TerminalTracker` (via `lsof` plus mtime-gated tail) | Codex sessions, token/cost timeline and limits; pid → rollout mapping; terminal error outcome |
| `~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<ws>/local_<uuid>.json` (plus `…/audit.jsonl`) | metadata (`cliSessionId`) and audit log of Claude Desktop Cowork sessions | `SessionIndexer`, `SessionTimeline` (details) | sessions of the Code / Cowork tab and their exact app deep-link id |
| `~/Library/Application Support/Claude/claude-code-sessions/<acct>/<ws>/local_<uuid>.json` | Claude Desktop Code-tab metadata (`sessionId`, `cliSessionId`) | `cc-open` (only when a Desktop session is opened) | translate the mirrored CLI transcript id to the tab's exact `/epitaxy/local_<uuid>` route |
| User-selected session source or mounted home | recognised Claude Code, Codex and Claude Desktop transcript layouts | disposable `source-sync` child process (30 s cadence, 120 s deadline) | update an isolated local snapshot without letting an unreliable mount block the app or its local index |
| `…/Application Support/EpiScope/sessions.json` | **our** index cache | `SessionIndexer` (at launch) | an instant table with no full scan |
| `…/Application Support/EpiScope/prompts/<name>.md` | **our** analysis prompt override, edited in `Settings → Insights` | `PromptLibrary` (when a run renders a template) | run an edited prompt without a release; absent means the bundled `prompt-<name>.md` is used |
| `…/Application Support/EpiScope/demo-fleet.json` | staged fleet for screenshots | `DemoFleet` (only when `demoFleet` is set) | show the product without the author's projects; every scanner stays parked so no real data reaches the screen |

### We write (our own files)

| Path | Writer | When | How |
|---|---|---|---|
| `~/.claude/state/cc-states.json` | `TerminalTracker` | every tick (1 s) | atomically (tmp + rename); the v1 contract. Optional `tool_running` marks a session whose tool is executing — the monitor needs it to tell an approved tool from a pending prompt without a second `ps` |
| `~/.claude/state/permission-wait.json` | `SessionMonitor` | when the wait clocks change | atomically; survives a restart. Alongside the per-session totals it keeps the last 4000 **closed** wait segments — the only record anywhere of *when* a prompt was on screen, which is what the details-mode lifecycle strip paints |
| `…/Application Support/EpiScope/sessions.json` | `SessionIndexer` | every 30 s if dirty, and on pause or exit | atomically; dates in ms |
| `…/Application Support/EpiScope/parked-sessions.json` | `ParkedSessions` | when a parked session → continuation pair is first seen | atomically; kept for good, since the link is published only while both processes run and the two transcripts it explains outlive them |
| `~/.claude/settings.json` (plus `.episcope.bak`) | `ClaudeHooks` | at launch | additively (it only adds our hooks and status line), with a backup |
| `~/.claude/hooks/episcope-statusline.sh`, `tab-state.sh` | `ClaudeHooks` | at launch | install and migrate; no-clobber for the status line |
| `…/Application Support/EpiScope/reports/<stamp>-<slug>.md` (plus `.json`) | `ReportStore` | when an analysis finishes | atomically; no retention policy — a report is deleted only from the UI |
| `…/Application Support/EpiScope/search.sqlite` | `SearchIndex` | as transcripts grow | FTS5 in WAL mode; rows for sessions that leave the index are pruned on reconcile |
| `…/Application Support/EpiScope/session-sources.json` | `SessionSourceStore` | when a custom source is added, changed or synced | atomically persisted source configuration and last successful sync time |
| `…/Application Support/EpiScope/session-sources/<id>/snapshot/**` | disposable `source-sync` child process | when an enabled custom source is available | private, atomic per-file copies of recognised transcripts; previous files are retained on every failure |
| `…/Application Support/EpiScope/prompts/<name>.md` | `PromptLibrary` (from `Settings → Insights`) | while a prompt is being edited, on a short delay after typing stops | atomically; `Restore Default` moves the file to the Trash so the bundled prompt takes over again |
| `~/Library/LaunchAgents/<bundleID>.plist` | `LoginItem` | first launch, and on toggle | atomically; removed when Launch-at-Login is turned off |
| `<temp>/episcope-analysis/<uuid>/**` | `AnalysisRunner`, `TranscriptExtractor` | for the duration of an analysis | the per-user temp root (0700), **not** `/private/tmp` — packets are verbatim conversation text; removed after the run, kept after a failure for a post-mortem. A Codex run also has the CLI write `last-message.md` here, so the result is read before the dir is removed |

Two of those touch files we do not own, so they are deliberately conservative.
`~/.claude/settings.json` and the hook scripts are commonly symlinks into a
dotfiles repo: `ClaudeHooks` resolves the link and writes **through** it, so the
repo keeps owning the file and the `.episcope.bak` holds content rather than a
second link. It also re-checks the file's (mtime, size) immediately before the
atomic swap and abandons the update if anything changed while it was merging —
our write replaces the whole document, so a hook Claude Code added in that
window would otherwise vanish.

`cc-open` is an internal app resource rather than a file installed under the
user's home. `TerminalIntegration` always runs the bundled copy so its parser
matches the `cc-states.json` producer from the same EpiScope version.

`cc-states.json` is the only bridge outwards. Its v1 entries may include the
optional `bundle_id` of the hosting application, discovered from process
ancestry. It is read by `cc-open` (which focuses a terminal or activates an
application from a notification or a double click) and by `SessionMonitor`
itself (states and host icons).

Custom session sources are a separate read-only bridge inwards. The main
process never walks or opens a configured mount. A bundled Python child copies
only recognised `.json` / `.jsonl` files to a private local snapshot, publishes
each file with an atomic rename and is terminated after 120 seconds. A failed
or missing source leaves the previous snapshot untouched, so `SessionIndexer`
and `SearchIndex` never interpret temporary unavailability as deletion.

---

## 2. Who runs when, and on which thread

Three scanners, each with its own queue and caches. They share `SessionStore`
for Claude session files; `SessionMonitor` also hands the already-computed set
of waiting Codex session ids to `TerminalTracker` in memory, avoiding a second
rollout-tail scan solely for notifications.

### TerminalTracker — "where does each session live" plus publishing
- **Thread and cadence:** a `DispatchSourceTimer` on a background serial queue,
  **1 s** (`TerminalTracker.interval`).
- **Every tick:** `SessionStore.sessions()` (gated decode) → `ps -p <pids>`
  (liveness, tty, and a guard against pid reuse).
- **Turn outcome:** transcript / rollout files are statted for live sessions;
  only a changed file gets a bounded 64 KiB tail read. A terminal Claude API
  error or Codex terminal `error` publishes `error` until the operator opens
  the session through EpiScope, then `error_attended`; both render as a neutral
  Error badge, but only the first drives the amber attention alarm and banner.
  Retryable Codex `stream_error` events are ignored. A newer Claude `idle`
  timestamp also invalidates a stale
  `thinking` hook left behind when Stop did not fire.
- **Less often:** `ps -axo` (the Codex lookup) runs **every 4th tick**, cached;
  kitty / iTerm / Terminal / Ghostty location runs **every 2nd tick**, and only
  when the application is running (`NSRunningApplication`), so AppleScript and
  `kitten` are never spawned otherwise.
- **End of a tick:** publish `cc-states.json` (atomically) and send
  notifications for state transitions. Codex approval transitions reuse the
  waiting-id verdict supplied in memory by `SessionMonitor`.
- **Why:** one path to open a terminal (`cc-open`), the terminal icons, and the
  Finished / Waiting / Error status.

### SessionMonitor — "live status for the menu bar and the table"
- **Thread and cadence:** a `Timer` on the main run loop, **1 s**, tolerance 0.2.
- **Every tick:** `SessionStore.sessions()` (gated decode) → `kill(0)` on the pid
  (cheap liveness), detection of a pending approval for `sdk-cli`,
  `refreshKittyStates()` (which reads `cc-states.json` **only when its mtime
  changes**), and `updateWaitClocks`.
- **Off main:** Codex sessions are read on a separate queue
  (`refreshCodexLiveAsync`); their waiting ids are then handed to
  `TerminalTracker` without another rollout read.
- **Why:** the needs-attention list, reaction alarms, state badges, and the
  perm-wait clocks.

### SessionIndexer — "the session table with aggregates"
- **Thread and cadence:** a `Timer` on the main run loop, **1 s**, tolerance 0.3.
  **Paused when the window is closed or minimised** — it does no work while the
  app sits in the menu bar.
- **Every tick (incremental)**, on a background serial `workQueue`:
  1. `rebuildShallow` walks `~/.claude/projects`, the Codex rollouts and Claude
     Desktop, and `stat`s every jsonl. Unchanged files come from the cache; new
     or grown ones are marked as stubs.
  2. `deepScan` runs on the stubs only (the changed files). Claude transcripts
     use their append cursor; Codex currently re-scans the changed rollout to
     find its latest cumulative snapshot. A live session's row therefore
     updates within a second, while untouched files cost one `stat` each.
- **Table updates:** when the row membership is unchanged, fresh data is written
  into the existing nodes **by `sessionId`** and only the changed rows are
  redrawn; the order is not re-sorted, because that would make
  `NSOutlineView` do a full `reloadData` on every tick. A full `reloadData`
  happens only when a session or a group really appeared or disappeared.
- **The reindex button** runs `fullReindex`: it re-reads every transcript from
  scratch (ignoring the incremental cursors) and publishes atomically, with no
  flicker.
- **Why:** the table rows and their tokens, cost, changed lines, model and turns.
- It saves the index cache to disk every 30 s when dirty, and on pause.
- Built-in provider roots are still indexed directly. Enabled custom sources
  contribute only their local snapshot roots; their mounted paths never enter
  an index pass. `sessionId` remains the global key, while `sourceID` is retained
  only for filtering, read-only actions and Offline presentation.

### TokenChartView and LimitChart — the charts
- Both use their own background queues and compute **on demand** (window opened,
  reindex, a setting changed), not on a timer.
- `TokenChartView` keeps incremental byte cursors over Claude project jsonl and
  Codex rollout jsonl and reads only appended bytes; the bucket grid is anchored
  to wall-clock boundaries. Its Codex cursor also retains the last cumulative
  usage snapshot, model, cwd and session id so the next tail can be converted
  to per-response deltas.
- `LimitChart` prefers `cc-rate-limits.json` (fresh for 30 minutes), then Codex
  rollouts, then a cached token estimate. It makes **no** network calls and
  touches **no** Keychain.
- `SessionTimeline` runs once per session opened in details, on the same
  background hop that loads the transcript for the viewer. It streams the
  **whole** transcript and byte-filters each line before decoding, so only
  prompts, turn receipts, errors, patches and usage reach `JSONDecoder`. One
  pass feeds everything above the conversation — the lifecycle strip, the three
  usage curves and the message markers. The viewer's 4 MB tail cap governs the
  conversation alone: sharing it would have drawn a month of phases against the
  last tenth of a curve, and the curve would have accumulated from the tail
  boundary rather than from the session's start. Usage dedupes by `requestId`
  like `foldUsage` does; the details chart used to skip that and ran 1.7-2.3×
  over the table.

---

## 3. How we process the data (techniques)

- **One shared decoder for session files (`SessionStore`).** Neither the monitor
  nor the tracker reads the directory itself; both call
  `SessionStore.sessions()`. The store does a `readdir` plus a `stat` per file
  and **decodes JSON only when `(mtime, size)` changed**. A tick with no changes
  is a readdir plus N stats and zero decodes. It is thread-safe (a lock).
- **Incremental jsonl parsing.** The indexer and the token chart both keep a
  `parsedSize` cursor and an mtime per file and parse only the appended tail. A
  full reparse happens only when a file shrank or was rewritten.
- **`requestId` dedup.** Claude writes several assistant records per API call
  (streaming blocks) with the same usage; we count the first one per requestId.
- **Cumulative Codex usage.** `total_token_usage.input_tokens` includes cache
  reads and cache writes. We subtract both into separate billing classes;
  `output_tokens` already includes reasoning, so `reasoning_output_tokens` is
  retained only as detail and is not added again. The chart subtracts the prior
  cumulative snapshot and ignores unchanged repeats.
- **mtime gating wherever possible:** decoding session files, listing project
  directories (a directory is re-read only when a file is added or removed; a
  file that grew is caught by the per-file stat), the monitor's read of
  `cc-states.json`, and the read of `cc-rate-limits.json`.
- **Memoised pure functions:** decoding `encoded-cwd → cwd` and classifying a
  session as temporary are cached by directory name, because those names are
  stable.
- **Atomic writes:** every file we own is written through tmp + rename.
- **Process liveness through `kill(0)`** instead of spawning `ps` where possible.
- **Separate queues**, heavy I/O off the main thread; the indexer and the charts
  pause or compute only when they are needed (the window is open).

---

## 4. Special cases

- **Temporary sessions** (`/private/tmp/*`, `/private/var/*` — sub-tasks and e2e
  runs): the indexer drops them before its inner `readdir` when Show Temporary is
  off, and the token chart folds them into one neutral bar.
- **Claude Desktop (Code / Cowork):** local-agent transcripts use the
  `audit.jsonl` next to `local_<uuid>.json`; freshness is keyed on the audit
  file's mtime and size. A Code tab can instead mirror its transcript under
  `~/.claude/projects` while `claude-code-sessions` maps that CLI id back to the
  owning `local_<uuid>` tab. On an explicit open, `cc-open` follows
  `claude://claude.ai/epitaxy/local_<uuid>` for the latter and retains the
  `claude://code/<cliSessionId>` route for older local-agent metadata.
- **Codex:** the cwd lives inside `session_meta`, pid → rollout is resolved
  through `lsof` (once per pid, cached), and usage is timestamped by the
  `token_count` record that actually carries it rather than by the preceding
  `agent_message`. When Codex App is the host, `cc-open` uses the documented
  `codex://threads/<thread-id>` deep link to select the exact local thread.

---

## 5. What we do NOT do (limits by design)

- No network calls to `api.anthropic.com` and no Keychain access.
- We never overwrite another tool's data: `settings.json` is edited additively
  (with a backup) and the status line is no-clobber.
- Real limits come only from local files (`cc-rate-limits.json` or the Codex
  rollout). When they are missing we fall back to an honest token estimate,
  labelled "estimate".
