# EpiScope

A menu-bar app and window that tracks [Claude Code](https://claude.com/claude-code),
[OpenAI Codex](https://github.com/openai/codex-cli) and Claude Desktop sessions
on macOS.

It lights up the menu bar when one of your sessions is waiting for permission,
and shows every session on the machine in one window: tokens, cost, status, the
transcript of each conversation and a spend timeline.

Pure AppKit (no SwiftUI), no network and no analytics — everything stays local.
It reads `~/.claude/**` and `~/.codex/**`, and publishes session state to
`~/.claude/state/cc-states.json` for external consumers.

## Features

**Menu bar**
- A `?` icon in the menu bar. It turns red and blinks at 1 Hz while a Claude Code
  session waits for permission.
- An optional system sound when a new permission prompt appears (pick it in
  _Settings → Sound_).
- The menu lists the waiting sessions with folder, tool and waiting time. A click
  copies the session id and focuses the session's terminal (the same logic as the
  main table). App settings (Launch at Login, Sound and the rest) live in the
  app's **Settings** menu; the status bar is about sessions only.

**Main window (list)**
- A session table with the columns **Color · Vendor · Model · Status · Path ·
  Title · Input · Changes · Last Activity** by default. The rest (Perm Wait,
  Name, Started, User msgs, Turns, Branch, Cache, Output, Cost) are turned on in
  _Settings → Columns_.
- The **Status** column: `Waiting` on red (waiting for permission), `Busy` with
  running dots (the model is typing), `Finished` on yellow (the turn is over and
  the window has not been opened yet — the tracker's verdict), `Idle` (the pid is
  alive), `—` (not running).
- **Model** shows the name plus the reasoning effort for Codex (for example
  `gpt-5.5 xhigh`, read from `turn_context.payload.effort`).
- **Title** stretches automatically to the free width of the window.
- Selecting a row **highlights its segment in the chart**: the others fade to
  alpha 0.18 and the selected session moves down the stack, to the baseline.
- Esc or a click outside the table clears the selection.
- The window title shows the session count and the indexing progress:
  `EpiScope · 187 sessions · Loading 50 / 187`.
- Above the table sits a stacked token chart with time axes. Its window is
  configured in _Settings → Chart Window_ (1/2/5/7 days); the bucket size scales
  so that roughly 100–250 columns remain.

**Details mode (double-click a finished session; for a live one, the Messages button)**
- The session title and its relative path move into the window title. The toolbar
  holds Back, the session actions and a search field.
- On top: a line or stacked chart of the spend of **this session only**, with
  Input / Cache / Output checkboxes. Bars are 15 minutes wide and empty windows
  are skipped.
- Below: the user ↔ model conversation (tools and diffs are hidden).
- Markdown in the model's answers is rendered by a built-in parser: headers,
  **bold**, *italic*, `code`, fenced ```code blocks```, lists, blockquotes, and
  tables drawn with Unicode box-drawing characters
  (`┌─┬─┐ │ ├─┼─┤ │ └─┴─┘`) with tinted borders.
- Transcript search uses the same field; Enter jumps to the next match.

**Full-text search (⌘F)**
- A deep-search mode in the main window (the magnifier left of the filter, or ⌘F)
  over a SQLite FTS5 index of the text of every conversation — with no external
  dependency (the system `libsqlite3`). Results are per-message cards with
  highlighted matches; a click opens the session, scrolls to the message and
  washes it. The index is built incrementally and survives relaunches.

**AI Insights (observability over the whole fleet)**
- An analytics layer on top of the telemetry EpiScope already collects. Local
  first: the numbers come from the index, the narrative from a headless
  `claude -p` run. Nothing leaves the machine.
- **Automatic**: a daily report every morning (for the previous day) and a
  separate weekly one on Mondays. One consolidated report: TL;DR, what needs
  attention, cost and savings, anomalies, patterns and hotspots, per-project
  health, CLAUDE.md candidates. A push notification opens Insights mode.
- Embedded in the main window as its own mode (the ✦ button, like deep search):
  the runs list on the left, the report on the right. It always works over the
  whole fleet, never over one selected session; a run is managed from the list's
  right-click menu.
- **Only two controls** (_Settings_): on/off and the analysis model (Sonnet 4.6
  by default / Sonnet 5 / Opus 4.8 / Haiku 4.5). See
  [`docs/insights-lab.md`](docs/insights-lab.md).

**Indexer**
- **Incremental**: for sessions it already knows, it reads only the bytes added
  since the last index instead of the whole jsonl. An active 50 MB session is
  indexed in milliseconds.
- Polls every 2 seconds, plus an immediate kick when the live state changes (a
  session started or died).
- Streaming records are deduplicated by `requestId`, so the token counters match
  Claude's `/usage`.
- The real cwd is read from the jsonl body (the `cwd` field) instead of being
  reconstructed from the folder name, so paths with a hyphen (`my-project`) do
  not turn into `my/project`.
- **Temporary sessions** (`/private/tmp/*`, `/private/var/*`) are skipped
  entirely while the toggle is off — not indexed, not counted, not part of the
  loading progress.
- Cost is computed from a model price list: Opus 4.x ($5/$25), Sonnet 4.x
  ($3/$15), Haiku 4.5 ($1/$5), Fable 5 / Mythos 5 ($10/$50), GPT-5.x ($5/$10),
  and so on. Update prices in `SessionIndex.pricingTable`.

**Terminal integration (always on)**
- EpiScope is the session tracker: it works out which terminal hosts each CC
  session and publishes a snapshot to `~/.claude/state/cc-states.json` for
  external consumers (`kitty-painter.py`, `cc-open`). Full adapters (window/tab
  plus focus): kitty (`kitten @ ls`), iTerm2 and Terminal.app (AppleScript,
  joined by tty), Ghostty 1.3+ (AppleScript, joined by working directory),
  Agterm (`agtermctl` plus `AGTERM_SESSION_ID` / `AGTERM_WINDOW_ID` from the
  process environment — an exact window/session binding, see
  [`docs/agterm.md`](docs/agterm.md)). For xterm and anything else the terminal
  kind is detected from the process ancestry, without a window.
- Every live session in the table carries its terminal's icon. Icons are taken at
  runtime from the installed applications; only the kitty mascot is bundled.
- A double click on a live session focuses its terminal window or tab through the
  `cc-open` script (looked up in `~/.local/bin`, `~/bin`, `~/dotfiles/bin`,
  `/usr/local/bin`, `/opt/homebrew/bin`, then the bundled copy; override it with
  `defaults write … ccOpenPath`). kitty, iTerm2, Terminal, Ghostty and Agterm get
  the exact tab; xterm activates XQuartz; with no window at all, a fresh terminal
  opens at the session's cwd. A double click on a dead session opens its details.
- Notifications: a banner on `Finished` and `Needs permission`; a click leads to
  the terminal through the same `cc-open`, and the banner is withdrawn as soon as
  the session is visited.
- The `Finished` status (a yellow badge) is the tracker's verdict: the turn is
  over and the window has not been opened yet.

**Other**
- A prebuilt LaunchAgent plist for autostart
  (`~/Library/LaunchAgents/almazko.EpiScope.plist`), enabled on first launch.
- A session's colour is a deterministic FNV-1a hash of its sessionId → HSB, so
  the same session keeps one hue everywhere.
- The session index lives in
  `~/Library/Application Support/EpiScope/sessions.json`.

## Install

Grab the DMG from the
[releases](https://github.com/almazko/EpiScope/releases), drag the app to
`/Applications` and launch it. Or install it from the tap:

```bash
brew tap almazko/tap
brew install --cask episcope
```

## Build from source

```bash
git clone https://github.com/almazko/EpiScope.git
cd EpiScope
open EpiScope.xcodeproj
```

The minimum target is macOS 14.0 (Sonoma). For a test build, press ⌘R in Xcode.

## Release

`release.sh` builds the Release configuration, signs it, packs a DMG, notarizes
it with Apple and staples the ticket:

```bash
# one-time: store a notary profile in the Keychain
xcrun notarytool store-credentials episcope-notary \
    --apple-id <your-id> \
    --team-id <your-team-id> \
    --password <app-specific-password>

./release.sh
# → EpiScope.dmg next to the script
```

The profile name can be overridden with `EPISCOPE_NOTARY_PROFILE`. The DMG is
mounted as `/Volumes/EpiScope-<version>`, because otherwise the path would clash
with the LaunchServices-registered `EpiScope.app` and TCC would block the write.

## System requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon or Intel
- ~3 MB on disk (universal .app), ~30 MB RAM when idle

## License

MIT — see [LICENSE](LICENSE).
