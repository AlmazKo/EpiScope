# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

EpiScope is a macOS menu-bar app that watches Claude Code, OpenAI Codex and
Claude Desktop sessions on one machine: permission prompts, live status, tokens
and cost, transcripts, full-text search, and scheduled local AI insights. Pure
AppKit, no SwiftUI, no third-party dependencies (the system `libsqlite3` is the
only library beyond the SDK).

## Build and verify

**`xcodebuild` is the source of truth.**

```bash
xcodebuild -project EpiScope.xcodeproj -scheme EpiScope -configuration Debug build
```

SourceKit reports cross-file `Cannot find type 'X' in scope` for symbols that
live in the same module. Those diagnostics are **false** in this environment —
do not chase them, confirm with a build instead.

There is no test target. Verify a change by building, and by running the app
when the change is visible:

```bash
open ~/Library/Developer/Xcode/DerivedData/EpiScope-*/Build/Products/Debug/EpiScope.app
```

## Architecture

Three scanners do the watching. They share no state except `SessionStore`, which
decodes `~/.claude/sessions/*.json` once per change for all of them.

| Component | Cadence | Owns |
|---|---|---|
| `TerminalTracker` | 1 s, background (`TerminalTracker.interval`) | which terminal hosts each session, `cc-states.json`, notifications |
| `SessionMonitor` | 1 s, main run loop | live status for the menu bar and the table, perm-wait clocks |
| `SessionIndexer` | 1 s heartbeat, main run loop, gated by FSEvents and disabled while the window is closed | the session table and its aggregates |

**All expensive work goes through `WorkScheduler`, and there is no second way
in.** `register(Job)` carries the recurring cadences above; `run(Work)` takes
one-shot work that declares what it needs rather than how to run it:

- `group` — one serial queue per group, so "at most one transcript walk at a
  time" is structural, not a convention. Groups: `scan` (every transcript
  walk), `index` (session-index passes), `analysis` (CLI runs and their prep).
- `coalesce` — a newer submission replaces one still queued under the same id,
  and one submitted while that id is running waits for it rather than stacking.
- `priority` — `.interactive` when somebody is watching the result. It raises
  the QoS; it cannot overtake, since a group is a serial FIFO.
- `deferrable` — held through the launch window so a cold start belongs to the
  visible table, not to the full-text backfill.

There is no cancellation, on purpose — see the header of `WorkScheduler.swift`.
Do not add a private `DispatchQueue` for heavy work; add a group.

Everything else hangs off those: `MenuBarChart` draws the status item — one
vertical bar per live session, on its own 10 Hz main-run-loop timer (a redraw of
a dozen rects is not scheduler work, and the scheduler's heartbeat is 1 s);
`MainWindowController` owns the window and its
four modes (list, details, search, insights); `ReportsWindowController` owns the
Insights mode and the whole analysis pipeline; `TokenChartView` and `LimitChart`
compute on demand, not on a timer; `SearchIndex` is an FTS5 index;
`MarkdownRenderer` renders transcripts and reports; `TranscriptExtractor` builds
the catalog and packets for analysis runs.

`docs/file-io.md` is the detailed map of what is read and written, by whom, when
and how. Read it before touching any file I/O.

## Invariants

Break these and the product stops being what it is:

- **No network, no Keychain.** There is no `URLSession` in the codebase. Keep it
  that way; analysis runs through the local `claude` CLI.
- **We only write** `~/.claude/state/**`, `~/Library/Application Support/EpiScope/`,
  our LaunchAgent plist, and a scratch dir under the **per-user** temp root —
  not `/private/tmp`, which any local account can read and analysis packets are
  verbatim conversation text. Another tool's config is edited additively, with a
  backup, never on invalid JSON, and written *through* a symlink so a dotfiles
  repo keeps owning the file (see `ClaudeHooks`).
- **Everything under `~/.claude` and `~/.codex` is untrusted input**, including
  what we published there ourselves — any local process can rewrite it, and a
  prompt-injected agent is exactly the population this app watches. Validate an
  id before it names a file (`SessionID.isValid`), hand values to `osascript` as
  `argv` instead of interpolating them into script text, and keep model output
  out of clickable links (`MarkdownRenderer.clickableTarget`).
- **Per-provider behaviour is a `switch` on `SessionProvider`**, never a path
  substring and never `provider == .claude` at the call site — put the answer on
  the enum (`watchRoot`, `supportsWindowedStats`) so a new provider fails to
  compile, or is derived via `allCases`, instead of inheriting the Claude answer.
  Asking `url.path.contains("/.claude/projects/")` is what dropped Codex and
  Claude Desktop from every daily report.
- **The project-directory codec lives in `ClaudeProjectPath`.** Encoding a cwd is
  exact; decoding a directory name is a guess that is wrong whenever the project
  name contains a dash (half of them here). Decode only to discover; label with
  the cwd the index read from the transcript.
- **Every file we own is written atomically** (tmp + rename).
- **Transcripts are never loaded whole.** Parsing is incremental: keep the
  `parsedSize` cursor and read only the appended tail. The viewer caps what it
  shows.
- **Token counts dedupe by `requestId`** — Claude writes several streaming
  records per API call, and counting them all inflates usage 2–5×.
- **`cc-states.json` is a contract**, not an implementation detail. `cc-open` and
  external scripts read it; keep the v1 envelope and the atomic rename.

## Conventions

- Write in the style of the surrounding code: same comment density, naming and
  idioms. Comments explain **why**, not what — the codebase leans on short
  paragraph comments above non-obvious blocks.
- Prefer surgical edits. Do not restructure working code without a reason.
- All code, comments, identifiers, commit messages and product-facing strings are
  in English.
- User-visible behaviour is specified in `docs/business-cases.md`. It follows the
  OpenSpec convention: `### Requirement:` with SHALL, `#### Scenario:` with
  **WHEN** / **THEN**. When you change behaviour a user can observe, update the
  matching scenario in the same change.
- `CHANGELOG.md` follows Keep a Changelog and tracks `MARKETING_VERSION` and the
  `vX.Y` tags. Add entries when shipping, not on every commit.

## Release

`release.sh` builds a universal binary, signs it with hardened runtime, notarizes
it and staples both the `.app` and the DMG. Releasing, notarizing, tagging and
pushing are **outward actions**: never run them unless explicitly asked.
`docs/homebrew.md` covers the cask.

## Notes that are easy to get wrong

- The tracker ticks at **1 s**, not 0.5 s. Older comments claimed otherwise and
  were wrong; trust `TerminalTracker.interval`.
- A state must hold for **two consecutive ticks** before a banner fires or is
  withdrawn. Ghostty intermittently returns an empty surface list for a live
  process, which used to flap the state and spam notifications.
- Terminal binding is vetoed by process ancestry: a JetBrains-hosted session must
  not match a Ghostty window that merely shares its working directory.
- The report text view builds a **TextKit 1** stack on purpose — a plain
  `NSTextView()` comes up on TextKit 2, and the code-chip layout manager cannot be
  installed there.
- `.claude/` is gitignored; local settings never belong in a commit.
