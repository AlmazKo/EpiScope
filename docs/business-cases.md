# EpiScope — business cases

This spec describes the product scenarios: **why** the app exists, **who** gets
value from it and when, **where** each case is implemented, and **which
observable signs** mean the case is covered.

Related technical docs: [`file-io.md`](file-io.md) (what we read and write),
[`insights-lab.md`](insights-lab.md) (the analytics layer),
[`agterm.md`](agterm.md), [`homebrew.md`](homebrew.md).

## How to read and extend this file

The format follows the [OpenSpec](https://github.com/Fission-AI/OpenSpec)
convention: plain Markdown, no custom syntax.

- `## BC-NN · Name` — a **case**, one unit of value. The id is stable and is not
  reused after a case is removed. The line below the heading holds the
  metadata: actor, priority, files that implement it.
- `### Requirement: …` — a **requirement**: one checkable statement written with
  `SHALL` or `SHALL NOT`. A requirement without scenarios is not specified.
- `#### Scenario: …` — a **scenario**: behaviour over time.
  `- **GIVEN**` (precondition, optional) → `- **WHEN**` (event) →
  `- **THEN**` (system reaction); continue with `- **AND**`.
- `**Limits:**` — deliberate limits of the implementation, not bugs.
  `**Out of scope:**` — what the case does not cover on purpose.

Reference a case by id (`BC-04`) and a behaviour by scenario name
(`BC-01 → Scenario: Terminal adapter flaps`). Write UI paths as
`Settings → Columns`.

## Case map

- **P0 — the product does not exist without these**
  - [BC-01 · React to a permission prompt](#bc-01--react-to-a-permission-prompt) — operator
  - [BC-02 · Get back to a session](#bc-02--get-back-to-a-session) — operator
  - [BC-03 · See the whole fleet in one window](#bc-03--see-the-whole-fleet-in-one-window) — operator
- **P1 — why people come back**
  - [BC-04 · Cost and token usage](#bc-04--cost-and-token-usage) — budget-owner
  - [BC-05 · Watch the account limits](#bc-05--watch-the-account-limits) — budget-owner
  - [BC-06 · Search every conversation](#bc-06--search-every-conversation) — operator
  - [BC-07 · Review one session](#bc-07--review-one-session) — operator
  - [BC-08 · Scheduled fleet insights](#bc-08--scheduled-fleet-insights) — budget-owner
- **P2 — plumbing**
  - [BC-09 · Resume and clean up sessions](#bc-09--resume-and-clean-up-sessions) — operator
  - [BC-10 · Publish state for scripts](#bc-10--publish-state-for-scripts) — external-consumer

---

## Context

A developer runs **several agent sessions in parallel** on one machine (Claude
Code, OpenAI Codex, Claude Desktop), in different terminals and projects. Each
session is a separate process. It works for minutes, then stops and waits for
permission, and it spends money and account quota all the time.

macOS gives no way to watch this. The state is spread across `~/.claude/**`,
`~/.codex/**` and terminal windows. The developer learns about an idle session,
an overspend or an exhausted limit only after switching to the tab.

**EpiScope is an observability layer over that fleet.** Positioning:
*observability and monitoring first*; analytics is a layer on top of the
telemetry we already collect.

**Boundaries.** One machine, one account, macOS 14+. Other tools own the source
of truth; EpiScope reads and aggregates their files. It writes only
`~/.claude/state/**` and its own directory in Application Support. There is no
network.

### Actors

| Actor | Who | What they need |
|---|---|---|
| `operator` | the developer at the machine, 2–10 live sessions | lose no time on idle sessions, reach the right session fast |
| `budget-owner` | the same person at the end of the week | see where money and quota went, and where the systemic loss is |
| `external-consumer` | the `cc-open` and `kitty-painter.py` scripts | a machine-readable snapshot of session state |

`operator` and `budget-owner` are the same person in two modes. The product does
not separate them by rights or by interface.

### What we optimise

| Pain | Metric | Product lever | Case |
|---|---|---|---|
| a session waits for permission and nobody sees it | time from prompt to reaction | menu-bar indicator, banner, sound | BC-01 |
| "which window is this session in?" | time to get back to a session | terminal tracker + `cc-open` | BC-02 |
| spending is opaque | share of cost explained per project | index + chart + cost columns | BC-04 |
| the limit is hit without warning | a warning before the refusal | 5h and weekly gauges | BC-05 |
| "we discussed this already — where?" | time to find it in history | FTS5 over every conversation | BC-06 |
| systemic losses stay invisible | a regular review with no manual work | daily and weekly Insights | BC-08 |

---

## BC-01 · React to a permission prompt

`actor: operator` · `priority: P0` · `code: EpiScope/TerminalTracker.swift, EpiScope/AppDelegate.swift, EpiScope/SessionMonitor.swift`

**Job.** While the agent waits for a yes or no, the work stops. Learn about it
without checking tabs.

### Requirement: Signal a pending prompt

The app SHALL signal to the operator that a session waits for permission,
without the operator switching to the terminal tab.

#### Scenario: A session stops on a prompt
- **WHEN** any session enters the waiting-for-permission state
- **THEN** the `?` menu-bar icon turns red and blinks at 1 Hz
- **AND** the selected system sound plays if `Settings → Sound` is on

#### Scenario: Nothing is waiting any more
- **WHEN** the last waiting session is served
- **THEN** the icon stops blinking and returns to its normal look

#### Scenario: The list of waiting sessions
- **WHEN** the operator opens the status-bar menu
- **THEN** every waiting session shows its folder, its tool and how long it has waited
- **AND** the menu shows `Nothing needs attention` when nothing waits

#### Scenario: A session that never prompts
- **GIVEN** the session runs in `bypassPermissions`, `auto` or `plan` mode
- **WHEN** it calls a tool
- **THEN** the app does not count it as waiting — no blink, no menu entry

#### Scenario: A session that auto-approves edits
- **GIVEN** the session runs in `acceptEdits` mode
- **WHEN** it calls `Edit`, `Write`, `MultiEdit` or `NotebookEdit`
- **THEN** the app does not count it as waiting
- **AND** any other tool (for example `Bash`) still counts as a prompt

### Requirement: Fire a banner only on a settled state

The app SHALL require a state to hold for two consecutive tracker ticks before
it posts or withdraws a banner.

#### Scenario: The state settles
- **GIVEN** the waiting state held for two ticks
- **WHEN** the tracker publishes the new state
- **THEN** a `Needs permission` banner arrives

#### Scenario: Terminal adapter flaps
- **GIVEN** Ghostty's AppleScript sometimes returns an empty surface list for a live process
- **WHEN** the state changes for one tick and changes back
- **THEN** no banner is posted and no delivered banner is withdrawn

### Requirement: Reach the terminal from the notification

The app SHALL take the operator from a notification to the session's terminal in
one action.

#### Scenario: Click on a banner or on a menu row
- **WHEN** the operator clicks the banner or the waiting session's row in the menu
- **THEN** the session's terminal comes to the front and the session id is copied to the clipboard
- **AND** the app uses the same route as a double click in the table (BC-02)

### Requirement: Clear the alarm once the session is visited

The app SHALL clear the alarm as soon as the session is visited, and arm it
again on the next prompt.

#### Scenario: The session is opened
- **WHEN** the session's terminal window gets focus
- **THEN** the alarm clears and the delivered banner is withdrawn

#### Scenario: A detached session with no terminal
- **GIVEN** the session is alive but no terminal hosts it
- **WHEN** the operator acknowledges the prompt — taps the banner or opens the session
- **THEN** the blink stops and the session stays in the needs-attention list
- **AND** the next prompt from that session arms the alarm again

**Out of scope:** the operator cannot answer a prompt inside EpiScope. The
product only brings the person to the terminal.

---

## BC-02 · Get back to a session

`actor: operator` · `priority: P0` · `code: EpiScope/TerminalTracker.swift, EpiScope/cc-open, EpiScope/TerminalIntegration.swift, EpiScope/MainWindowController.swift`

**Job.** Land in the right session's window instead of hunting for the tab.

### Requirement: Open the window of a live session

The app SHALL bring forward the exact terminal window or tab that hosts the
session.

#### Scenario: A terminal with exact binding
- **GIVEN** the session runs in kitty, iTerm2, Terminal.app, Ghostty or Agterm
- **WHEN** the operator double-clicks the session row
- **THEN** `cc-open` focuses that window or tab

#### Scenario: A terminal with no window model
- **GIVEN** the session runs in xterm
- **WHEN** the operator opens the session
- **THEN** the app activates XQuartz and does not look for a window

#### Scenario: An IDE terminal
- **GIVEN** the session runs in a JetBrains IDE terminal, or in the Claude desktop app
- **WHEN** the operator opens the session
- **THEN** the app brings that application forward, because it exposes no per-tab focus API

#### Scenario: The terminal is unknown but the cwd is known
- **WHEN** the operator opens the session
- **THEN** the app opens a new terminal at the session's `cwd` — kitty first, Terminal.app as the fallback

#### Scenario: The session runs in more than one place
- **GIVEN** the session was resumed in a new terminal while the first one is still alive
- **WHEN** the operator opens the session
- **THEN** the app ranks the matches and picks the focused instance first, then the one with the newest `startedAt`
- **AND** it never picks an arbitrary match

#### Scenario: Another window sits in the same directory
- **GIVEN** the session runs in a JetBrains terminal and a Ghostty window is open in the same directory
- **WHEN** the tracker matches the session to a surface
- **THEN** process ancestry vetoes the match and the Ghostty window is not chosen

#### Scenario: The terminal cannot be located
- **WHEN** the operator taps the banner or the menu row for such a session
- **THEN** the app reveals the session in the table
- **AND** it does not spawn a stray terminal

### Requirement: Show details for a dead session

The app SHALL open the session details instead of a terminal when the tracker
knows of no host for the session.

#### Scenario: Double click on a finished session
- **WHEN** the operator double-clicks a row with no tracked terminal
- **THEN** the details mode opens (BC-07)

### Requirement: Resolve cc-open predictably

The app SHALL look for `cc-open` in `~/.local/bin`, `~/bin`, `~/dotfiles/bin`,
`/usr/local/bin` and `/opt/homebrew/bin`, and SHALL fall back to the copy inside
the app bundle.

#### Scenario: A clean install with no user copy
- **WHEN** the operator opens a session
- **THEN** the bundled `cc-open` runs, so a double click works out of the box

#### Scenario: A custom script location
- **GIVEN** the `ccOpenPath` default is set
- **WHEN** the operator opens a session
- **THEN** the app runs that binary and skips the default search

---

## BC-03 · See the whole fleet in one window

`actor: operator` · `priority: P0` · `code: EpiScope/MainWindowController.swift, EpiScope/SessionIndex.swift, EpiScope/SessionMonitor.swift`

**Job.** One screen that shows every session on the machine and its state right
now.

### Requirement: One screen with every session

The app SHALL show a table of every session on the machine above a stacked usage
chart.

#### Scenario: The main window opens
- **WHEN** the operator opens the main window
- **THEN** the table shows Color, provider icon, terminal icon, Model, Status, Path, Title, Input, Changes and Last Activity
- **AND** Perm Wait, Name, Started, User msgs, Turns, Branch, Cache, Output and Cost are hidden until `Settings → Columns` turns them on

### Requirement: Read a session's state at a glance

The app SHALL show each session's state as one of `Waiting`, `Busy`, `Finished`,
`Idle` or `—`.

#### Scenario: The status values
- **WHEN** a session waits for permission, types, has finished a turn, is merely alive, or is not running
- **THEN** the status reads `Waiting`, `Busy` (with an elapsed timer), `Finished`, `Idle` or `—`

#### Scenario: A finished turn nobody looked at
- **GIVEN** the session's status is `Finished`
- **WHEN** the operator opens its window
- **THEN** the status resets

#### Scenario: A session with no reachable terminal
- **WHEN** the table redraws
- **THEN** that row is dimmed
- **AND** `-p` and Claude Desktop sessions show their own marker instead of a terminal icon

### Requirement: Tie the selection to the chart

The app SHALL highlight the selected session's segment in the chart.

#### Scenario: A row is selected
- **WHEN** the operator selects a table row
- **THEN** that session's segment stays lit and the others fade to alpha 0.18

#### Scenario: The selection is cleared
- **WHEN** the operator presses Esc or clicks outside the table
- **THEN** the selection clears and the chart returns to its normal look

### Requirement: Group by project

The app SHALL be able to group the table and the chart by working directory.

#### Scenario: Grouping is on
- **GIVEN** `Settings → Group by Directory` is on
- **WHEN** the table rebuilds
- **THEN** sessions are grouped by project and the chart follows the grouping
- **AND** temporary sessions (`/private/tmp`, `/private/var`) stay hidden until their toggle is on

### Requirement: Index without blocking the interface

The app SHALL index incrementally and show progress while it works.

#### Scenario: The first load
- **WHEN** indexing runs
- **THEN** the window title shows the session count and the loading progress

#### Scenario: A live session grows
- **GIVEN** a live session's transcript is 50 MB
- **WHEN** new lines are appended
- **THEN** the app reads only the new bytes and reindexes in milliseconds

### Requirement: Keep the filter across navigation

The app SHALL keep the table's quick filter when the operator moves into a
session, into search or into Insights.

#### Scenario: Coming back to the list
- **GIVEN** the quick filter holds a query
- **WHEN** the operator opens a session, search or Insights and goes back
- **THEN** the filter and the filtered list are still there

### Requirement: Keep a session's colour stable

The app SHALL colour a session deterministically from its `sessionId`.

#### Scenario: One session in several surfaces
- **WHEN** the session appears in the table, in the chart and in the menu
- **THEN** all of them use the same hue (FNV-1a hash of `sessionId` → HSB)

---

## BC-04 · Cost and token usage

`actor: budget-owner` · `priority: P1` · `code: EpiScope/SessionIndex.swift, EpiScope/TokenChartView.swift`

**Job.** See where the money goes — which projects and sessions eat it.

### Requirement: Split usage by billing class

The app SHALL split tokens into input, cache write, cache read and output, and
SHALL price them from the model price table.

#### Scenario: A transcript is indexed
- **WHEN** the indexer parses a session transcript
- **THEN** the tokens are split into the four classes
- **AND** the cost comes from `SessionIndex.pricingTable`

#### Scenario: Streaming records of one request
- **GIVEN** the transcript holds several records with the same `requestId`
- **WHEN** the app counts tokens
- **THEN** it counts the request once, so the totals match `/usage` in Claude Code

### Requirement: Let the chart window and detail be chosen

The app SHALL let the operator pick the chart window and the bucket size.

#### Scenario: Choosing the window
- **WHEN** `Settings → Chart Window` is set to 1, 2, 5 or 7 days
- **THEN** the bars rebuild for that window

#### Scenario: Choosing the bucket size
- **WHEN** `Settings → Chart Bars` is set to Auto, 5 min, 15 min or 1 hour
- **THEN** the chart uses that step
- **AND** Auto picks a step that keeps roughly 100–250 columns

#### Scenario: The chart recomputes
- **WHEN** the chart recomputes
- **THEN** the bucket grid stays anchored to clock boundaries, so bars for past days do not grow

### Requirement: Take the project from the transcript

The app SHALL read the working directory from the transcript body, not from the
folder name.

#### Scenario: A hyphen in the project name
- **GIVEN** the project is called `my-project`
- **WHEN** the session enters the index
- **THEN** the path stays `my-project` and does not become `my/project`

**Out of scope:** budgets and threshold alerts. The product reports the fact; it
does not guard a limit (see open question OQ-1).

---

## BC-05 · Watch the account limits

`actor: budget-owner` · `priority: P1` · `code: EpiScope/LimitChart.swift, EpiScope/ClaudeHooks.swift, EpiScope/episcope-statusline.sh`

**Job.** Learn that the quota is running out before the agent hits the wall.

### Requirement: Show real percentages when the hook is installed

The app SHALL show the server-side usage percentages when the status-line hook
is installed.

#### Scenario: The hook is installed
- **GIVEN** the status-line hook is installed from `Settings → Claude Code Hooks`
- **WHEN** the operator opens the status-bar dropdown
- **THEN** the gauges show the real percentages for the 5-hour window and for the week
- **AND** a usage-against-time zone is drawn next to them

### Requirement: Reconstruct the windows without the hook

The app SHALL reconstruct the windows and the cap from message timestamps when
no server data is available.

#### Scenario: No hook is installed
- **WHEN** a gauge needs data and no server percentages exist
- **THEN** 5-hour windows are built greedily — the first message opens a window `[t, t+5h)`
- **AND** weekly windows are 7-day blocks tiled from the first window's start
- **AND** the cap is estimated from the largest window observed

### Requirement: Warn about an overspend

The app SHALL show an overspend before the refusal, not after it.

#### Scenario: Usage outpaces the planned pace
- **WHEN** consumption runs ahead of an even pace to the end of the window
- **THEN** the forecast zone is filled with a diagonal hazard pattern

### Requirement: Roll a window over after its reset

The app SHALL roll a stale window over once its reset time has passed.

#### Scenario: The window passed its reset
- **GIVEN** the previous window was full
- **WHEN** the reset time passes
- **THEN** the gauge switches to the new window and does not stay stuck at full

### Requirement: Allow a manual cap

The app SHALL let the operator set the cap by hand.

#### Scenario: A custom cap is set
- **WHEN** the operator uses `Set 5h limit cap…` or `Set weekly limit cap…`
- **THEN** that value overrides the estimate and survives a relaunch

**Limits:** this is an approximation. Only Anthropic knows the true anchor and
cap; the real limit weighs tokens per model while we sum raw tokens; history
depth is bounded by how long the transcripts are kept (~30 days).

---

## BC-06 · Search every conversation

`actor: operator` · `priority: P1` · `code: EpiScope/SearchIndex.swift, EpiScope/SearchView.swift`

**Job.** Find which session discussed a thing, and what exactly was said.

### Requirement: Full-text search over every conversation

The app SHALL search the text of every session and SHALL add no external
dependency.

#### Scenario: A query in deep-search mode
- **WHEN** the operator types a query after ⌘F or the magnifier button
- **THEN** the results are per-message cards with the matches highlighted
- **AND** the search runs on a SQLite FTS5 index built on the system `libsqlite3`

### Requirement: Open the matching message from a result

The app SHALL open a found message inside its session.

#### Scenario: A result card is clicked
- **WHEN** the operator clicks a result card
- **THEN** the session opens, the transcript scrolls to that message and washes it
- **AND** the other matches of the query are highlighted too

### Requirement: Build the index incrementally and keep it

The app SHALL extend the index as messages appear and SHALL NOT rebuild it from
scratch after a relaunch.

#### Scenario: New messages arrive
- **WHEN** sessions gain new messages
- **THEN** the index is extended incrementally

#### Scenario: The app relaunches
- **WHEN** the app starts again
- **THEN** the index built earlier is available at once (`~/Library/Application Support/EpiScope/search.sqlite`)

### Requirement: Keep the filter and the search separate

The app SHALL keep the table's quick filter and the full-text search as two
different tools.

#### Scenario: Typing in the quick filter
- **WHEN** the operator types in the quick filter
- **THEN** the table rows are filtered by title, project and id
- **AND** message text is not searched

---

## BC-07 · Review one session

`actor: operator` · `priority: P1` · `code: EpiScope/MainWindowController.swift, EpiScope/MarkdownRenderer.swift, EpiScope/ReportsWindowController.swift`

**Job.** Understand what happened in one conversation and where its resources
went.

### Requirement: Show usage and the conversation

The app SHALL show that session's usage chart and its conversation in details
mode.

#### Scenario: Details open
- **WHEN** the operator double-clicks a finished session, or presses Messages on a live one
- **THEN** the chart above covers only that session — 15-minute bars that skip empty windows, with Input / Cache / Output checkboxes
- **AND** the conversation is shown below it

#### Scenario: What the transcript contains
- **WHEN** the transcript renders
- **THEN** only the user ↔ assistant dialogue is shown
- **AND** tool calls and diffs are hidden

### Requirement: Render Markdown with the built-in parser

The app SHALL render the model's Markdown without an external dependency.

#### Scenario: A formatted answer
- **WHEN** an answer contains markup
- **THEN** the app renders headers, lists, `code`, fenced blocks, quotes and tables drawn with box-drawing characters

### Requirement: Keep a large transcript from blocking the window

The app SHALL load a transcript off the main thread and SHALL cap how much of it
is shown.

#### Scenario: A transcript of tens of megabytes
- **WHEN** such a session opens
- **THEN** the load runs off the main thread and the early history is dropped
- **AND** a line at the top says that earlier history was omitted

### Requirement: Search inside the open transcript

The app SHALL search the open transcript from the same field that a search
result uses when it opens a session.

#### Scenario: A query over the open session
- **WHEN** the operator types in the details search field
- **THEN** the matches are highlighted and Enter moves to the next one

### Requirement: Offer the full session action set in details

The app SHALL offer the same actions in the details toolbar as the row's context
menu.

#### Scenario: The details toolbar
- **WHEN** details mode is open
- **THEN** Copy session ID, Copy Resume Command, Go to terminal, Reveal in Finder, Analyze and Delete are available

#### Scenario: Analyze Session
- **WHEN** the operator runs `Analyze Session…`
- **THEN** a retro report starts for that session
- **AND** the result is shown in Insights mode (BC-08)

### Requirement: Match the window title to the current mode

The app SHALL update the window title with the mode and SHALL NOT leave the
title of the previous screen.

#### Scenario: Viewing a session
- **WHEN** details mode is open
- **THEN** the window title is the project path and the subtitle is the session name

#### Scenario: Leaving details for Insights
- **GIVEN** a session is open in details mode
- **WHEN** the operator moves to Insights, for example through `Analyze Session…`
- **THEN** the window title stops showing the previous session

---

## BC-08 · Scheduled fleet insights

`actor: budget-owner` · `priority: P1` · `code: EpiScope/ReportsWindowController.swift, EpiScope/TranscriptExtractor.swift, EpiScope/AnalysisRunner.swift, EpiScope/ReportStore.swift, EpiScope/prompt-insights.md`

**Job.** Get a review once a day and once a week — what is stuck, where the
losses are, what to fix in the process — without doing it by hand.

### Requirement: Run daily and weekly reports on their own

The app SHALL run the review without the operator asking for it.

#### Scenario: The daily run
- **GIVEN** `Settings → Automatic Insights` is on
- **WHEN** the morning comes
- **THEN** a run starts over the previous day

#### Scenario: The weekly run
- **WHEN** Monday morning comes
- **THEN** a second run starts over the last 7 days
- **AND** it is saved as its own report and does not replace the daily one

#### Scenario: Almost nothing happened in the window
- **GIVEN** the report window holds fewer than two sessions
- **WHEN** the run is due
- **THEN** the app skips it silently and sends no notification

### Requirement: Produce one consolidated report from indexed numbers

The app SHALL build one report where the numbers come from the index and the
narrative comes from a local headless CLI run.

#### Scenario: Building a report
- **WHEN** a report is built
- **THEN** it holds TL;DR, needs-attention, cost & savings, anomalies, patterns and hotspots, per-project health, and CLAUDE.md candidates
- **AND** the numbers come from the index, including cached tool activity
- **AND** the model writes the narrative and the judgement, not the data collection

#### Scenario: A long-lived session
- **GIVEN** a session has been open for a month and holds large lifetime totals
- **WHEN** the daily report is built
- **THEN** it counts only the work done inside the report's window (interval attribution)

### Requirement: Take the operator from the notification to the report

The app SHALL take the operator from a notification to the finished report in
one tap.

#### Scenario: A run finishes
- **WHEN** the report is ready
- **THEN** a notification arrives and a tap opens Insights mode
- **AND** the mode lands on the newest run: the runs list on the left, the report on the right

#### Scenario: An unread report
- **GIVEN** a report arrived after the last visit to the mode
- **WHEN** the operator looks at the main window toolbar
- **THEN** the ✦ button shows an unread dot
- **AND** entering the mode clears it

### Requirement: Manage a run from the runs list

The app SHALL keep Insights mode free of run controls.

#### Scenario: Right click on a run
- **WHEN** the operator right-clicks a row in the runs list
- **THEN** Copy Report, Reveal in Finder and Delete are offered
- **AND** the mode holds no other run controls

### Requirement: Keep the analysis on the machine

The app SHALL run the analysis locally.

#### Scenario: A run starts
- **WHEN** a run starts
- **THEN** it runs a local headless `claude -p` and sends the data nowhere else

### Requirement: Expose exactly two controls

The app SHALL limit the Insights settings to a switch and a model choice.

#### Scenario: The settings for Insights
- **WHEN** the operator opens Settings
- **THEN** only `Automatic Insights` (on/off) and `Analysis Model` (Sonnet 4.6 by default, Sonnet 5, Opus 4.8, Haiku 4.5) are offered

**Out of scope:** a manual run over an arbitrary scope, and an ask-a-question
field. Both were removed on purpose — the surface stays automatic.

---

## BC-09 · Resume and clean up sessions

`actor: operator` · `priority: P2` · `code: EpiScope/MainWindowController.swift, EpiScope/SessionIndex.swift`

**Job.** Come back to yesterday's work and remove what is no longer needed.

### Requirement: Hand out a ready resume command

The app SHALL produce a command that reopens the session, with no path editing
by hand.

#### Scenario: Copy Resume Command for Claude
- **WHEN** the operator runs `Copy Resume Command` on a Claude session
- **THEN** the clipboard holds `cd '<cwd>' && claude --resume <id>`

#### Scenario: Copy Resume Command for Codex
- **WHEN** the operator runs `Copy Resume Command` on a Codex session
- **THEN** the clipboard holds `codex resume <id>`

### Requirement: Reach the original transcript

The app SHALL reveal the session's own file without copying or changing it.

#### Scenario: Reveal Transcript in Finder
- **WHEN** the operator runs `Reveal Transcript in Finder`
- **THEN** Finder opens the session's `.jsonl`

### Requirement: Make deletion reversible and confirmed

The app SHALL delete a session only after a confirmation and only to the Trash.

#### Scenario: Delete Session
- **WHEN** the operator runs `Delete Session…` and confirms
- **THEN** the transcript moves to the Trash
- **AND** the details of that session close if they are open

#### Scenario: Deleting a running session
- **GIVEN** the session is still running
- **WHEN** the confirmation sheet appears
- **THEN** it says that the session is still running

### Requirement: Keep temporary sessions out of the index

The app SHALL skip sessions from temporary directories entirely while their
toggle is off.

#### Scenario: A session in a temporary directory
- **GIVEN** temporary sessions are hidden
- **WHEN** indexing runs
- **THEN** sessions under `/private/tmp` and `/private/var` are not indexed
- **AND** they affect neither the session count nor the loading progress

### Requirement: Keep our data apart from other tools' data

The app SHALL store its own data in its own directory and SHALL NOT rewrite
files owned by other tools.

#### Scenario: Writing our own data
- **WHEN** the index or a report is saved
- **THEN** it is written under `~/Library/Application Support/EpiScope/` (`sessions.json`, `search.sqlite`, `reports/`)

---

## BC-10 · Publish state for scripts

`actor: external-consumer` · `priority: P2` · `code: EpiScope/TerminalTracker.swift, EpiScope/ClaudeHooks.swift`

**Job.** Give external tools the session state so they do not have to parse
`~/.claude` themselves.

### Requirement: Publish a state snapshot

The app SHALL publish the state of every session to
`~/.claude/state/cc-states.json`.

#### Scenario: A tracker tick
- **WHEN** a tracker tick passes (1 s, `TerminalTracker.interval`)
- **THEN** the snapshot is written as a v1 envelope with an atomic rename
- **AND** the file's `mtime` works as the heartbeat

### Requirement: Keep the contract above the implementation

The app SHALL be the single publisher of the snapshot and SHALL stay replaceable
for its consumers.

#### Scenario: A consumer reads the state
- **WHEN** `cc-open` or `kitty-painter.py` reads the file
- **THEN** it gets the full session state without touching `~/.claude` directly
- **AND** it does not check who wrote the file

### Requirement: Install hooks additively

The app SHALL add only the missing routes to another tool's `settings.json`, and
SHALL keep a backup.

#### Scenario: Installing the hooks
- **WHEN** the operator installs them from `Settings → Claude Code Hooks`
- **THEN** only the missing routes are added and a foreign status line is left alone
- **AND** the previous file is kept as `settings.json.episcope.bak`
- **AND** the replacement is atomic

#### Scenario: The foreign file is invalid
- **GIVEN** `settings.json` holds invalid JSON
- **WHEN** the operator asks to install the hooks
- **THEN** the install is refused and the file is left untouched

---

## Cross-cutting requirements

### Requirement: Stay local

The app SHALL work with no network, no accounts and no telemetry.

#### Scenario: Any work the app does
- **WHEN** the app indexes, analyses or publishes state
- **THEN** it reads only files under `~`
- **AND** it writes only `~/.claude/state/**` and its own directory in Application Support

### Requirement: Stay cheap in the background

The app SHALL stay a cheap background process: ~3 MB on disk (universal build)
and ~30 MB RAM when idle.

#### Scenario: The app is idle
- **WHEN** no session is active
- **THEN** indexing is driven by FSEvents and runs incrementally
- **AND** transcripts are parsed line by line and are never loaded whole
- **AND** the alert sound is played out of process by `afplay`

### Requirement: Degrade instead of failing

The app SHALL keep serving a case when an external dependency is missing.

#### Scenario: No claude CLI
- **WHEN** an analysis starts and the CLI is not found
- **THEN** the app offers to pick the binary and remembers it in `claudeCLIPath`

#### Scenario: No notification permission
- **WHEN** the system denies notifications
- **THEN** Settings shows a Notifications row that restores the grant

#### Scenario: An unknown terminal
- **WHEN** a session runs in an environment the tracker cannot name
- **THEN** the session is still listed and can still be opened (BC-02)

### Requirement: Leave other tools' files intact

The app SHALL edit another tool's config additively and with a backup.

#### Scenario: Editing a foreign config
- **WHEN** the app has to add its routes to a foreign file
- **THEN** the rules of BC-10 apply

### Requirement: Ship as a signed universal app

The app SHALL ship as a universal binary for macOS 14+, signed and notarized,
through a DMG and a Homebrew cask.

#### Scenario: A user installs it
- **WHEN** the user opens the DMG or installs the cask
- **THEN** the app passes Gatekeeper with no warning
- **AND** the App Store is not used, because the sandbox blocks the core of the product — reading `~/.claude` and `~/.codex`, running `ps`, `lsof` and `osascript`, FSEvents, and writing the tracker hook

## Non-goals

- The app SHALL NOT replace the terminal: the operator cannot answer the agent,
  type a prompt or continue a conversation inside EpiScope.
- The app SHALL NOT edit code or interfere with a running session.
- The app SHALL NOT go to the cloud: there is no report sharing and no team
  dashboard. The product lives on one machine.
- The app SHALL NOT act as a billing system: it prices from a local table, not
  from the provider's invoices.

## Open questions

- **OQ-1** — are threshold alerts on cost (BC-04) worth it, or are they noise?
- **OQ-2** — first-class `SessionSignals` (a stuck loop, rollbacks, a failing-test
  loop) would give richer patterns without parsing transcripts again; roadmap in
  [`insights-lab.md`](insights-lab.md).
- **OQ-3** — interval attribution for Codex and Claude Desktop: today it is exact
  only for Claude Code.
