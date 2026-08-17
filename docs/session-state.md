# Session state: what each status means and how it is caught

Companion to `docs/file-io.md` (which file is read by whom) and
`docs/business-cases.md` (what the user is promised). This one answers a
narrower question: **the table says `Waiting` — where did that come from, and
what could make it lie?**

Nothing here is authoritative on its own. Every status is a verdict over five
sources that disagree in predictable ways, and most of the code below exists
because one of them went stale.

## 1. The sources

| # | Source | Who reads it | Cadence | What it is worth |
|---|---|---|---|---|
| S1 | `~/.claude/sessions/<pid>.json` → `status` / `waitingFor` / `statusUpdatedAt` | `SessionStore` → `SessionMonitor`, `TerminalTracker` | 1 s, mtime-gated | **Authoritative** — Claude Code's own `busy` / `waiting` / `idle`. Absent for `-p` / SDK-CLI and Claude Desktop sessions |
| S2 | `~/.claude/state/sig-<sid>` | `TerminalTracker.computeState` | on change | A hook fired. Instant, but only ever cleared by the *next* hook |
| S3 | `~/.claude/state/attended-<sid>` | `TerminalTracker.computeState` | on change | We already showed this finished turn to the operator |
| S4 | The transcript tail | `TerminalTracker` (turn outcome), `SessionMonitor` (SDK-CLI) | mtime-gated | The only witness for API failures and for SDK sessions |
| S5 | The process tree (`ps`) | `TerminalTracker.youngestChildAges` | 1 s, and only when an S1-less session is alive | Whether a tool is executing right now |

`kill(0)` on the pid gates everything: a state file left behind by a crash never
surfaces as a live session.

The verdict is computed in `TerminalTracker.computeState`, published to
`~/.claude/state/cc-states.json`, and read back by everyone else. The table's
badge, the menu-bar alarm, the notifications and the Perm Wait clock are all
downstream of that one function — deliberately, so there is one place to fix.

## 2. The state machine

`computeState(sid:status:statusUpdatedAt:turnErrored:located:focused:toolRunning:)`,
in order. `status` is S1, `sig` is S2.

**Staleness repairs first** — each one exists because a signal outlived its
truth:

1. `status == busy` and `sig == needs_permission` → **delete the signal**. The
   prompt was answered; the authoritative status already moved on.
2. `status.isEmpty` and `sig == needs_permission` and a tool is running (S5) →
   read the signal as `thinking`, but leave the file alone. Same staleness with
   no S1 to catch it: Claude Code has no "permission granted" event, so
   `needs_permission` stands until `PostToolUse` — which fires when the tool
   *finishes*. A `sleep 570` read as a permission request for nine minutes.
3. `status == idle` and `sig == thinking`, and the status is at least as new as
   the signal → **delete the signal**. A failed stream can end a turn without
   firing `Stop`, leaving `thinking` forever.

**Then the verdict:**

4. Turn errored (S4) and status is neither `waiting` nor `busy` → `error`, or
   `error_attended` if S3 exists.
5. **No terminal located** → `needs_permission` / `thinking` / `done` / `idle`,
   in that order. `done` is only ever taken from the hook here, never derived
   from an idle status: with no window to focus there would be nothing to clear
   it, and it would stick. This is the JetBrains and Claude Desktop case.
6. Located: `waiting`/`needs_permission` wins, then the hook's
   `thinking`/`done`, then `busy` → `thinking`, then idle-with-no-`attended` →
   `done`, else `idle`.
7. The session's window is focused → the operator has seen it: `done` is
   acknowledged (signal deleted, `attended` written) and the state drops to
   `idle`. A permission request and an error are *not* acknowledged by looking
   at them.

Two other providers bypass most of this:

- **Codex** has no hooks and no status file. An unresolved `function_call` in
  the rollout tail is `needs_permission`; a terminal `error` event is `error`;
  everything else is `idle`. A `stream_error` is retry noise, not an outcome.
- **Claude Desktop** runs `computeState` with `located: true, focused: false` —
  we cannot see its window focus, so rule 7 never fires and `Finished` is
  cleared by opening the session through EpiScope instead.

## 3. What the table shows

`MainWindowController.sessionCell`, Status column, in order:

| Badge | Condition |
|---|---|
| `Parked` | the row was parked with ⌃B and its continuation is on screen (`ParkedSessions`). Checked first, ahead of `Error`: the row is a stub, and what happened to a stub is less useful than the fact that it is one |
| `Error` | tracker state `error` / `error_attended`. Neutral either way — the amber alarm carries the attention, the badge only carries the fact |
| `Waiting` | live session with S1 `waiting`, or tracker state `needs_permission` |
| `mm:ss` | busy, counting from `statusUpdatedAt` (exact) or first sight. The pearlescent fill is the animation; the text is refreshed in place once a second by `tickBusyColumn` — which must skip anything the cell logic special-cases, or it paints over it |
| `Finished` | tracker state `done` |
| `Idle` | alive, nothing else applies |
| `Active` | Claude Desktop with a record written in the last 6 minutes — it has no hooks, so recency is all there is |
| `—` | not running |

## 4. The attention path

Separate from the badge, and stricter:

- `SessionMonitor.waiting` — S1 `waiting`, or tracker `needs_permission`, or the
  SDK-CLI guess below. Drives the menu-bar alarm count, the Perm Wait clock and
  its persisted segments.
- `TerminalTracker.notifyTransitions` — banners for `done` / `error` /
  `needs_permission`. A state must hold **two consecutive ticks** before it
  fires or is withdrawn (Ghostty intermittently drops its surface list, which
  used to flap the state and spam banners), and nothing fires until the session
  has settled on some earlier state, so a launch is quiet.
- `needsAttention` in the table — `waiting`, `needs_permission`, `done` or
  `error`. Only used to decide whether an unlocatable live session gets the
  orange detached glyph.

**The `/btw` exception**: a user-opened overlay publishes
`waiting / dialog open` while the turn keeps running. `isEphemeralDialogOpen`
keeps it out of the attention path entirely.

## 5. Sessions with no status file

`-p` and SDK-CLI sessions (`entrypoint == "sdk-cli"`) never write S1, so the
monitor reconstructs it: if the transcript's last record is an `assistant` with
a `tool_use` block, the agent is parked waiting for the parent to approve. The
permission mode is taken from the most recent record that carries one —
`bypassPermissions` / `auto` / `plan` never prompt, and `acceptEdits`
auto-approves edits but not Bash.

That guess cannot tell a pending approval from an approved tool still running —
the trailing record is identical. So the tracker publishes `tool_running` in
`cc-states.json` (optional v1 field) and the monitor skips the guess while it is
set. The expensive half — one `ps` per tick, only while such a session is alive
— stays off the main thread.

## 6. Known blind spots

- **There is no "permission granted" hook.** CLI 2.1.223 has 14 events and none
  of them is that; `PreToolUse` fires *before* the prompt, not after it. Both
  repairs above are workarounds for its absence — if it ever ships, they are the
  first thing to delete.
- **`tab-state.sh` may not be ours.** The installer only overwrites a script
  whose `episcope-hook` marker is intact, so a user copy keeps running. It then
  misses whatever the bundled version has gained — currently the session-id
  sanitisation, and the id becomes a filename.
- **A stale signal for a dead pid** is cleaned by `cleanupSignals` on the tick
  that stops seeing the session, not before.
- **Installation is silent.** `ClaudeHooks.install()` returns a user-facing
  error string and `AppDelegate` discards it; with a broken `settings.json` the
  whole hook path is simply absent and nothing says so. `isInstalled()` exists
  for an indicator that was never built.
