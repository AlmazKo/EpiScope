# EpiScope — business cases

This spec describes the product scenarios: **why** the app exists, **who** gets
value from it and when, **where** each case is implemented, and **which
observable signs** mean the case is covered.

Related technical docs: [`file-io.md`](file-io.md) (what we read and write),
[`insights-lab.md`](insights-lab.md) (the analytics layer),
[`agterm.md`](agterm.md).

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

`actor: operator` · `priority: P0` · `code: EpiScope/TerminalTracker.swift, EpiScope/AppDelegate.swift, EpiScope/MenuBarChart.swift, EpiScope/SessionMonitor.swift`

**Job.** While the agent waits for a yes or no, the work stops. Learn about it
without checking tabs.

### Requirement: Show the fleet in the menu bar

The app SHALL draw the fleet in the menu bar as five fixed slots, one slot per
session that is busy or needs the operator, so what the machine is doing is
readable at a glance and the chart never changes width.

#### Scenario: Sessions are running
- **WHEN** sessions are busy and none needs the operator
- **THEN** each one fills a slot with a dashed bar whose dashes scroll upward
- **AND** the slots left over stay faint and still

#### Scenario: A session sits idle
- **GIVEN** a session is open but not working and needs nothing
- **WHEN** the chart is drawn
- **THEN** it takes no slot

#### Scenario: More sessions than slots
- **GIVEN** more than five sessions want a slot
- **WHEN** the chart is drawn
- **THEN** the slots go to the sessions that need attention first, and the rest are dropped
- **AND** the status-bar menu still lists every session that needs attention

#### Scenario: Nothing is happening
- **WHEN** no session is busy or waiting on the operator
- **THEN** all five slots are faint and nothing animates

### Requirement: Signal a pending prompt

The app SHALL signal to the operator that a session waits for permission,
without the operator switching to the terminal tab.

#### Scenario: A session stops on a prompt
- **WHEN** any session enters the waiting-for-permission state
- **THEN** its bar turns red, stops scrolling and blinks at 1 Hz
- **AND** the sound picked in `Settings → Alerts` plays, unless it is None

#### Scenario: A session waits for an answer
- **WHEN** a session finishes a step and waits on the operator
- **THEN** its bar turns amber, stops scrolling and blinks at 0.5 Hz

#### Scenario: An API failure ends a turn
- **WHEN** Claude or Codex ends a turn with a terminal API or stream error
- **THEN** its bar turns amber, stops scrolling and blinks at 0.5 Hz
- **AND** the dropdown lists it under `Needs attention` with a yellow Error icon
- **AND** opening the session through EpiScope acknowledges that alarm like a finished step

#### Scenario: Nothing is waiting any more
- **WHEN** the last waiting session is served
- **THEN** its bar stops blinking and goes back to scrolling

#### Scenario: The fleet dropdown
- **WHEN** the operator opens the status-bar menu
- **THEN** `Needs attention` lists every blocking request, finished step and failed turn
- **AND** `Active` lists every busy session, including sessions beyond the five visible slots
- **AND** every session has a coloured circular state icon: blue six-section donut loader for active, yellow checkmark for turn end, yellow exclamation mark for Error, red exclamation mark for permission or question requests
- **AND** each row shows the AI-generated task description on its first line
- **AND** its second line shows the project directory name and time since the last status change
- **AND** no text duplicates the status already conveyed by the icon
- **AND** long text truncates instead of widening the menu beyond the limit gauges
- **AND** the menu shows `No active sessions` when neither section has entries

#### Scenario: A Claude Desktop session has its own name
- **GIVEN** a Claude Desktop Code session has a name shown in Claude's sidebar
- **WHEN** EpiScope shows that session in the fleet dropdown
- **THEN** the same name is used as its task description
- **AND** a technical tracker label never replaces it

#### Scenario: The fleet dropdown stays alive while open
- **GIVEN** the status-bar menu remains open
- **WHEN** elapsed time advances
- **THEN** every visible session's `ago` label updates once per second without rebuilding or moving rows
- **AND** active icons show a large, clearly separated six-section donut whose active section rises through medium and full brightness on consecutive 10 fps ticks
- **AND** red blocking icons blink at 1 Hz and amber reaction icons blink at 0.5 Hz, matching the menu-bar bars
- **AND** the animation clock stops as soon as the menu closes

#### Scenario: A session that never prompts
- **GIVEN** the session runs in `bypassPermissions`, `auto` or `plan` mode
- **WHEN** it calls a tool
- **THEN** the app does not count it as waiting — no red bar, no menu entry

#### Scenario: A session that auto-approves edits
- **GIVEN** the session runs in `acceptEdits` mode
- **WHEN** it calls `Edit`, `Write`, `MultiEdit` or `NotebookEdit`
- **THEN** the app does not count it as waiting
- **AND** any other tool (for example `Bash`) still counts as a prompt

#### Scenario: A `/btw` side question is open
- **GIVEN** Claude Code publishes `status = waiting` and `waitingFor = dialog open` for a user-opened `/btw` overlay
- **WHEN** the independent main turn remains busy, finishes or is idle
- **THEN** EpiScope continues to show that main-turn state instead of `Waiting`
- **AND** the overlay causes no menu-bar attention, notification, sound or permission-wait time
- **AND** a real `needs_permission` hook signal still takes precedence

### Requirement: Fire a banner only on a settled state

The app SHALL require a state to hold for two consecutive tracker ticks before
it posts or withdraws a banner.

#### Scenario: The state settles
- **GIVEN** the waiting state held for two ticks
- **WHEN** the tracker publishes the new state
- **THEN** a `Needs permission` banner arrives

#### Scenario: Codex requests approval
- **GIVEN** a live Codex thread has an unresolved approval in its rollout
- **WHEN** that waiting state holds for two tracker ticks
- **THEN** a `Needs permission` banner arrives for that Codex thread
- **AND** answering the request withdraws the delivered banner

### Requirement: Put session context in the banner

The app SHALL make a session notification identifiable without spending banner
space on its model, terminal, answer options or notification grouping.

#### Scenario: An AI description exists
- **GIVEN** the session index has an AI-generated description
- **WHEN** EpiScope posts a `Finished`, `Error` or `Needs permission` notification
- **THEN** the first body line starts with `✨ ` and contains that description
- **AND** whitespace is collapsed and descriptions longer than 36 Unicode characters are truncated with `…`
- **AND** a blocking request's state message follows on a new line

#### Scenario: A finished notification title
- **GIVEN** a finished session lives at `/Users/alexander/tmp` and that user's home is `/Users/alexander`
- **WHEN** EpiScope posts its notification
- **THEN** the title is `~/tmp · Finished`
- **AND** the body does not repeat `Finished` or say `waiting for your input`

#### Scenario: An error notification title
- **WHEN** EpiScope posts a failed-turn notification
- **THEN** its title ends with ` · Error`
- **AND** its interruption level is `active`

#### Scenario: No AI description exists
- **GIVEN** the session index has no AI-generated description
- **WHEN** EpiScope posts a session notification
- **THEN** a blocking-request body contains only the state message and no empty context line
- **AND** a finished or failed-turn notification needs no body because its state is in the title

#### Scenario: Finished notification urgency
- **WHEN** EpiScope posts a finished-step notification
- **THEN** its interruption level is `active`

#### Scenario: Blocking-request notification urgency
- **WHEN** EpiScope posts a permission or question notification
- **THEN** its interruption level is `timeSensitive`

#### Scenario: One notification per session
- **WHEN** EpiScope posts a session notification
- **THEN** it uses the session's existing notification identifier
- **AND** it does not assign an additional notification group

#### Scenario: Terminal adapter flaps
- **GIVEN** Ghostty's AppleScript sometimes returns an empty surface list for a live process
- **WHEN** the state changes for one tick and changes back
- **THEN** no banner is posted and no delivered banner is withdrawn

### Requirement: Reach the session host from the notification

The app SHALL take the operator from a notification to the session's terminal or
desktop app in one action.

#### Scenario: Click on a banner or on a menu row
- **WHEN** the operator clicks the banner or the waiting session's row in the menu
- **THEN** the session's terminal or desktop app comes to the front and the session id is copied to the clipboard
- **AND** the app uses the same route as a double click in the table (BC-02)

#### Scenario: Click a Codex notification
- **GIVEN** the Codex App hosts the waiting thread
- **WHEN** the operator clicks its notification
- **THEN** EpiScope follows `codex://threads/<thread-id>`
- **AND** Codex App opens that exact local thread

### Requirement: Keep a request active until it is answered

The app SHALL distinguish an unresolved permission or question request from a
finished step. Visiting a request is not an answer, so it remains urgent until
Claude or Codex reports that the session has left the waiting state.

#### Scenario: The waiting session is opened
- **GIVEN** a session waits for a permission decision or an answer to a question
- **WHEN** the operator clicks its banner, menu row or table row
- **THEN** the terminal comes to the front
- **AND** its red menu-bar bar continues blinking
- **AND** visiting the request does not acknowledge it

#### Scenario: The operator answers the request
- **GIVEN** a session waits for a permission decision or an answer to a question
- **WHEN** Claude or Codex reports that the session has left `waiting`
- **THEN** that request stops driving the red blink
- **AND** its delivered banner is withdrawn

#### Scenario: A finished step is visited
- **GIVEN** a session has finished a step and shows `Finished`
- **WHEN** the operator opens it through EpiScope
- **THEN** its finished alarm clears immediately
- **AND** this acknowledgment does not apply to permission or question requests

**Out of scope:** the operator cannot answer a prompt inside EpiScope. The
product only brings the person to the hosting terminal or app.

---

## BC-02 · Get back to a session

`actor: operator` · `priority: P0` · `code: EpiScope/TerminalTracker.swift, EpiScope/cc-open, EpiScope/TerminalIntegration.swift, EpiScope/MainWindowController.swift`

**Job.** Land in the right session's window instead of hunting for the tab.

### Requirement: Open the window of a live session

The app SHALL bring forward the exact terminal window or tab that hosts the
session.

#### Scenario: The selected session has a known hosting application
- **GIVEN** a session is selected in the list or shown in details
- **AND** EpiScope can resolve the hosting application's icon
- **WHEN** the operator looks at the session action in the window toolbar
- **THEN** the action shows that application icon instead of a generic terminal
- **AND** clicking it opens the session through the same exact-session route

#### Scenario: No hosting application icon is available
- **GIVEN** the selected row has no resolvable application icon
- **WHEN** the toolbar shows its placeholder
- **THEN** the placeholder uses the same square footprint as an application icon
- **AND** the action does not shift when the selection changes

#### Scenario: Toolbar action icons
- **WHEN** the operator moves between list and details modes
- **THEN** every action icon uses the same square footprint
- **AND** system symbols share one point size and stroke weight
- **AND** navigation and document actions use the same unfilled outline style
- **AND** Insights uses the distinct `sparkles` mark rather than a Favorites star
- **AND** the Insights glyph uses the same animated pearlescent palette as an active-session badge
- **AND** non-square glyphs are fitted proportionally rather than stretched
- **AND** custom Refresh and Insights controls use the same square hover container

#### Scenario: Fleet and session toolbar actions
- **GIVEN** a session is selected in the list
- **WHEN** the operator looks at the toolbar action groups
- **THEN** Copy, Messages and Open session app stay in the session group
- **AND** Insights is grouped with Full Search as a fleet-level action
- **AND** the custom Insights button has the same circular hover size as adjacent actions

#### Scenario: A terminal with exact binding
- **GIVEN** the session runs in kitty, iTerm2, Terminal.app, Ghostty or Agterm
- **WHEN** the operator double-clicks the session row
- **THEN** `cc-open` focuses that window or tab

#### Scenario: A session runs in a Ghostty tab
- **GIVEN** the tracker published the terminal surface's stable Ghostty id
- **WHEN** the operator opens the session
- **THEN** `cc-open` resolves that terminal directly by id and focuses it
- **AND** Ghostty selects the native tab containing that surface
- **AND** app activation happens before terminal focus, so Ghostty cannot restore the previously selected tab over the target

#### Scenario: Ghostty sessions share an AI title
- **GIVEN** two live sessions have the same AI-generated task title
- **AND** a Ghostty tab title exactly matches one session's live name
- **WHEN** the tracker assigns that terminal surface
- **THEN** it binds the surface to the exact live-name match
- **AND** the other session cannot claim it through the shared AI title

#### Scenario: Ghostty scripting stalls
- **GIVEN** Ghostty does not complete the focus Apple Event
- **WHEN** the operator opens the session
- **THEN** `cc-open` stops waiting after a bounded interval
- **AND** it activates Ghostty without leaving a stuck `osascript` process

#### Scenario: A terminal with no window model
- **GIVEN** the session runs in xterm
- **WHEN** the operator opens the session
- **THEN** the app activates XQuartz and does not look for a window

#### Scenario: An IDE terminal
- **GIVEN** the session runs in a JetBrains IDE terminal
- **WHEN** the operator opens the session
- **THEN** the project path comes from the session transcript rather than the IDE agent process cwd
- **AND** the app passes the nearest project root through the running IDE's command-line launcher
- **AND** the IDE selects the corresponding macOS project tab
- **AND** it reuses the open project instead of initializing and disposing a duplicate
- **AND** an unrecognised or stale cwd only activates the IDE and is never opened as a project
- **AND** the app does not attempt to select a terminal tab inside the project

#### Scenario: A previously unknown application host
- **GIVEN** the session runs inside an application for which EpiScope has no adapter
- **WHEN** the tracker walks the process ancestry
- **THEN** the table loads that installed application's icon from its bundle id
- **AND** opening the session brings the application forward

#### Scenario: A session runs in Codex App
- **GIVEN** the tracker identifies the host bundle as `com.openai.codex`
- **WHEN** the operator opens the session
- **THEN** the bundled opener follows `codex://threads/<thread-id>`
- **AND** Codex App shows that exact local thread

#### Scenario: A session belongs to Claude App
- **GIVEN** the table identifies a Claude App Code or local-agent session
- **WHEN** the operator opens it from the table, menu or notification
- **THEN** the bundled opener follows that session type's exact Claude deep link
- **AND** Claude App shows that exact session instead of its last visible one

#### Scenario: A Claude Desktop Code tab mirrors a CLI transcript
- **GIVEN** the table session id matches `cliSessionId` in Claude Desktop's `claude-code-sessions` metadata
- **AND** that metadata identifies the tab as `local_<uuid>`
- **WHEN** the operator opens the session from the table, menu or notification
- **THEN** EpiScope follows `claude://claude.ai/epitaxy/local_<uuid>`
- **AND** this works while the session is waiting in plan mode as well as during a normal turn

#### Scenario: Claude local metadata uses two ids
- **GIVEN** the indexed metadata filename uses `local_<uuid>` and contains a different `cliSessionId`
- **WHEN** the operator opens that session from the table
- **THEN** EpiScope uses `cliSessionId` in the Claude deep link
- **AND** keeps `local_<uuid>` as its own stable index key

#### Scenario: The terminal is unknown but the cwd is known
- **GIVEN** no hosting application bundle can be determined
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

#### Scenario: Reveal a detached session while Insights is open
- **GIVEN** the main window is showing Insights
- **AND** a session has no terminal or desktop app EpiScope can focus
- **WHEN** the operator opens that session from the menu or a notification
- **THEN** the window changes to the session list before it comes forward
- **AND** the target session is selected without retaining the Insights title or state

### Requirement: Show details for a dead session

The app SHALL open the session details instead of a terminal when the tracker
knows of no host for the session.

#### Scenario: Double click on a finished session
- **WHEN** the operator double-clicks a row with no tracked terminal
- **THEN** the details mode opens (BC-07)

### Requirement: Keep the opener aligned with the snapshot

The app SHALL use only the `cc-open` copy inside its own bundle, so the opener
and the `cc-states.json` producer always implement the same protocol version.

#### Scenario: A user has another cc-open on PATH
- **GIVEN** an external `cc-open` exists in a conventional bin directory
- **WHEN** the operator opens a session
- **THEN** EpiScope ignores it and runs its bundled opener

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
- **THEN** the table shows Color, AI (provider), App (hosting application), Model, Status, Path, Title, Input, Changes and Last Activity
- **AND** Perm Wait, Name, Started, User msgs, Turns, Branch, Cache, Output and Cost are hidden until they are turned on

#### Scenario: Dropping every narrowing at once
- **GIVEN** a dragged range, filter text or a selected session is narrowing the table
- **WHEN** the operator looks at the rows area
- **THEN** a `Show all` button floats over it; the count stays in the title bar, which already reads "N of M"
- **AND** pressing it drops the range, the filter text and the selection together
- **AND** it is absent whenever there is nothing to undo, so an unfiltered table looks exactly as before

#### Scenario: The table has nothing to show
- **WHEN** no session survives whatever is narrowing the table
- **THEN** the rows area says so in place of the rows, and names the narrowing responsible: the dragged range, the filter text, the hidden temporary sessions, or nothing indexed yet
- **AND** where the narrowing is undone elsewhere, the message says where — a range clears by clicking the chart, temporary sessions come back from Settings
- **AND** the header, the chart and the layout are untouched: it is a placeholder over the rows, not a row

#### Scenario: Choosing which columns to show
- **WHEN** the operator right-clicks the table's header
- **THEN** a menu lists every named column with a tick against the visible ones, and choosing one toggles it
- **AND** `Settings → Columns` offers the same list and the same ticks — both act on the one setting, so neither can show a state the table does not have

#### Scenario: Sorting by a column
- **WHEN** the operator clicks a sortable column's header
- **THEN** the rows reorder by that column's own value, and a second click reverses it
- **AND** rows with no value for it (no custom name, no recorded start) collect at the end of the descending order

### Requirement: Read a session's state at a glance

The app SHALL show each session's state as one of `Waiting`, `Busy`, `Finished`,
`Error`, `Idle` or `—`.

#### Scenario: The status values
- **WHEN** a session waits for permission, types, has finished or failed a turn, is merely alive, or is not running
- **THEN** the status reads `Waiting`, `Busy` (with an elapsed timer), `Finished`, `Error`, `Idle` or `—`

#### Scenario: A finished turn nobody looked at
- **GIVEN** the session's status is `Finished`
- **WHEN** the operator opens its window
- **THEN** the status resets

#### Scenario: A finished turn in a host whose focus cannot be watched
- **GIVEN** the session runs somewhere no adapter reports window focus — a
  JetBrains terminal, the Claude app
- **WHEN** its Stop hook reports the turn finished
- **THEN** the status still reads `Finished`, because opening the session
  through EpiScope clears it and the next turn overwrites it
- **AND** an idle status alone never becomes `Finished` there: that guess leaves
  nothing to clear, so it would never go away

#### Scenario: A failed stream ends a live turn
- **GIVEN** Claude's API stream fails and no Stop hook fires
- **WHEN** Claude's live session status returns from `busy` to `idle`
- **THEN** the table shows a neutral `Error` badge instead of `Idle` or `Busy`
- **AND** the failed turn drives the amber reaction alarm and notification until the operator opens it through EpiScope
- **AND** acknowledging the alarm leaves the neutral `Error` badge visible until a later turn clears the error

#### Scenario: A Codex turn fails
- **GIVEN** a live Codex rollout ends with a terminal `error`
- **WHEN** the table refreshes
- **THEN** the table shows a neutral `Error` badge
- **AND** the failed turn drives the same amber reaction alarm as a Claude failure
- **AND** a retryable `stream_error` alone does not count as a failed turn
- **AND** a user-interrupted turn does not count as an error
- **AND** starting or completing a later turn clears the error

#### Scenario: A session with no reachable terminal
- **WHEN** the table redraws
- **THEN** that row is dimmed
- **AND** `-p` and Claude Desktop sessions show their own marker instead of a terminal icon

### Requirement: Date a session by its conversation

The app SHALL report last activity as the newest timestamped record in the
transcript, not as the file's modification time.

#### Scenario: The CLI touches an old transcript
- **GIVEN** the session's last message is days old
- **WHEN** the CLI appends bookkeeping records (mode, permission-mode, titles,
  agent names) or rewrites the file while it merely sits open
- **THEN** Last Activity keeps naming the last message, and the sort keeps the
  session where it belongs

#### Scenario: A transcript with no timestamped record
- **GIVEN** the file carries no record with a time of its own
- **THEN** the file's modification time is used

### Requirement: Tie the selection to the chart

The app SHALL highlight the selected session's segment in the chart.

#### Scenario: A row is selected
- **WHEN** the operator selects a table row
- **THEN** that session's segment stays lit and the others fade to alpha 0.18

#### Scenario: The selection is cleared
- **WHEN** the operator presses Esc or clicks outside the table
- **THEN** the selection clears and the chart returns to its normal look

### Requirement: Narrow the table to a time range

The chart is the only time axis over the whole fleet. The app SHALL let the
operator drag a range across it and SHALL keep in the table only the sessions
that billed tokens inside that range.

#### Scenario: A range is dragged
- **WHEN** the pointer is over a chart that has data
- **THEN** it is a crosshair, so the chart reads as something to drag across rather than a picture
- **AND** hovering a bar draws a panel beside it, at once and without a tooltip's delay, marking the bar it belongs to
- **AND** that panel names the bar's interval and total, then breaks the total down by the sessions (or projects) stacked in it, largest first
- **AND** each line carries the swatch its segment is drawn in, so a name can be matched to a band of the bar without guessing
- **AND** the figures are whatever the chart is currently measuring — tokens, cost or lines — and a bar with more segments than fit says how many were left out
- **AND** it does not appear while a range is being dragged, where the range's own caption already sits
- **WHEN** the operator presses on the chart and travels less than 10 pt
- **THEN** nothing is marked and the chart looks untouched — the press is still a click, not a range
- **WHEN** the operator drags across the chart past that distance
- **THEN** the range is marked and everything outside it dims, with its bounds, length and session count named above it
- **AND** the table keeps only the sessions that billed tokens in that range
- **AND** the title bar subtitle counts them as "N of M"

#### Scenario: The range is adjusted or dropped
- **WHEN** the operator drags an edge of the range
- **THEN** the range and the table follow that edge from the first pixel, since grabbing a handle is unambiguous
- **WHEN** the operator clicks the chart without dragging
- **THEN** the range clears, any selected session is deselected, and the whole fleet returns
- **AND** clearing is reachable regardless through the button over the table; Esc and a click below the last row still clear the selection alone

#### Scenario: The chart the range belongs to goes away
- **WHEN** the operator switches to Limits, or the index is rebuilt
- **THEN** the range clears rather than filtering the table from behind a chart that no longer shows it
- **AND** the selected session survives it — only a click on the chart means the operator asked for everything back

### Requirement: Add up what the table shows

The app SHALL total the table's numeric columns in a strip under the rows.

#### Scenario: The totals strip
- **WHEN** the table has rows
- **THEN** a strip under them totals Input, Cache read, Output, Cost, Turns,
  User messages, Changes and Perm wait, each under its own column
- **AND** it names the set it adds up — `Total · N sessions`
- **AND** columns whose values do not add up (model, status, last activity) stay empty

#### Scenario: The totals follow the table
- **WHEN** a range is dragged, the filter text changes or a source is narrowed
- **THEN** the totals describe the filtered set, not the whole index
- **WHEN** a column is resized, reordered, hidden, or the table is scrolled sideways
- **THEN** every total stays under the column it belongs to
- **WHEN** the table is empty, or the window is showing a session, search or Insights
- **THEN** the strip is not there at all

### Requirement: Limit the table to the chart window

The app SHALL offer a setting that keeps in the table only sessions last active
inside the chart window, and it SHALL be off by default.

#### Scenario: The toggle is on
- **GIVEN** `Settings → Chart Window Only` is on
- **WHEN** the table rebuilds
- **THEN** it holds only sessions whose last activity falls inside the chart window
- **AND** the count, the grouping and the chart all read that same set
- **AND** changing `Settings → Chart Window` changes which sessions those are

#### Scenario: The window holds nothing
- **GIVEN** the setting is on and the index is not empty
- **WHEN** no session was active inside the window
- **THEN** the empty table names the window and the setting responsible

#### Scenario: The toggle is off
- **WHEN** the app is first run
- **THEN** the setting is off and the table is the whole history

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

#### Scenario: A row while its session is being rescanned
- **GIVEN** a live Codex or Claude Desktop session, whose transcript is re-read whole on each pass
- **WHEN** the shallow pass republishes it before the deep scan lands
- **THEN** the row keeps the numbers from the previous pass
- **AND** it never blanks its title, project and cost between ticks

### Requirement: Keep settings in one window with sections

The app SHALL offer a settings window shaped like System Settings — a sidebar of
sections, each shown as islands — and SHALL keep the settings that need more
than a menu item there.

#### Scenario: Opening Settings
- **WHEN** the operator presses ⌘, or picks `EpiScope → Settings…`
- **THEN** a settings window opens with a source-list sidebar naming its
  sections — `Alerts`, `Sources` and `Insights` — each with its own tinted icon
- **AND** the section on screen is titled above its content
- **AND** its controls sit in rounded islands, one row per control, with the
  explanation under the island rather than beside the control

#### Scenario: One place per setting
- **WHEN** a setting has a section in this window
- **THEN** the menu bar does not carry a second way to reach it

#### Scenario: The banner permission
- **WHEN** `Settings → Alerts` appears
- **THEN** it reads the current notification grant from the system rather than a
  pref of its own, and says which of the three states it is in
- **WHEN** the grant has never been asked for
- **THEN** the button asks for it, and the state updates on the answer
- **WHEN** it was granted or refused
- **THEN** the button opens System Settings, which owns the switch from then on

#### Scenario: Choosing the alert sound
- **WHEN** the operator picks a sound in `Settings → Alerts`
- **THEN** it plays once, through the same player the alarm itself uses
- **AND** `None` silences the alarm without touching the banner

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

#### Scenario: Codex reports a cumulative token snapshot
- **GIVEN** `input_tokens` includes cached reads and cache writes
- **WHEN** the indexer parses `total_token_usage`
- **THEN** ordinary input is `input_tokens - cached_input_tokens - cache_write_input_tokens`
- **AND** cache writes and cache reads remain separate billing classes
- **AND** `reasoning_output_tokens` is not added to `output_tokens`, because it is already included there

#### Scenario: Codex reports only rate limits
- **GIVEN** a `token_count` record has no token usage info
- **WHEN** the indexer counts model responses
- **THEN** that record is not counted as a turn

#### Scenario: Streaming records of one request
- **GIVEN** the transcript holds several records with the same `requestId`
- **WHEN** the app counts tokens
- **THEN** it counts the request once, so the totals match `/usage` in Claude Code

### Requirement: Let the chart window and detail be chosen

The app SHALL let the operator pick the chart window and the bucket size.

#### Scenario: Choosing the window
- **WHEN** `Settings → Chart Window` is set to 1, 2, 5, 7 or 30 days
- **THEN** the bars rebuild for that window
- **AND** the axis widens its tick spacing so the labels stay apart

#### Scenario: Choosing the bucket size
- **WHEN** `Settings → Chart Bars` is set to Auto, 5 min, 15 min or 1 hour
- **THEN** the chart uses that step
- **AND** Auto picks a step that keeps roughly 100–250 columns

#### Scenario: The chart recomputes
- **WHEN** the chart recomputes
- **THEN** the bucket grid stays anchored to clock boundaries, so bars for past days do not grow

#### Scenario: Claude and Codex are both active
- **WHEN** the aggregate chart recomputes
- **THEN** it buckets usage from Claude transcripts and Codex rollouts together
- **AND** repeated Codex cumulative snapshots are converted to deltas and counted once

#### Scenario: A Codex response finishes
- **WHEN** `token_count` follows its `agent_message`
- **THEN** the session detail chart places the usage point at the `token_count` timestamp
- **AND** the usage-only record is not rendered as a transcript message

### Requirement: Use provider-specific cache pricing

The app SHALL account for cache writes using the model's pricing policy.

#### Scenario: Pricing a Codex cache write
- **GIVEN** the model predates GPT-5.6
- **THEN** cache writes use the ordinary input rate
- **GIVEN** the model is GPT-5.6 or newer
- **THEN** cache writes use 1.25 times the ordinary input rate

### Requirement: Take the project from the transcript

The app SHALL read the working directory from the transcript body, not from the
folder name.

#### Scenario: A hyphen in the project name
- **GIVEN** the project is called `my-project`
- **WHEN** the session enters the index
- **THEN** the path stays `my-project` and does not become `my/project`

#### Scenario: The chart groups the same project as the table
- **GIVEN** the chart discovers projects by listing directories, where the name alone is ambiguous
- **WHEN** it groups and colours bars by directory
- **THEN** it keys each bar on the cwd carried by the transcript record itself, the same source the table uses
- **AND** a hyphenated project is one group in both surfaces, not `my/project` in one and `my-project` in the other
- **AND** a record too old to carry a cwd falls back to the directory name, which is the previous behaviour

**Out of scope:** budgets and threshold alerts. The product reports the fact; it
does not guard a limit (see open question OQ-1).

---

## BC-05 · Watch the account limits

`actor: budget-owner` · `priority: P1` · `code: EpiScope/LimitChart.swift, EpiScope/AppDelegate.swift, EpiScope/ClaudeHooks.swift, EpiScope/episcope-statusline.sh`

**Job.** Learn that the quota is running out before the agent hits the wall.

### Requirement: Show real percentages when the hook is installed

The app SHALL show the server-side usage percentages when the status-line hook
is installed.

#### Scenario: The hook is installed
- **GIVEN** the status-line hook is installed from `Settings → Claude Code Hooks`
- **WHEN** the operator opens the status-bar dropdown
- **THEN** the gauges show the real percentages for the 5-hour window and for the week
- **AND** a usage-against-time zone is drawn next to them

#### Scenario: Codex reports only a weekly window
- **GIVEN** the latest Codex rollout reports a 10080-minute window and no 300-minute window
- **WHEN** the operator opens the status-bar dropdown
- **THEN** the Codex limits section shows the weekly gauge
- **AND** it does not show a 5-hour gauge

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

#### Scenario: A session leaves the index
- **WHEN** a session's transcript is deleted, from the app or outside it
- **THEN** its messages are dropped from the index and stop appearing in results
- **AND** the database does not keep growing on their account

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
- **AND** `Your messages` and `AI responses` independently toggle the orange user-message and purple assistant-response markers
- **AND** the lifecycle strip sits under the curves on the same time axis
- **AND** the conversation is shown below it

### Requirement: Show where a session's time went

The app SHALL show, on the usage chart's own time axis, the phases a session
passed through and the moments worth seeing against them. It SHALL keep what it
observed apart from what a transcript merely implies: a stall no record can
explain is never labelled as an approval prompt.

#### Scenario: A session with several turns
- **WHEN** details open
- **THEN** a strip under the curves gives each turn a Working block, from its prompt to the last record of that turn
- **AND** the silence before the next prompt is Idle, or Away once it passes twenty minutes
- **AND** the totals beside the checkboxes name each phase in its own colour and give its duration

#### Scenario: A permission prompt EpiScope watched
- **GIVEN** EpiScope was running while the session sat on an approval
- **WHEN** that session's details open
- **THEN** the wait is a Permission block at the moment it happened
- **AND** past fifteen minutes it continues as Away, the same split the `Waited` column counts

#### Scenario: A session that ran before its waits were recorded
- **WHEN** details open for such a session
- **THEN** the strip shows Working, Idle and Away only
- **AND** nothing in it is labelled Permission

#### Scenario: Point events on the axis
- **WHEN** the session contains errors, interrupts, compactions, edits or resumes
- **THEN** errors, interrupts and compactions strike the strip as coloured ticks at their moment
- **AND** every Edit or Write raises a tick in the lane above it, taller for more lines changed
- **AND** a resume is a hairline — exact for Codex, inferred from a long silence for Claude Code

#### Scenario: A session with no usage records
- **WHEN** such a session opens
- **THEN** the strip still draws
- **AND** the plot above it says that no usage data was recorded

#### Scenario: What the transcript contains
- **WHEN** the transcript renders
- **THEN** only the user ↔ assistant dialogue is shown
- **AND** tool calls and diffs are hidden
- **AND** the role label stays colour-coded while its message timestamp uses a subdued secondary-label style

### Requirement: Render Markdown with the built-in parser

The app SHALL render the model's Markdown without an external dependency.

#### Scenario: A formatted answer
- **WHEN** an answer contains markup
- **THEN** the app renders headers, lists, `code`, fenced blocks, quotes and tables drawn with box-drawing characters

#### Scenario: A table is wider than the conversation pane
- **WHEN** a rendered Markdown table does not fit the transcript width
- **THEN** that table scrolls horizontally without wrapping or breaking its grid
- **AND** prose around the table continues to wrap to the conversation pane

### Requirement: Never let model-supplied links launch local targets

Reports and transcripts are model output, and a clicked link goes straight to
the system opener. The app SHALL make only web links from Markdown clickable
and SHALL render every other model-supplied target as ordinary text. Trusted
session links may be added by EpiScope only after validating them against the
saved report scope and local index.

#### Scenario: A link to a local file
- **WHEN** a report or a message contains `[label](file:///…/x.command)`, a custom app scheme or a relative path
- **THEN** the label renders as ordinary text and clicking it does nothing
- **AND** only `http`, `https` and `mailto` targets stay clickable

#### Scenario: Insights cites a session
- **GIVEN** an Insights report contains a full session id or an unambiguous short form
- **AND** that session belongs to the report's saved scope and still exists in the index
- **WHEN** the report is rendered
- **THEN** EpiScope turns that reference into a trusted internal link
- **AND** clicking it uses the same opening path as double-clicking the session in the table
- **AND** a detached session opens in details and Back returns to Insights
- **AND** the model still cannot create a clickable custom-scheme or local-file link

### Requirement: Keep a large transcript from blocking the window

The app SHALL load a transcript off the main thread and SHALL cap how much of it
is shown. The cap SHALL apply to the conversation alone: the chart and the strip
above it measure the whole session, whatever its size.

#### Scenario: A transcript of tens of megabytes
- **WHEN** such a session opens
- **THEN** the load runs off the main thread and the early history is dropped
- **AND** a line at the top says that earlier history was omitted
- **AND** the curves, the markers and the lifecycle strip still span the session from its first record to its last, on one axis

#### Scenario: Cumulative usage of a capped session
- **WHEN** the curves are drawn for a session whose conversation was truncated
- **THEN** they accumulate from the session's own beginning, not from where the shown history starts
- **AND** they count each API call once, so they agree with the table's token columns

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
- **AND** it waits for the daily run to finish rather than being skipped for the week

#### Scenario: A scheduled run cannot start yet
- **GIVEN** another analysis is in flight, or the window holds too little to report on
- **WHEN** the scheduler reaches its check
- **THEN** the day or week is not marked done, and the next check tries again

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

#### Scenario: A provider with no interval fold implemented
- **GIVEN** a Codex or Claude Desktop session was active inside the report's window
- **WHEN** the report is built
- **THEN** the session is listed with its lifetime totals, marked `lifetime totals` rather than `active`
- **AND** it is left out of the interval project totals, so those stay interval-only
- **AND** a note names how many sessions this applies to, so the two are never added together
- **AND** the fleet is never silently reduced to one provider

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

### Requirement: Show that an analysis is in flight

The app SHALL show that a run is happening for as long as it lasts, wherever
the operator is in the window.

#### Scenario: A run starts
- **WHEN** an analysis starts, from the schedule or from `Analyze Session…`
- **THEN** the ✦ toolbar button pulses, from packet preparation until the run ends
- **AND** the runs list carries an "analyzing…" row with elapsed time

#### Scenario: The run ends
- **WHEN** the run finishes, is cancelled or fails
- **THEN** the pulse stops and the button returns to its normal look

#### Scenario: The window was closed while a run was going
- **GIVEN** an analysis started while the main window was closed
- **WHEN** the operator opens the window
- **THEN** the ✦ is already pulsing

### Requirement: Manage a run from the runs list

The app SHALL keep Insights mode free of run controls.

#### Scenario: Compare run metadata
- **WHEN** the operator scans the Cost and Date columns in the runs list
- **THEN** their digits use tabular fixed-width figures
- **AND** values align without changing the surrounding system typeface

#### Scenario: Right click on a run
- **WHEN** the operator right-clicks a row in the runs list
- **THEN** Copy Report, Reveal in Finder and Delete are offered
- **AND** the mode holds no other run controls

### Requirement: Keep the analysis on the machine

The app SHALL run the analysis locally.

#### Scenario: A run starts
- **WHEN** a run starts
- **THEN** it runs a local headless CLI — `claude -p` or `codex exec`, whichever
  the chosen model belongs to — and sends the data nowhere else
- **AND** that CLI is confined to reading: no shell, no writes, no network tools
  and none of the operator's own MCP servers

#### Scenario: The chosen engine's CLI is missing
- **GIVEN** the chosen model belongs to an engine whose CLI is not installed
- **WHEN** a run starts
- **THEN** the run fails with a message naming that CLI, not the other one
- **AND** this is the one failure that opens a dialog, because it offers to
  locate the binary

#### Scenario: A run fails
- **WHEN** a run fails for any other reason, including before it started
- **THEN** it appears in the runs list as a failed report carrying the reason
- **AND** no alert interrupts the operator — the runs are scheduled, so a modal
  would land over unrelated work
- **AND** when the CLI reported the reason in its own output, that is what the
  report shows rather than an exit code

### Requirement: Expose exactly two controls

The app SHALL limit the Insights settings to a switch and a model choice.

#### Scenario: The settings for Insights
- **WHEN** the operator opens `Settings → Insights`
- **THEN** only automatic runs (on/off) and the analysis model are offered
- **AND** `Analysis Model` groups its choices by the CLI that runs them: Claude
  Code (Sonnet 4.6 by default, Sonnet 5, Opus 5, Opus 4.8, Haiku 4.5) and Codex
- **AND** the Codex choice names no model of its own — it runs whatever
  `~/.codex/config.toml` selects, because which models a CLI accepts depends on
  its version and the account's plan

### Requirement: Let the prompts be edited and put back

The analysis prompts already ship as files an override can replace. The app
SHALL make that override editable under `Settings → Insights` — the run, its
model and its prompt are one subject — and SHALL keep the way back.

#### Scenario: Editing a prompt
- **GIVEN** `Settings → Insights` is open on one of the prompt templates
- **WHEN** the operator edits it
- **THEN** the edit is saved as the user copy that runs from then on, and the
  pane says the bundled default is no longer followed
- **AND** the placeholders the run fills in are listed, read from the bundled copy

#### Scenario: Restoring a default
- **WHEN** the operator restores the default and confirms
- **THEN** the user copy moves to the Trash and the bundled prompt runs again,
  including whatever later releases change in it

#### Scenario: A prompt that was never edited
- **WHEN** the pane opens on a template with no user copy
- **THEN** it shows the bundled text and offers nothing to restore

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

#### Scenario: A Claude Desktop Code tab
- **GIVEN** the session ran in the Claude app's Code tab
- **THEN** `Copy Resume Command` and `Delete Session…` are offered, because it is
  ordinary Claude Code and its transcript is the CLI's own
- **AND** a local-agent-mode session is offered neither: the CLI cannot address a
  session it never wrote

### Requirement: Reach the original transcript

The app SHALL reveal the session's own file without copying or changing it.

#### Scenario: Reveal Transcript in Finder
- **WHEN** the operator runs `Reveal Transcript in Finder`
- **THEN** Finder opens the session's `.jsonl`

### Requirement: End a running session from the table

The app SHALL let the operator stop a running session, performing the shutdown
`/exit` performs inside it, and SHALL signal only the provider's own process.

#### Scenario: Stop an idle session
- **GIVEN** the session is running and neither working nor waiting on the operator
- **WHEN** the operator runs `Stop Session`
- **THEN** its process is asked to terminate, with no confirmation
- **AND** the row leaves the live set on the next monitor tick

#### Scenario: Stop a session mid-turn
- **GIVEN** the session is working or holding a permission prompt
- **WHEN** the operator runs `Stop Session`
- **THEN** a confirmation names what ends with it
- **AND** nothing is signalled unless it is confirmed

#### Scenario: The pid does not belong to the session
- **GIVEN** the published pid is stale, forged or reused by another program
- **WHEN** the operator runs `Stop Session`
- **THEN** nothing is signalled

#### Scenario: Sessions that cannot be stopped
- **GIVEN** the session is finished, or runs as a Claude Desktop Code tab
- **THEN** `Stop Session` is listed with the other session actions but disabled
- **AND** it is not listed at all where no session action applies — an external
  source's session, or the local-agent-mode store

### Requirement: Make deletion reversible and confirmed

The app SHALL delete a session only after a confirmation and only to the Trash.

#### Scenario: Delete Session
- **WHEN** the operator runs `Delete Session…` and confirms
- **THEN** the transcript moves to the Trash
- **AND** the details of that session close if they are open

#### Scenario: Deleting a running session
- **GIVEN** the session is still running and the app may signal its process
- **WHEN** the operator confirms the delete
- **THEN** the session is stopped first, and the sheet said so
- **AND** the transcript moves to the Trash only once the process has exited, so
  its shutdown records go with it
- **AND** a session that has not exited within the wait is left alone —
  transcript in place — and says so

#### Scenario: Deleting a running Claude Desktop Code tab
- **GIVEN** the session runs in the Claude app, which the app does not stop
- **WHEN** the confirmation sheet appears
- **THEN** it says so, and says the delete removes only what has been written so far

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

### Requirement: Index additional session sources

The app SHALL keep the built-in Claude Code, Codex and Claude Desktop roots
working without configuration and SHALL let the operator add read-only session
directories from `Settings → Sources`.

#### Scenario: Add a mounted agent home
- **GIVEN** a directory contains a recognised Claude Code, Codex or Claude Desktop layout
- **WHEN** the operator adds it as a session source
- **THEN** EpiScope synchronises recognised transcript files into its own local snapshot
- **AND** never mounts, writes to or deletes from the selected directory
- **AND** sessions keep their original globally unique `sessionId`

#### Scenario: The layout sits below the selected directory
- **GIVEN** the selected directory is a mounted home, a backup, or holds several agent homes side by side
- **WHEN** the source synchronises
- **THEN** every recognised root below it is found, whatever its depth
- **AND** their transcripts merge into one snapshot per provider
- **AND** the sessions appear in the main table like any other source

#### Scenario: An external source becomes unavailable
- **GIVEN** the source has completed at least one successful synchronisation
- **WHEN** its directory disappears, blocks or returns an error
- **THEN** its last successful snapshot and indexed sessions remain available
- **AND** the source is labelled Offline with its last successful sync time
- **AND** full search, transcript viewing and Insights read the local snapshot
- **AND** the failed sync never publishes an empty generation

#### Scenario: A cached source is offline
- **GIVEN** an indexed session belongs to an unavailable external source
- **THEN** its App column uses the square cached-source icon
- **AND** Open Application, Resume and Delete are unavailable
- **AND** Reveal Transcript targets the local snapshot

#### Scenario: The main session list covers every source
- **WHEN** the Sessions window opens
- **THEN** the table shows sessions from every enabled source together, with no
  per-source picker in the toolbar
- **AND** which sources count at all is decided in `Settings → Sources`,
  the one place that governs them

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
