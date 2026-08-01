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
| `~/.claude/sessions/<pid>.json` | pid, sessionId, cwd, entrypoint, status, updatedAt | `SessionStore` (shared) → `SessionMonitor`, `TerminalTracker` | the list of live CC sessions, their status and cwd |
| `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` | transcript (assistant records with usage, structuredPatch, cwd, gitBranch) | `SessionIndexer` (deepScan), `TokenChartView`, `LimitChart` | tokens, cost, changed lines, model; per-session aggregates; limit reconstruction |
| `~/.claude/state/cc-rate-limits.json` | real 5h / weekly limits (written by Claude's hooks and status line) | `LimitChart` | exact limits when they exist |
| `~/.claude/state/sig-<sid>`, `attended-<sid>` | hook signals about state and attention | `SessionMonitor`, `TerminalTracker` (`computeState`) | session state (waiting / thinking / done) |
| `~/.claude/settings.json` | `effortLevel`, `hooks`, `statusLine` | `MainWindowController` (effort), `ClaudeHooks` (install) | show the effort; check and complete the integration |
| `~/.codex/sessions/**/rollout-*.jsonl` | Codex transcript plus rolling limits | `SessionIndexer`, `LimitChart`, `TerminalTracker` (via `lsof`) | Codex sessions and limits; pid → rollout mapping |
| `~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<ws>/local_<uuid>.json` (plus `…/audit.jsonl`) | metadata and audit log of Claude Desktop Cowork sessions | `SessionIndexer` | sessions of the Code / Cowork tab |
| `…/Application Support/EpiScope/sessions.json` | **our** index cache | `SessionIndexer` (at launch) | an instant table with no full scan |

### We write (our own files)

| Path | Writer | When | How |
|---|---|---|---|
| `~/.claude/state/cc-states.json` | `TerminalTracker` | every tick (1 s) | atomically (tmp + rename); the v1 contract |
| `~/.claude/state/permission-wait.json` | `SessionMonitor` | when the wait clocks change | atomically; survives a restart |
| `…/Application Support/EpiScope/sessions.json` | `SessionIndexer` | every 30 s if dirty, and on pause or exit | atomically; dates in ms |
| `~/.claude/settings.json` (plus `.episcope.bak`) | `ClaudeHooks` | at launch | additively (it only adds our hooks and status line), with a backup |
| `~/.claude/hooks/episcope-statusline.sh`, `tab-state.sh`, `cc-open` (bundle) | `ClaudeHooks` | at launch | install and migrate; no-clobber for the status line |

`cc-states.json` is the only bridge outwards. It is read by `cc-open` (which
focuses a terminal from a notification or a double click) and by
`SessionMonitor` itself (kitty states).

---

## 2. Who runs when, and on which thread

Three **independent** scanners, each with its own queue and caches. They share
no state except `SessionStore` for the session files.

### TerminalTracker — "where does each session live" plus publishing
- **Thread and cadence:** a `DispatchSourceTimer` on a background serial queue,
  **1 s** (`TerminalTracker.interval`).
- **Every tick:** `SessionStore.sessions()` (gated decode) → `ps -p <pids>`
  (liveness, tty, and a guard against pid reuse).
- **Less often:** `ps -axo` (the Codex lookup) runs **every 4th tick**, cached;
  kitty / iTerm / Terminal / Ghostty location runs **every 2nd tick**, and only
  when the application is running (`NSRunningApplication`), so AppleScript and
  `kitten` are never spawned otherwise.
- **End of a tick:** publish `cc-states.json` (atomically) and send
  notifications for state transitions.
- **Why:** one path to open a terminal (`cc-open`), the terminal icons, and the
  Finished / Waiting status.

### SessionMonitor — "live status for the menu bar and the table"
- **Thread and cadence:** a `Timer` on the main run loop, **1 s**, tolerance 0.2.
- **Every tick:** `SessionStore.sessions()` (gated decode) → `kill(0)` on the pid
  (cheap liveness), detection of a pending approval for `sdk-cli`,
  `refreshKittyStates()` (which reads `cc-states.json` **only when its mtime
  changes**), and `updateWaitClocks`.
- **Off main:** Codex sessions are read on a separate queue
  (`refreshCodexLiveAsync`).
- **Why:** the needs-attention list, the state badges, and the perm-wait clocks.

### SessionIndexer — "the session table with aggregates"
- **Thread and cadence:** a `Timer` on the main run loop, **1 s**, tolerance 0.3.
  **Paused when the window is closed or minimised** — it does no work while the
  app sits in the menu bar.
- **Every tick (incremental)**, on a background serial `workQueue`:
  1. `rebuildShallow` walks `~/.claude/projects`, the Codex rollouts and Claude
     Desktop, and `stat`s every jsonl. Unchanged files come from the cache; new
     or grown ones are marked as stubs.
  2. `deepScan` runs on the stubs only (the changed files) and parses **just the
     tail that was appended**. A live session's row therefore updates within a
     second, while untouched files cost one `stat` each.
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

### TokenChartView and LimitChart — the charts
- Both use their own background queues and compute **on demand** (window opened,
  reindex, a setting changed), not on a timer.
- `TokenChartView` keeps an incremental byte cursor over `projects/*.jsonl` and
  reads only the appended bytes; the bucket grid is anchored to wall-clock
  boundaries.
- `LimitChart` prefers `cc-rate-limits.json` (fresh for 30 minutes), then Codex
  rollouts, then a cached token estimate. It makes **no** network calls and
  touches **no** Keychain.

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
- **Claude Desktop (Code / Cowork):** the transcript is the `audit.jsonl` next to
  `local_<uuid>.json`; freshness is keyed on the audit file's mtime and size; the
  entrypoint is `claude-desktop` and the session opens through `cc-open` using
  the application's bundle id.
- **Codex:** the cwd lives inside `session_meta`, and pid → rollout is resolved
  through `lsof` (once per pid, cached).

---

## 5. What we do NOT do (limits by design)

- No network calls to `api.anthropic.com` and no Keychain access.
- We never overwrite another tool's data: `settings.json` is edited additively
  (with a backup) and the status line is no-clobber.
- Real limits come only from local files (`cc-rate-limits.json` or the Codex
  rollout). When they are missing we fall back to an honest token estimate,
  labelled "estimate".
