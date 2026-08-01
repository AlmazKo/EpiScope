# Agterm integration

[Agterm](https://github.com/umputun/agterm) (`com.umputun.agterm`) is a terminal
built on libghostty. It is driven through its own Unix socket (`agtermctl`) and
ships no AppleScript dictionary. EpiScope supports it with a **full adapter**:
the terminal icon in the table, window and session binding, the focus dance
(`Finished` clears once the session is opened), and jumping into it with a
double click or a click on the banner.

Code: `TerminalTracker.swift` (MARK: `Agterm adapter`), focus in `cc-open` (the
`agterm)` case), icon in `MainWindowController.terminalIcon(for:)`.

---

## How a session is bound to a window

Windows of other Ghostty-based terminals expose no tty, so the Ghostty adapter
has to guess the binding from the working directory or the tab title. Agterm
removes the guessing: it exports the UUIDs of its window and session into the
**process environment**.

| Environment variable | Value |
|---|---|
| `AGTERM_SESSION_ID` | UUID of the Agterm session |
| `AGTERM_WINDOW_ID` | UUID of the Agterm window |
| `AGTERM_WORKSPACE_ID` | UUID of the workspace |
| `AGTERM_SOCKET` | path to the control socket |

`resolveAgtermEnv(_:)` reads the environment of every claude pid once
(`ps eww -o pid=,command=`) and pulls out `AGTERM_SESSION_ID` and
`AGTERM_WINDOW_ID`. The values are UUIDs, so they are extracted by a targeted
scan for the key; that survives `AGTERM_SOCKET`, whose value can contain spaces.
A process environment never changes, so `ps eww` runs at most once per pid, and
in the steady state it never runs at all. Everything sits behind an "Agterm is
running" flag, so machines without Agterm pay nothing for it.

The result is published in `cc-states.json` as `term = "agterm"` and
`ref = "<window id>:<session id>"`. Those two ids are all `cc-open` needs to
raise the window and select the session inside it.

## The active session and frontmost (focus dance)

A session counts as focused — which clears `Finished` and withdraws the banner —
when both conditions hold:

1. **Agterm is the frontmost application.** `NSRunningApplication.isActive` and
   `NSWorkspace.frontmostApplication` are cached on the main thread of the
   observing app, and the tracker's background queue reads them **stale**: they
   returned `false` while Agterm really was in front. So the frontmost app is
   taken from `CGWindowListCopyWindowInfo` instead. That is the window server's
   live z-order, it is thread-safe, and the window owner
   (`kCGWindowOwnerPID`) is returned without the screen-recording permission,
   which is only needed for window titles. We compare the owner pid of the
   topmost layer-0 window with Agterm's pid.
2. **It is the active session of its workspace**, taken from
   `agtermctl tree --json` (`active: true` on the session and on its workspace).

Both queries run on the tracker's slow cadence (`scriptEvery`, ~2 s).

## Jumping into a session (`cc-open`)

`agtermctl` ships inside the app bundle. `cc-open` takes it from `PATH` (the
Homebrew symlink) or from `/Applications/agterm.app/Contents/MacOS/agtermctl`.
It splits the window id and the session id out of `ref` and then runs:

```sh
agtermctl window select "$AWID"
agtermctl session select --target "$ASID" --window "$AWID"
open -b com.umputun.agterm
```

`session select --target … --window …` switches **both the session and its
workspace**, because a session belongs to a workspace. A click therefore lands
on exactly the right tab in the right workspace. If `agtermctl` is unavailable,
the fallback is `open -a agterm`.

## Fallback without agtermctl

The `termsByAncestorExe` map holds `"agterm" → "agterm"`. If the control socket
is unavailable, the session is still recognised by its process ancestor (the
binary's basename is `agterm`) and still gets a terminal icon — only without
window binding and focus detection.

## agtermctl commands EpiScope uses

| Command | Purpose |
|---|---|
| `agtermctl tree --json` | list workspaces and sessions, find the active one |
| `agtermctl window select <wid>` | raise a window |
| `agtermctl session select --target <sid> --window <wid>` | select a session (and its workspace) |

For the full control API see `agtermctl help` and the `CLAUDE.md` of the Agterm
repository.
