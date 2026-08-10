# Changelog

All notable changes to EpiScope are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/); versions track the app's
`MARKETING_VERSION` and the `vX.Y` release tags.

## [0.8] — 2026-08-09

### Added
- **Codex as an analysis engine** — Insights can run through `codex exec` as
  well as `claude -p`. The Codex entry names no model: `~/.codex/config.toml`
  already holds one, and which names a CLI accepts moves faster than a menu can
  track. Containment matches the Claude run — a read-only sandbox, no inherited
  MCP servers, and nothing persisted to the operator's Codex history.
- **A time range dragged on the chart** narrows the table to the sessions that
  billed tokens inside it. A drag has to travel 10 pt before it counts, so a
  plain click stays a click; clicking the chart clears the range and the
  selection together.
- **A bar explains itself on hover** — a panel beside it names the interval and
  the total, then breaks the total down by the sessions stacked in it, largest
  first, each line leading with its figure and carrying the swatch its segment
  is drawn in.
- **A session's lifecycle on the usage chart's axis.**
- **Columns are picked by right-clicking the table header**, the same list
  Settings offers.
- **An empty table says why it is empty** and names the narrowing responsible,
  with a `Show all` button that drops range, filter text and selection at once.
- **Resilient session sources**, and Insights runs link back to the sessions
  they were built from.
- **Claude Desktop Code tabs open by their own route** — recent builds mirror a
  tab's transcript under the CLI id while addressing the tab as `local_<uuid>`,
  and `claude://code/<cli-id>` was accepted and then silently dropped.

### Changed
- **Analysis failures appear in the runs list, not in a dialog.** The runs are
  scheduled, so a modal landed over unrelated work to report something already
  on screen. A failure that never started is recorded too, rather than only
  raising the alert that used to be its sole trace.
- **The Sources picker leaves the toolbar** — which sources count is decided in
  `Settings → Session Sources…`, the one place that governs them.
- The README leads with what the app is for, and shows it.

### Fixed
- The chart's crosshair never appeared: cursor rects are computed once and
  cached, and the chart is still empty when that first happens.
- A press painted a one-pixel range before travelling anywhere, so a click meant
  to clear things flashed a selection.
- The hover marker sat against the bar's left edge — it was placed from the time
  axis, which maps a bucket's start rather than the bar's middle.
- Codex runs reported their reason as an exit code and a stderr warning it
  prints on healthy runs too; the actual message arrives in the event stream.
- Line churn is counted from unlabelled Edit results.

## [0.7] — 2026-08-04

### Added
- **Menu-bar fleet chart** — the status item draws six fixed slots, one per
  session that is busy or needs you: dashes scroll while a session works, the
  bar turns red and blinks at 1 Hz on a permission prompt, amber at 0.5 Hz when
  a turn is waiting on you. The dropdown splits into *Needs attention* and
  *Active*, each row with a coloured state icon.
- **Error state** — a Claude API stream that dies without a Stop hook, or a
  Codex turn that ends in a terminal error, shows a neutral `Error` badge in the
  table instead of masquerading as Idle or Busy. Deliberately not an attention
  state: no blink, no sound, no banner.
- **Session context in notifications** — a banner carries the session's
  AI-generated description, so several waiting sessions are tellable apart
  without opening the app.
- **Host application icons** — any app hosting a session gets its real icon,
  including terminals EpiScope has no adapter for.

### Changed
- **One owner for expensive work.** Every transcript walk, index pass, chart
  fold and CLI run goes through a single scheduler: exclusion groups (at most
  one walk at a time, structurally), leases so a minutes-long child process
  holds its group without parking a thread, coalescing that also sees work
  already running, and launch admission so a cold start belongs to the visible
  table rather than the full-text backfill.
- **Incremental scanning for all three providers.** Codex and Claude Desktop
  folded their whole transcript on every pass — up to 12 MB re-decoded once a
  second for a live session; they now fold only the appended tail. The
  rate-limit walk and the tool-activity summary stopped re-reading the corpus
  as well.
- **Per-provider behaviour lives on the type.** `SessionProvider` answers with
  exhaustive switches, so a new provider fails to compile instead of silently
  inheriting Claude's answer; the project-directory codec has one home.

### Fixed
- Codex and Claude Desktop sessions were silently missing from every daily and
  weekly report, which therefore understated the fleet's cost.
- The weekly report was lost every Monday: the week was marked done before the
  run started, and the run was then refused because the daily one was still
  preparing.
- Deep search returned nothing for the whole session on a fresh install — the
  read connection opened before the database file existed and never retried.
- The chart grouped and coloured half the projects under paths the table never
  showed, because a hyphenated project name decodes ambiguously from its
  directory.
- Clicking the Model, Name or Started headers moved the sort arrow without
  reordering anything.
- A live Codex or Claude Desktop row blanked its title, project and cost once a
  second while being rescanned.
- Codex token accounting and rate-limit window mapping.

### Security
- `cc-open` interpolated a value from `~/.claude/state/cc-states.json` into
  AppleScript source, so a forged snapshot could run arbitrary commands from a
  row double-click or a notification tap. Window and tab now go in as
  arguments.
- Rendered Markdown made any URL clickable and the system opener honours
  `file://`, so a link in model output was one click from launching something.
  Only web links stay clickable.
- Session ids from other tools' files named files we create and delete without
  validation, so a crafted id could empty an arbitrary file once a second.
- Analysis packets (verbatim conversation text) moved out of world-readable
  `/private/tmp`; the analysis run no longer inherits the user's own tool
  permissions or MCP servers.
- A symlinked `~/.claude/settings.json` is written through rather than
  replaced, so a dotfiles repo keeps owning the file, and an edit that lands
  mid-merge is no longer lost.

## [0.6] — 2026-07-06

### Added
- **AI Insights** — a local-first analytics layer over the whole session fleet.
  Automatic **daily** (each morning, the previous day) and **weekly** (Monday)
  reports, each ONE consolidated, crystallized report: TL;DR, needs-attention,
  cost & savings, anomalies, patterns/hotspots, per-project health, CLAUDE.md
  candidates. Numbers come from the index; the narrative is generated by a
  headless `claude -p` run — nothing leaves the machine. A push notification
  opens the report. Insights are **embedded in the main window** as a
  fleet-level mode (the ✦ button, like deep search): runs list on the left,
  report on the right, a run managed from the list's right-click menu. Controls
  are deliberately minimal — Settings → *Automatic Insights* (on/off) and
  *Analysis Model*. See `docs/insights-lab.md`.
- **Agterm terminal support** — exact window/session binding via `agtermctl` and
  the `AGTERM_*` environment variables (`docs/agterm.md`).
- **Custom About window** — gradient header, hero icon and slogan.
- **Usage-gauge overage** — when consumption outpaces the planned pace, the
  over-forecast zone of the menu-bar "Claude Limits" gauge is painted as a
  diagonal striped hazard fill.
- **Unread Insights badge** — the Insights toolbar button shows a dot when a
  report (a background daily/weekly insight, or a finished run) has arrived
  since you last opened Insights; opening Insights clears it.
- **Non-interactive marker** — sessions launched with `claude -p` / driven over
  the SDK (entrypoint `sdk-cli`, no interactive terminal) show a "-p" in the
  terminal column instead of a terminal icon, for live and past runs alike.
- **Copy Resume Command** — right-clicking any Claude / Codex session copies a
  command that reopens it: `cd '<cwd>' && claude --resume <id>` (Codex:
  `codex resume <id>`).
- **Session actions in the details toolbar** — viewing a session's messages now
  offers its full action set on the toolbar (Copy session ID, Copy Resume
  Command, Go to terminal, Reveal in Finder, Analyze, Delete), not just Back.
- **Delete a session** — right-click → Delete Session… (with confirmation)
  moves a Claude / Codex session's transcript to the Trash (recoverable).

### Changed
- Default analysis model is **Sonnet 4.6** (selectable in Settings → Analysis
  Model, alongside Sonnet 5 / Opus 4.8 / Haiku 4.5).
- Insights use **interval attribution** — a report counts the work done inside
  its window (yesterday / the last 7 days), not lifetime totals; tool activity
  is cached in the index and reused instead of re-parsing transcripts.
- `release.sh` builds a **universal** binary and notarizes + staples the `.app`
  itself (not just the DMG), so a copy dragged out of the DMG launches offline.
- Sessions with no reachable terminal (past runs, or detached / orphaned) are
  dimmed in the table; `-p` and Claude-desktop sessions keep their own marker.

### Fixed
- Ghostty: bind sessions to tabs by tab name or ai-title (the wrong tab could
  focus before).
- Column sort now actually reorders the table.
- A session's `Finished` state resets when its window is opened.
- Auto / bypass-permission sessions are no longer flagged as waiting on a
  permission prompt.
- Rate-limit gauges: merge real and estimated data per window, roll stale
  windows over past their reset, and align the weekly estimate to the reset
  cadence — fixing gauges that stuck full right after a reset.
- Runaway permission waits are capped and split from away-from-keyboard idle
  time.
- Detached / headless background sessions (a `--bg` agent adopted by Claude's
  daemon, with no terminal to focus) no longer trap the menu bar in a blink
  that can't be cleared: acknowledging the prompt — tapping the notification or
  opening the session — silences the alarm while the session stays in the
  Needs-attention list; a fresh prompt re-arms it.
- Tapping such a session (notification banner or status-bar menu) opens it in
  the table instead of spawning a stray kitty at its cwd, and the tap never
  dead-ends when there's no live row to select.
- The table marks a detached session (alive but hosted by no known terminal)
  with a distinct icon and tooltip instead of a generic-terminal glyph.
- "Go to terminal" opens the right instance when one session runs in more than
  one place (e.g. resumed in a new terminal while the original lingers) — the
  most recently launched, not an arbitrary match.
- A session running in a JetBrains IDE terminal is no longer mislabeled (and
  opened) as Ghostty when a Ghostty window shares its directory — process
  ancestry now vetoes the wrong surface match.
- Notification spam fixed: Ghostty's AppleScript intermittently returns no
  surfaces while it's still running, which made a session's state flap
  done ↔ idle every few seconds and re-fire the "Finished" banner. The surface
  cache now ignores those empty results, and a state must hold for two ticks
  before a banner fires or is retracted.
- Opening a session / Insights / search and returning no longer clears the
  table's quick filter.

## [0.5] — 2026-06-30

### Added
- **Full-text search across all sessions.** A deep-search mode in the main
  window (the magnifier button left of the filter, or ⌘F) backed by a SQLite
  FTS5 index over every session's conversation text — zero new dependencies
  (the system `libsqlite3`). Results are per-message cards with highlighted
  excerpts; clicking one opens that session's Messages, scrolls to the exact
  message and briefly washes it. The index builds incrementally and survives
  relaunches.
- **Homebrew distribution.** Install and update via a `brew` cask.
- **Animated busy badge** — a pearlescent fill with elapsed `mm:ss` while a
  session is thinking.
- **Group sessions by directory** (Settings → Group by Directory): a
  directory-keyed table and chart, with temporary sessions folded away.
- Per-session Claude reasoning effort, read from the transcript (overrides the
  global `~/.claude/settings.json` value).
- `docs/file-io.md` documenting how EpiScope reads and writes session files.

### Performance
A large energy-and-memory pass — idle CPU roughly halved and cold-start peak
memory cut by more than half:
- Indexing is driven by **FSEvents** instead of a blind 1-second filesystem
  walk; the cheap status heartbeat is split from the full analytics reindex,
  which now sweeps **incrementally** and updates only the table rows that
  changed (the status column no longer forces a per-tick relayout).
- The indexer memoises cwd decoding and caches per-project file listings, and
  `~/.claude/sessions` is decoded once per change by a single mtime-gated store.
- The terminal tracker resolves each pid's tty once and uses `kill(0)` for
  liveness, cutting redundant per-tick work.
- Transcripts are parsed **line-by-line and never loaded whole** (Claude, Codex
  and Claude-desktop scans all stream); the limit scan streams too, the
  transcript viewer is capped, and per-file autorelease pools drain the scan
  loops.
- The alert chime plays via `afplay` out of process, so EpiScope no longer
  keeps CoreAudio threads warm (fewer live threads at idle).

### Changed
- The main-window filter stays a fast table filter (title / project / id);
  message-text search lives in the dedicated deep-search mode.
- Tapping a notification reveals the session in the table when EpiScope can't
  tell where its terminal is (instead of opening a stray terminal), and no
  longer flashes the window in front of the terminal it is bringing forward.
- Claude desktop sessions open through the single `cc-open` path.
- Status-bar gauges fall back to a token estimate when no live limit data is
  available.
- The idle status badge is driven from the tracker's live state.

### Fixed
- Ghostty: focus the correct tab (deterministic session ordering).
- Token chart: bars no longer grow for past days on recompute (the bucket grid
  is anchored to clock boundaries).

## [0.4.1] — 2026-06-19

### Added
- Claude desktop session support (the Code tab and Cowork / local-agent-mode).
- Row context menu: Reveal Transcript in Finder.

### Changed
- Limits chart: a "Computing…" placeholder while reconstructing; dropped the
  stale "enable in Settings" hint.

## [0.4] — 2026-06-19

### Added
- Status-bar limit gauges for Claude and Codex (5-hour and weekly windows),
  with a usage-vs-time zone bar; opt-in via Settings.
- Codex live tracking via rollouts, and Codex integration via hooks.
- Claude Code hooks installer (Settings → Claude Code Hooks) — explicit and
  additive, never touching a foreign status line.
- Turns and Perm-Wait columns; JetBrains terminal support.
- Single-instance guard — a second launch focuses the running app and quits.

### Changed
- Unified NSToolbar with an Activity Monitor-style header and inset table.

## [0.3.1] — 2026-06-11

### Added
- Settings → Chart Bars: Auto / 5 min / 15 min / 1 hour bar size.

## [0.3] — 2026-06-11

### Added
- EpiScope is now the session tracker and notifier: it publishes
  `cc-states.json` and owns the done / needs-permission banners.
- Per-terminal icons in the table; Terminal.app and Ghostty adapters.
- Chart window setting, a Messages button, and a Changes (lines ±) column.
- Settings → Notifications row to re-request or fix the notification grant.

### Changed
- Terminal integration is core — the optional kitty-only concept was removed.
- The status bar is sessions-only; app settings moved to the Settings menu.

## [0.2] — 2026-06-10

### Added
- Main window listing every session, with a token-usage chart.
- Per-session details mode: per-session chart, transcript view and Markdown
  rendering.
- Codex session support and official provider icons.
- Incremental session indexer, a Resume button, and waiting `sdk-cli` detection.

### Changed
- Renamed Signal → EpiScope.

## [0.1] — 2026-06-09

- First release: a menu-bar indicator for Claude Code permission prompts
  (macOS 14 baseline).
