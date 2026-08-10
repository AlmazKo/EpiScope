import AppKit
import UserNotifications

// Terminal-agnostic Claude Code session tracker. EpiScope is the single
// publisher of ~/.claude/state/cc-states.json; the kitty painter,
// cc-open and SessionMonitor are consumers of that contract and don't
// care who writes it. (A reference Python implementation, state-core.py,
// lives in the companion dotfiles repo as a manual fallback.)
//
// Every tick (1 s, on a background queue — TerminalTracker.interval):
//   1. ~/.claude/sessions/*.json is the authority on which CC sessions
//      exist; one `ps` call confirms liveness, grabs the tty and guards
//      against pid reuse.
//   2. Terminal adapters answer "where is pid X and is it focused?":
//      kitty via `kitten @ ls`, iTerm2 via AppleScript + tty join
//      (osascript costs ~250 ms, polled every other tick). Sessions in
//      no known terminal are published with term = null.
//   3. State per session: hook signal (~/.claude/state/sig-<session_id>)
//      complements CC status (busy → thinking, idle → done); transcript
//      terminal events add `error` / `error_attended` states. Opening a done or
//      failed turn through EpiScope acknowledges it, while permission requests
//      stay active until CC leaves `waiting`.
//   4. Snapshot goes to cc-states.json (v1 envelope, atomic rename,
//      mtime is the heartbeat).
//
// It also owns user notifications: a banner on the done / error /
// needs_permission transitions. Finished and Error are removed once attended;
// a permission banner remains until Claude or Codex leaves `waiting`.
// Clicking a banner focuses the hosting terminal/app via cc-open — the
// exact same path as a double-click in the sessions table.
final class TerminalTracker: NSObject {
    static let shared = TerminalTracker()

    // Set by AppDelegate: handle a notification tap (by sessionId). When unset,
    // taps fall back to opening the session's terminal directly.
    var onNotificationClick: ((String) -> Void)?
    // Tap on a "Daily insights ready" banner (posted by the reports
    // window) — routed here because this class is the UNUserNotification
    // delegate for the whole app.
    var onReportNotificationClick: (() -> Void)?

    static let interval: TimeInterval = 1.0
    static let jobId = "terminal-tracker"
    private static let scriptEvery = 2  // AppleScript / kitty enumerations every 2 s

    private let queue = DispatchQueue(label: "episcope.terminal-tracker", qos: .utility)
    // Codex discovery walks every process (`ps -axo`), which is the most
    // expensive thing in a tick. Codex appearing/leaving is fine to notice
    // a couple of seconds late, so refresh it on this slower cadence and
    // serve the cache in between.
    private static let codexEvery = 4   // every 4 ticks ≈ 2 s
    private var codexCache: ([SessionInfo], [Int: String]) = ([], [:])
    private var tick = 0
    private var kittyCache: [Int: Located] = [:]           // pid -> location
    private var itermCache: [String: Located] = [:]        // tty -> location
    private var terminalAppCache: [String: Located] = [:]  // tty -> location
    private struct GhosttySnapshot {
        var surfaces: [(ref: String, wd: String, title: String)] = []
        var focusedId: String?  // only set while Ghostty is frontmost
    }
    private var ghosttyCache = GhosttySnapshot()
    // Agterm (com.umputun.agterm) is a Ghostty-based terminal driven by its
    // agtermctl control socket, not AppleScript. Each session exports its
    // window/session UUIDs into the process env, so a Claude pid binds to an
    // exact agterm window+session; the snapshot only carries which sessions are
    // active (for the focus dance) and whether agterm is frontmost.
    private struct AgtermSnapshot {
        var activeSessionIds: Set<String> = []
        var frontmost = false
    }
    private var agtermCache = AgtermSnapshot()
    // pid → (window id, session id), read once from the process env
    // (AGTERM_WINDOW_ID / AGTERM_SESSION_ID are fixed for the process's life).
    // agtermChecked holds every pid already env-read (agterm or not).
    private var agtermInfo: [Int: (window: String, session: String)] = [:]
    private var agtermChecked: Set<Int> = []
    private var lastStates: [String: String] = [:]     // sessionId -> previous tick's state
    private var settledStates: [String: String] = [:]  // sessionId -> last state acted on
    // sessionId -> ai-title (what Claude shows as the tab title). Pushed from
    // the index by AppDelegate; read on `queue` in assignGhostty. Lets us bind
    // an unnamed session to its Ghostty tab by title.
    private var sessionTitles: [String: String] = [:]
    // sessionId -> AI-generated session description. This deliberately excludes
    // the user's custom name. It becomes the short first line of notification
    // bodies and is pushed from the already-parsed index, so notification
    // delivery never needs to read a transcript.
    private var sessionDescriptions: [String: String] = [:]
    // SessionMonitor is the single rollout-tail reader for Codex approval
    // state. AppDelegate pushes its current waiting ids onto this queue so the
    // notification state machine can treat them as needs_permission without a
    // second filesystem scan.
    private var codexWaitingSessionIds: Set<String> = []
    // CC liveness/tty without a `ps` every tick: each pid is ps'd once (to
    // resolve its tty and confirm it's really a claude process), then liveness
    // is a cheap kill(0). ccChecked holds every pid already ps'd (claude or
    // not); ccTty maps confirmed-claude pids to their tty ("" = no tty).
    private var ccTty: [Int: String] = [:]
    private var ccChecked: Set<Int> = []
    // Codex pid → (rollout sessionId, cwd, rollout path). A process holds these for
    // its lifetime, so lsof runs once per pid, not every tick.
    private var codexInfoCache: [Int: (sessionId: String, cwd: String, rolloutPath: String)] = [:]

    // Transcript tails are only decoded after the file changes. The state
    // tracker ticks every second, so this keeps a settled session to one stat
    // instead of repeatedly reading its jsonl.
    private struct TurnOutcomeCacheEntry {
        let mtime: Date
        let size: UInt64
        let errored: Bool
    }
    private var turnOutcomeCache: [String: TurnOutcomeCacheEntry] = [:]

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private var stateDir: String { home + "/.claude/state" }
    private let kittenPath = "/Applications/kitty.app/Contents/MacOS/kitten"

    private struct Located {
        let term: String
        let ref: String
        let focused: Bool
        // kitty only: the @-control socket of the instance that owns the
        // window. Window ids are per-instance, so a ref is meaningless
        // to consumers without the socket that minted it.
        var sock: String? = nil
    }

    private struct AncestryHost {
        let term: String
        let ref: String?
        let bundleId: String?
    }

    // Terminals recognisable by walking up the process tree (executable
    // basename of an ancestor). Used for sessions the kitty / iTerm2
    // adapters didn't locate — gives the snapshot a `term` (so the UI can
    // show the right icon) but no ref / focus, so the attended dance
    // doesn't apply. Also the fallback identification for kitty/iTerm2
    // themselves when the socket / AppleScript path is unavailable.
    private static let termsByAncestorExe: [String: String] = [
        "kitty": "kitty",
        "iTerm2": "iterm2",
        "Terminal": "terminal",
        "ghostty": "ghostty",
        "Ghostty": "ghostty",
        // Agterm bundles libghostty; its own binary basename is "agterm".
        // The env/tree adapter locates it precisely — this is the fallback
        // that still gives the row an icon if agtermctl is unavailable.
        "agterm": "agterm",
        "xterm": "xterm",
        // JetBrains IDEs' embedded terminal — the launcher binaries.
        // This fast list covers the common ones; any other JetBrains
        // product is caught by the bundle-id check in ancestryLookup.
        // All map to one "jetbrains" kind (ancestry-only, like xterm).
        "idea": "jetbrains",
        "pycharm": "jetbrains",
        "webstorm": "jetbrains",
        "goland": "jetbrains",
        "clion": "jetbrains",
        "phpstorm": "jetbrains",
        "rubymine": "jetbrains",
        "rider": "jetbrains",
        "datagrip": "jetbrains",
        "rustrover": "jetbrains",
        "dataspell": "jetbrains",
        "aqua": "jetbrains",
    ]

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        try? FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true)

        // The tick keeps running on this subsystem's own serial queue — it is
        // what serializes a tick against updateSessionMetadata / acknowledge —
        // but the cadence now comes from the shared scheduler.
        WorkScheduler.shared.register(.init(
            id: Self.jobId, interval: Self.interval, target: .queue(queue),
            initialDelay: Self.interval
        ) { [weak self] in self?.tickOnce() })
    }

    // MARK: - Tick

    private func tickOnce() {
        var (sessions, ttys) = ccSessions()
        // Codex sessions too, so their terminal is published (icon +
        // cc-open focus). Located by the same adapters via pid/tty/cwd.
        // The `ps -axo` walk only runs every codexEvery ticks; other ticks
        // reuse the cache (refreshed pids stay valid for their lifetime).
        if tick % Self.codexEvery == 0 {
            codexCache = codexSessions()
        }
        let (codex, codexTtys) = codexCache
        sessions += codex
        ttys.merge(codexTtys) { a, _ in a }
        // Window location (kitty ref/sock, iTerm/Terminal tty, Ghostty
        // surface) is stable between moves, and session state comes from the
        // hook sig files, not these queries — so refresh all the terminal
        // adapters on the slow cadence and reuse the caches in between. This
        // keeps the per-tick subprocess spawns (kitten @ ls, osascript) down.
        if tick % Self.scriptEvery == 0 {
            kittyCache = kittyLocate()
            itermCache = itermLocate()
            terminalAppCache = terminalAppLocate()
            // Ghostty's AppleScript intermittently returns no surfaces while
            // it's still running. Don't clobber the cache with that empty
            // result: a session's surface (and thus its located → done state)
            // would flap every couple of seconds, spamming notifications. Keep
            // the last good snapshot; only accept an empty one once Ghostty
            // itself is gone.
            let ghostty = ghosttyLocate()
            if !ghostty.surfaces.isEmpty || !appRunning("com.mitchellh.ghostty") {
                ghosttyCache = ghostty
            }
            agtermCache = agtermLocate()
        }
        let kitty = kittyCache
        tick += 1

        // Env binding is immutable per pid, so resolve new pids every tick (not
        // just the slow cadence) — a fresh agterm session gets its icon/focus
        // without a scriptEvery delay. No-op when there are no unseen pids.
        resolveAgtermEnv(Set(sessions.map(\.pid)))

        var states: [String: Entry] = [:]
        var bySid: [String: Entry] = [:]
        // pid → host found in the process ancestry. For application hosts the
        // bundle id lets both cc-open and the table use the exact installed app.
        // Resolved eagerly when
        // any session isn't precisely placed (i.e. is a ghostty candidate) —
        // it both vetoes wrong ghostty matches below and serves as the loop's
        // fallback — and skipped entirely (no ps) when everything is located.
        let ghosttyEligible = sessions.filter { ghosttyCandidate($0, kitty: kitty, ttys: ttys) }
        let ancestry: [Int: AncestryHost] =
            ghosttyEligible.isEmpty ? [:] : ancestryLookup(pids: sessions.map(\.pid))
        // Ghostty surfaces expose no tty, so they're matched by title / cwd —
        // which a session running under another terminal in the same directory
        // (e.g. a JetBrains IDE) can also satisfy, stealing the surface. Ancestry
        // is authoritative: drop any candidate whose process tree runs under a
        // non-ghostty host (nil / ghostty ancestry stays eligible).
        let ghosttyByPid = assignGhostty(ghosttyEligible.filter {
            (ancestry[$0.pid]?.term ?? "ghostty") == "ghostty"
        })
        for s in sessions {
            // Claude desktop ("Code" tab) runs in the Claude app, not a
            // terminal. It has a pid + cwd, so the tty / working-dir matchers
            // would wrongly bind it to an unrelated terminal (e.g. a ghostty
            // window in the same project). Publish it as the "claude-desktop"
            // kind with the app bundle id so cc-open / notification taps open
            // the app. State still comes from the hooks (computeState), with no
            // focus dance (we can't detect a Claude.app window's focus).
            if s.entrypoint == "claude-desktop" {
                let turnErrored = claudeTurnErrored(sessionId: s.sessionId, cwd: s.cwd)
                let state = computeState(
                    sid: s.sessionId,
                    status: s.attentionStatus ?? "",
                    statusUpdatedAt: s.statusUpdatedAt,
                    turnErrored: turnErrored,
                    located: true,
                    focused: false)
                let entry = Entry(
                    state: state, session_id: s.sessionId,
                    term: "claude-desktop", ref: "com.anthropic.claudefordesktop",
                    bundle_id: "com.anthropic.claudefordesktop",
                    sock: nil, tty: ttys[s.pid], cwd: s.cwd, focused: false, wid: nil)
                states[String(s.pid)] = entry
                bySid[s.sessionId] = entry
                continue
            }
            var loc: Located?
            let tty = ttys[s.pid]
            if let k = kitty[s.pid] {
                loc = k
            } else if let ag = agtermInfo[s.pid] {
                // ref = "<window id>:<session id>" — cc-open needs both to raise
                // the window and select the session within it.
                loc = Located(term: "agterm", ref: "\(ag.window):\(ag.session)",
                              focused: agtermCache.frontmost
                                  && agtermCache.activeSessionIds.contains(ag.session))
            } else if let tty, let i = itermCache[tty] {
                loc = i
            } else if let tty, let t = terminalAppCache[tty] {
                loc = t
            } else if let ref = ghosttyByPid[s.pid] {
                loc = Located(term: "ghostty", ref: ref,
                              focused: ghosttyCache.focusedId == ref)
            }
            var term = loc?.term
            var ancestryRef: String?
            if term == nil {
                term = ancestry[s.pid]?.term
                ancestryRef = ancestry[s.pid]?.ref
            }
            // Codex has no hook signals / "done" semantics here. Its rollout
            // tail exposes both unresolved approvals and terminal turn errors.
            let state: String
            if s.entrypoint == "codex" {
                if codexWaitingSessionIds.contains(s.sessionId) {
                    state = "needs_permission"
                } else if let info = codexInfoCache[s.pid], codexTurnErrored(at: info.rolloutPath) {
                    state = errorState(sid: s.sessionId)
                } else {
                    // Codex has no busy status that would clear this marker for
                    // us. A later non-error rollout outcome starts a fresh
                    // acknowledgment cycle for the next failed turn.
                    try? FileManager.default.removeItem(
                        atPath: stateDir + "/attended-" + s.sessionId)
                    state = "idle"
                }
            } else {
                state = computeState(
                    sid: s.sessionId,
                    status: s.attentionStatus ?? "",
                    statusUpdatedAt: s.statusUpdatedAt,
                    turnErrored: claudeTurnErrored(sessionId: s.sessionId, cwd: s.cwd),
                    located: loc != nil,
                    focused: loc?.focused ?? false)
            }
            let entry = Entry(
                state: state,
                session_id: s.sessionId,
                term: term,
                ref: loc?.ref ?? ancestryRef,
                bundle_id: ancestry[s.pid]?.bundleId,
                sock: loc?.sock,
                tty: tty,
                cwd: s.cwd,
                focused: loc?.focused ?? false,
                wid: loc?.term == "kitty" ? Int(loc?.ref ?? "") : nil)
            states[String(s.pid)] = entry
            bySid[s.sessionId] = entry
        }

        publish(states)
        notifyTransitions(bySid)
        cleanupSignals(liveSids: Set(sessions.map(\.sessionId)))
    }

    // MARK: - CC sessions (source of truth)

    private func ccSessions() -> ([SessionInfo], [Int: String]) {
        // Decoded session files come from the shared store (mtime-gated, so a
        // tick where nothing changed costs no JSON decode).
        var candidates: [Int: SessionInfo] = [:]
        for info in SessionStore.shared.sessions() { candidates[info.pid] = info }
        let present = Set(candidates.keys)
        ccTty = ccTty.filter { present.contains($0.key) }
        ccChecked = ccChecked.intersection(present)
        guard !candidates.isEmpty else { return ([], [:]) }

        // Resolve tty + confirm "is a claude process" once per pid via a single
        // ps for the pids we haven't seen yet. Steady state spawns no ps at all
        // — liveness below is kill(0).
        let unseen = present.subtracting(ccChecked)
        if !unseen.isEmpty {
            let pids = unseen.map(String.init).joined(separator: ",")
            let out = runShell(["/bin/ps", "-o", "pid=,tty=,command=", "-p", pids]) ?? ""
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2,
                                       omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let pid = Int(parts[0]),
                      parts[2].lowercased().contains("claude")
                else { continue }
                let tty = String(parts[1])
                ccTty[pid] = (tty != "??" && tty != "-") ? "/dev/" + tty : ""
            }
            ccChecked.formUnion(unseen)   // mark all (claude or not) as resolved
        }

        // Stable pid order (the old single `ps` listed pids ascending). The
        // ghostty matcher assigns "first unused surface with this cwd" walking
        // sessions in order, so a non-deterministic order (dict iteration) made
        // same-cwd sessions swap surfaces between ticks — and cc-open then
        // focused the wrong tab.
        var alive: [SessionInfo] = []
        var ttys: [Int: String] = [:]
        for pid in candidates.keys.sorted() {
            guard let info = candidates[pid], let tty = ccTty[pid], Self.isAlive(pid) else { continue }
            alive.append(info)
            if !tty.isEmpty { ttys[pid] = tty }
        }
        return (alive, ttys)
    }

    nonisolated private static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // Live Codex sessions as SessionInfo, for terminal location. The
    // codex process holds its rollout jsonl open, so lsof yields both
    // the session id (rollout uuid) and the cwd; tty comes from ps.
    private func codexSessions() -> ([SessionInfo], [Int: String]) {
        guard let out = runShell(["/bin/ps", "-axo", "pid=,tty=,comm="]) else { return ([], [:]) }
        var alive: [SessionInfo] = []
        var ttys: [Int: String] = [:]
        var seenPids = Set<Int>()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let comm = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard (comm.components(separatedBy: "/").last ?? comm) == "codex" else { continue }
            seenPids.insert(pid)

            let info: (sessionId: String, cwd: String, rolloutPath: String)
            if let cached = codexInfoCache[pid] {
                info = cached
            } else if let resolved = codexLsof(pid: pid) {
                info = resolved
                codexInfoCache[pid] = resolved
            } else {
                continue
            }
            let tty = String(parts[1])
            if tty != "??" && tty != "-" { ttys[pid] = "/dev/" + tty }
            alive.append(SessionInfo(
                pid: pid, sessionId: info.sessionId, cwd: info.cwd,
                status: nil, waitingFor: nil, updatedAt: nil, entrypoint: "codex"))
        }
        codexInfoCache = codexInfoCache.filter { seenPids.contains($0.key) }
        return (alive, ttys)
    }

    // lsof the codex pid → its open rollout jsonl (→ session uuid) + cwd.
    private func codexLsof(pid: Int) -> (sessionId: String, cwd: String, rolloutPath: String)? {
        guard let out = runShell(["/usr/sbin/lsof", "-p", String(pid), "-Fn"]) else { return nil }
        var sessionId: String?
        var rolloutPath: String?
        var cwd = ""
        var isCwd = false
        for line in out.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("f") { isCwd = (s == "fcwd"); continue }
            guard s.hasPrefix("n") else { continue }
            let path = String(s.dropFirst())
            if isCwd { cwd = path }
            if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl"),
               let name = path.components(separatedBy: "/").last {
                sessionId = String(name.dropLast(6).suffix(36))   // strip ".jsonl"
                rolloutPath = path
            }
        }
        guard let sid = sessionId, let rolloutPath else { return nil }
        return (sid, cwd, rolloutPath)
    }

    // MARK: - kitty adapter

    private struct KittyOSWindow: Decodable {
        let isFocused: Bool?
        let tabs: [Tab]
        struct Tab: Decodable {
            let isFocused: Bool?
            let windows: [Window]
            struct Window: Decodable {
                let id: Int
                let isFocused: Bool?
                let foregroundProcesses: [Proc]?
                struct Proc: Decodable { let pid: Int }
            }
        }
    }

    // kitty.conf's `listen_on unix:/tmp/<name>` makes kitty create
    // `/tmp/<name>-<pid>` — one socket per instance. The user can have
    // several instances alive at once (e.g. a stray `open -n kitty`),
    // and each one's window ids start from 1, so every socket has to be
    // queried and the owning socket remembered alongside the ref.
    private func kittySockets() -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: "/tmp")) ?? [])
            .filter { $0.hasPrefix("kitty") }
            .map { "/tmp/\($0)" }
            .filter {
                (try? fm.attributesOfItem(atPath: $0))?[.type] as? FileAttributeType == .typeSocket
            }
            .map { "unix:\($0)" }
    }

    private func kittyLocate() -> [Int: Located] {
        guard FileManager.default.isExecutableFile(atPath: kittenPath)
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var res: [Int: Located] = [:]
        for socket in kittySockets() {
            // Dead leftover sockets just fail the ls and contribute nothing.
            guard let out = runShell([kittenPath, "@", "--to", socket, "ls"]),
                  let data = out.data(using: .utf8),
                  let osWindows = try? decoder.decode([KittyOSWindow].self, from: data)
            else { continue }
            for osw in osWindows {
                for tab in osw.tabs {
                    for win in tab.windows {
                        let focused = (osw.isFocused ?? false)
                            && (tab.isFocused ?? false)
                            && (win.isFocused ?? false)
                        for p in win.foregroundProcesses ?? [] {
                            res[p.pid] = Located(term: "kitty", ref: String(win.id),
                                                 focused: focused, sock: socket)
                        }
                    }
                }
            }
        }
        return res
    }

    // MARK: - iTerm2 adapter

    // NB: inside `tell application "iTerm2"` the word `tab` resolves to
    // iTerm's tab CLASS, not the tab character — hence the "|" separator.
    private static let itermLs = """
    tell application "iTerm2"
    	set fm to frontmost
    	set curTTY to ""
    	try
    		set curTTY to tty of current session of current window
    	end try
    	set out to "FRONT|" & fm & "|" & curTTY & linefeed
    	repeat with w in windows
    		repeat with t in tabs of w
    			repeat with s in sessions of t
    				set out to out & (unique ID of s) & "|" & (tty of s) & linefeed
    			end repeat
    		end repeat
    	end repeat
    	return out
    end tell
    """

    // The running-app guards also keep the osascripts from auto-launching
    // the terminals they target.
    private func appRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private func itermLocate() -> [String: Located] {
        guard appRunning("com.googlecode.iterm2"),
              let out = runShell(["/usr/bin/osascript", "-e", Self.itermLs])
        else { return [:] }

        var ttyToRef: [String: String] = [:]
        var front = false
        var curTTY = ""
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 3 && parts[0] == "FRONT" {
                front = parts[1] == "true"
                curTTY = String(parts[2])
            } else if parts.count >= 2 && parts[1].hasPrefix("/dev/") {
                ttyToRef[String(parts[1])] = String(parts[0])
            }
        }
        var res: [String: Located] = [:]
        for (tty, ref) in ttyToRef {
            res[tty] = Located(term: "iterm2", ref: ref,
                               focused: front && tty == curTTY)
        }
        return res
    }

    // MARK: - Terminal.app adapter

    // Same join as iTerm2: every tab publishes its tty. The tab has no
    // stable id, so ref = "<window id>:<tab index>" — good enough for the
    // seconds between a snapshot and a click.
    private static let terminalAppLs = """
    tell application "Terminal"
    	set fm to frontmost
    	set out to "FRONT|" & fm & linefeed
    	repeat with w in windows
    		set wid to id of w
    		set widx to index of w
    		set n to count of tabs of w
    		repeat with i from 1 to n
    			try
    				set t to tab i of w
    				set out to out & wid & "|" & widx & "|" & i & "|" & (tty of t) & "|" & (selected of t) & linefeed
    			end try
    		end repeat
    	end repeat
    	return out
    end tell
    """

    private func terminalAppLocate() -> [String: Located] {
        guard appRunning("com.apple.Terminal"),
              let out = runShell(["/usr/bin/osascript", "-e", Self.terminalAppLs])
        else { return [:] }
        var res: [String: Located] = [:]
        var front = false
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count >= 2 && parts[0] == "FRONT" {
                front = parts[1] == "true"
            } else if parts.count >= 5 {
                var tty = String(parts[3])
                if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
                let focused = front && parts[1] == "1" && parts[4] == "true"
                res[tty] = Located(term: "terminal",
                                   ref: "\(parts[0]):\(parts[2])",
                                   focused: focused)
            }
        }
        return res
    }

    // MARK: - Ghostty adapter

    // Ghostty (1.3+) has an AppleScript dictionary, but its terminal class
    // exposes no tty — surfaces are joined to sessions by working
    // directory instead (kept current by shell integration).
    private static let ghosttyLs = """
    tell application "Ghostty"
    	set fm to frontmost
    	set fid to ""
    	try
    		set fid to id of focused terminal of selected tab of front window
    	end try
    	set out to "FRONT|" & fm & "|" & fid & linefeed
    	repeat with w in windows
    		repeat with t in tabs of w
    			repeat with s in terminals of t
    				try
    					set out to out & (id of s) & "|" & (working directory of s) & "|" & (name of s) & linefeed
    				end try
    			end repeat
    		end repeat
    	end repeat
    	return out
    end tell
    """

    private func ghosttyLocate() -> GhosttySnapshot {
        guard appRunning("com.mitchellh.ghostty"),
              let out = runShell(["/usr/bin/osascript", "-e", Self.ghosttyLs])
        else { return GhosttySnapshot() }
        var snap = GhosttySnapshot()
        var front = false
        var focusedId = ""
        for line in out.split(separator: "\n") {
            // maxSplits: 2 so a title containing "|" stays intact as the last field.
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 && parts[0] == "FRONT" {
                front = parts[1] == "true"
                focusedId = String(parts[2])
            } else if parts.count >= 2 {
                let title = parts.count >= 3 ? String(parts[2]) : ""
                snap.surfaces.append((ref: String(parts[0]), wd: String(parts[1]), title: title))
            }
        }
        if front && !focusedId.isEmpty {
            snap.focusedId = focusedId
        }
        return snap
    }

    // Assign Ghostty surfaces to sessions. Ghostty exposes no tty, so binding is
    // by title / cwd. Exact session names bind first, before the secondary
    // ai-title: two sessions may inherit the same task title, while only the
    // session actually hosted by the tab has that title as its live name.
    // The rest take the first unused surface with a matching cwd.
    // A session no other adapter (kitty / iTerm / Terminal) located → a Ghostty
    // candidate. Split out so the tick's filter type-checks quickly.
    private func ghosttyCandidate(_ s: SessionInfo, kitty: [Int: Located],
                                  ttys: [Int: String]) -> Bool {
        if s.entrypoint == "claude-desktop" || kitty[s.pid] != nil { return false }
        if agtermInfo[s.pid] != nil { return false }  // located precisely via env
        guard let tty = ttys[s.pid] else { return true }
        return itermCache[tty] == nil && terminalAppCache[tty] == nil
    }

    private func assignGhostty(_ candidates: [SessionInfo]) -> [Int: String] {
        var out: [Int: String] = [:]
        var used = Set<String>()

        func bind(_ s: SessionInfo, label: String?) {
            guard out[s.pid] == nil, let label, !label.isEmpty else { return }
            if let surf = ghosttyCache.surfaces.first(where: { surf in
                guard !used.contains(surf.ref) else { return false }
                let stripped = String(surf.title.drop { !$0.isLetter && !$0.isNumber })
                return stripped.caseInsensitiveCompare(label) == .orderedSame
            }) {
                out[s.pid] = surf.ref
                used.insert(surf.ref)
            }
        }

        // A live session name is the label Claude assigned to this particular
        // process. Reserve those exact matches before consulting historical
        // ai-titles, which are commonly shared by related or resumed sessions.
        for s in candidates { bind(s, label: s.name) }
        for s in candidates { bind(s, label: sessionTitles[s.sessionId]) }

        for s in candidates where out[s.pid] == nil {
            let free = ghosttyCache.surfaces.filter { $0.wd == s.cwd && !used.contains($0.ref) }
            // Prefer a surface a program titled (a running Claude tab) over a
            // bare shell tab whose title is just the working directory.
            if let surf = free.first(where: { !Self.titleIsPath($0.title) }) ?? free.first {
                out[s.pid] = surf.ref
                used.insert(surf.ref)
            }
        }
        return out
    }

    // A bare shell tab shows its cwd as the title ("~/projects/foo" or "/…"); a
    // running Claude tab shows a task / session name (usually with a status
    // glyph). Lets the cwd fallback skip empty shell tabs.
    private static func titleIsPath(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") || t.hasPrefix("~")
    }

    // MARK: - Agterm adapter

    private struct AgtermTree: Decodable {
        let result: Result
        struct Result: Decodable { let tree: Tree }
        struct Tree: Decodable { let workspaces: [Workspace] }
        struct Workspace: Decodable {
            let active: Bool?
            let sessions: [Session]?
            let windows: [Window]?
        }
        struct Window: Decodable {
            let active: Bool?
            let sessions: [Session]?
        }
        struct Session: Decodable {
            let id: String
            let active: Bool?
        }
    }

    private func agtermApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.umputun.agterm").first
    }

    // pid of the app owning the frontmost normal (layer 0) window, in true
    // z-order. NSRunningApplication.isActive / NSWorkspace.frontmostApplication
    // are cached on the observing app's main thread and read stale from the
    // tracker's background queue; the window-server list is live and thread-safe
    // (owner pid needs no Screen Recording permission — only titles do).
    nonisolated private static func frontmostWindowOwnerPID() -> pid_t? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return pid
        }
        return nil
    }

    // agtermctl ships inside the app bundle; resolve it from the running
    // instance so the path holds wherever agterm is installed (a GUI-launched
    // EpiScope has no Homebrew symlink dir on PATH).
    private func agtermctlPath(_ app: NSRunningApplication) -> String? {
        if let bundle = app.bundleURL {
            let p = bundle.appendingPathComponent("Contents/MacOS/agtermctl").path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        let fallback = "/Applications/agterm.app/Contents/MacOS/agtermctl"
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    // Which agterm sessions are currently active (their workspace/window's
    // selected session), plus whether agterm is the frontmost app — together
    // they decide focus for the done/attended dance.
    private func agtermLocate() -> AgtermSnapshot {
        guard let app = agtermApp(), let ctl = agtermctlPath(app) else {
            return AgtermSnapshot()
        }
        var snap = AgtermSnapshot()
        snap.frontmost = Self.frontmostWindowOwnerPID() == app.processIdentifier
        guard let out = runShell([ctl, "tree", "--json"]),
              let data = out.data(using: .utf8),
              let tree = try? JSONDecoder().decode(AgtermTree.self, from: data)
        else { return snap }
        // The tree may nest sessions directly under a workspace or under its
        // windows; take the active session from either shape.
        for ws in tree.result.tree.workspaces where ws.active == true {
            for s in ws.sessions ?? [] where s.active == true {
                snap.activeSessionIds.insert(s.id)
            }
            for win in ws.windows ?? [] where win.active == true {
                for s in win.sessions ?? [] where s.active == true {
                    snap.activeSessionIds.insert(s.id)
                }
            }
        }
        return snap
    }

    // Read each unseen pid's env once for its agterm window/session ids. The
    // env is fixed for a process's life, so ps-eww runs a pid at most once;
    // steady state resolves nothing. Gated on agterm running so non-agterm
    // setups never pay for it.
    private func resolveAgtermEnv(_ present: Set<Int>) {
        agtermInfo = agtermInfo.filter { present.contains($0.key) }
        agtermChecked = agtermChecked.intersection(present)
        let unseen = present.subtracting(agtermChecked)
        guard !unseen.isEmpty, appRunning("com.umputun.agterm") else { return }
        let pids = unseen.map(String.init).joined(separator: ",")
        // `ps eww` appends the environment after the command. The ids are
        // UUIDs, so a regex-style scan for each key is robust to AGTERM_SOCKET
        // (whose value contains spaces) and any other env entry.
        let out = runShell(["/bin/ps", "eww", "-o", "pid=,command=", "-p", pids]) ?? ""
        for line in out.split(separator: "\n") {
            guard let pidField = line.split(separator: " ", maxSplits: 1).first,
                  let pid = Int(pidField) else { continue }
            let s = String(line)
            if let sid = Self.envUUID(in: s, key: "AGTERM_SESSION_ID"),
               let wid = Self.envUUID(in: s, key: "AGTERM_WINDOW_ID") {
                agtermInfo[pid] = (window: wid, session: sid)
            }
        }
        agtermChecked.formUnion(unseen)
    }

    // Value of a `KEY=<uuid>` token inside a whitespace-joined env dump.
    private static func envUUID(in s: String, key: String) -> String? {
        guard let r = s.range(of: key + "=") else { return nil }
        let val = s[r.upperBound...].prefix { $0 == "-" || $0.isHexDigit }
        return val.isEmpty ? nil : String(val)
    }

    // MARK: - ancestry fallback (terminal kind without window ref / focus)

    private func ancestryLookup(pids: [Int]) -> [Int: AncestryHost] {
        guard let out = runShell(["/bin/ps", "-axo", "pid=,ppid=,comm="])
        else { return [:] }
        var parent: [Int: Int] = [:]
        var exePath: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]), let ppid = Int(parts[1])
            else { continue }
            parent[pid] = ppid
            exePath[pid] = String(parts[2]).trimmingCharacters(in: .whitespaces)
        }
        var res: [Int: AncestryHost] = [:]
        for start in pids {
            var pid = start
            var nearestBundleId: String?
            for _ in 0..<15 {
                let path = exePath[pid] ?? ""
                let base = path.components(separatedBy: "/").last ?? ""
                let bundleId = Self.bundleId(exePath: path)
                if nearestBundleId == nil { nearestBundleId = bundleId }
                if let term = Self.termsByAncestorExe[base] {
                    // For JetBrains, attach the IDE bundle id so cc-open
                    // can activate the exact app.
                    let hostBundleId = bundleId ?? nearestBundleId
                    res[start] = AncestryHost(
                        term: term,
                        ref: term == "jetbrains" ? hostBundleId : nil,
                        bundleId: hostBundleId)
                    break
                }
                // Any other JetBrains product → bundle id com.jetbrains*.
                if let bundleId, bundleId.hasPrefix("com.jetbrains") {
                    res[start] = AncestryHost(
                        term: "jetbrains", ref: bundleId, bundleId: bundleId)
                    break
                }
                guard let up = parent[pid], up > 1 else { break }
                pid = up
            }
            // No dedicated adapter is needed for an application we have never
            // seen before: its outer .app bundle is enough to show its icon and
            // bring it forward. Keep walking for known terminals first so an
            // Electron helper cannot hide a more precise host above it.
            if res[start] == nil, let nearestBundleId {
                res[start] = AncestryHost(
                    term: "application", ref: nearestBundleId,
                    bundleId: nearestBundleId)
            }
        }
        return res
    }

    // Cache of <app>.app path → CFBundleIdentifier, confined to the
    // tracker queue (ancestryLookup runs there).
    nonisolated(unsafe) private static var bundleIdCache: [String: String?] = [:]
    private static func bundleId(exePath: String) -> String? {
        // Use the outermost bundle. Electron and IDE helpers often execute from
        // Contents/Frameworks/<Helper>.app, but the icon users recognise belongs
        // to the containing application.
        guard let r = exePath.range(of: ".app/") else { return nil }
        let appPath = String(exePath[..<r.lowerBound]) + ".app"
        if let cached = bundleIdCache[appPath] { return cached }
        var bid: String?
        let plist = appPath + "/Contents/Info.plist"
        if let data = FileManager.default.contents(atPath: plist),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            bid = obj["CFBundleIdentifier"] as? String
        }
        bundleIdCache[appPath] = bid
        return bid
    }

    // MARK: - terminal turn outcomes

    private struct ClaudeOutcomeRecord: Decodable {
        let type: String?
        let isApiErrorMessage: Bool?
        let error: String?
    }

    private struct CodexOutcomeRecord: Decodable {
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let reason: String?
        }
    }

    private func claudeTurnErrored(sessionId: String, cwd: String) -> Bool {
        let path = ClaudeProjectPath.transcript(
            sessionId: sessionId, cwd: cwd,
            in: URL(fileURLWithPath: home + "/.claude/projects", isDirectory: true)).path
        return cachedTurnOutcome(path: path) { data in
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0a, omittingEmptySubsequences: true).reversed() {
                guard let record = try? decoder.decode(ClaudeOutcomeRecord.self, from: Data(line)) else {
                    continue
                }
                switch record.type {
                case "assistant":
                    return record.isApiErrorMessage == true || record.error != nil
                case "user":
                    // A retry/new prompt supersedes the previous failed turn.
                    return false
                default:
                    continue
                }
            }
            return false
        }
    }

    private func codexTurnErrored(at path: String) -> Bool {
        cachedTurnOutcome(path: path) { data in
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0a, omittingEmptySubsequences: true).reversed() {
                guard let record = try? decoder.decode(CodexOutcomeRecord.self, from: Data(line)),
                      record.type == "event_msg",
                      let event = record.payload?.type else { continue }
                switch event {
                case "task_complete":
                    return false
                case "error":
                    return true
                case "stream_error":
                    // Retry/reconnect progress, not a terminal outcome. If
                    // retries are exhausted Codex follows with `error`.
                    continue
                case "turn_aborted":
                    // A user cancellation is a normal stopped turn. Other abort
                    // reasons indicate that Codex could not finish the turn.
                    let normalReasons = ["interrupted", "user_requested"]
                    return !normalReasons.contains(record.payload?.reason ?? "")
                case "task_started":
                    // A new turn clears a prior error while it is in progress.
                    return false
                default:
                    continue
                }
            }
            return false
        }
    }

    private func cachedTurnOutcome(path: String, scan: (Data) -> Bool) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        if let cached = turnOutcomeCache[path], cached.mtime == mtime, cached.size == size {
            return cached.errored
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        let tailSize: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let errored = scan(data)
        turnOutcomeCache[path] = TurnOutcomeCacheEntry(mtime: mtime, size: size, errored: errored)
        return errored
    }

    // MARK: - state machine (signal files are keyed by CC session id)

    private func computeState(sid: String, status: String,
                              statusUpdatedAt: Int64?,
                              turnErrored: Bool,
                              located: Bool, focused: Bool) -> String {
        let fm = FileManager.default
        let sigPath = stateDir + "/sig-" + sid
        let attPath = stateDir + "/attended-" + sid
        var sig = (try? String(contentsOfFile: sigPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // PermissionRequest can write its hook signal just before the session
        // file reaches `waiting`. Conversely, once an answer is accepted the
        // authoritative status returns to `busy`; discard the now-stale signal
        // rather than showing a request while the approved tool is running.
        if status == "busy" && sig == "needs_permission" {
            try? fm.removeItem(atPath: sigPath)
            sig = ""
        }

        // A failed/stalled API stream may return the authoritative session
        // status to idle without firing Claude's Stop hook. In that case the
        // old UserPromptSubmit signal remains "thinking" forever and masks the
        // completed turn. Compare timestamps so idle only wins when it is at
        // least as new as the signal; a freshly-written thinking hook may race
        // briefly with the previous idle status at the start of a new turn.
        if status == "idle" && sig == "thinking" {
            let sigAttributes = try? fm.attributesOfItem(atPath: sigPath)
            let sigUpdatedAt = sigAttributes?[.modificationDate] as? Date
            let statusIsNewer: Bool
            if let statusUpdatedAt, let sigUpdatedAt {
                statusIsNewer = TimeInterval(statusUpdatedAt) / 1000
                    >= sigUpdatedAt.timeIntervalSince1970
            } else {
                // Older Claude versions may omit statusUpdatedAt. Their idle
                // status is still a stronger source than a thinking hook that
                // has no matching Stop event.
                statusIsNewer = true
            }
            if statusIsNewer {
                try? fm.removeItem(atPath: sigPath)
                sig = ""
            }
        }

        // A terminal API/stream failure ended the turn and needs the same kind
        // of user reaction as a completed step. Keep its distinct Error label,
        // but let navigation through EpiScope acknowledge its amber alarm.
        if status != "waiting" && status != "busy" && turnErrored {
            return errorState(sid: sid)
        }

        if !located {
            // No focus signal exists for this session, so the attended
            // dance can't apply — never derive an unacknowledgeable "done".
            if sig == "needs_permission" || status == "waiting" { return "needs_permission" }
            if sig == "thinking" || status == "busy" { return "thinking" }
            return "idle"
        }

        // Once CC goes busy again, an old "attended" mark is no longer
        // relevant — the next idle should re-show done.
        if status == "busy" {
            try? fm.removeItem(atPath: attPath)
        }

        var state: String
        if status == "waiting" || sig == "needs_permission" {
            state = "needs_permission"
        } else if sig == "thinking" || sig == "done" {
            state = sig
        } else if status == "busy" {
            state = "thinking"
        } else if status == "idle" && !fm.fileExists(atPath: attPath) {
            state = "done"
        } else {
            state = "idle"
        }

        if focused && state != "needs_permission" && state != "error" {
            // Acknowledge only a completed step. Looking at a permission or
            // question request is not the same as answering it.
            if sig == "done" {
                try? fm.removeItem(atPath: sigPath)
            }
            Self.createOwnFile(atPath: attPath, contents: nil)
            state = "idle"
        }
        return state
    }

    private func errorState(sid: String) -> String {
        FileManager.default.fileExists(atPath: stateDir + "/attended-" + sid)
            ? "error_attended"
            : "error"
    }

    // The index knows each session's ai-title (which Claude uses as the Ghostty
    // tab title); AppDelegate pushes it here so assignGhostty can bind by title.
    func updateSessionMetadata(titles: [String: String],
                               descriptions: [String: String]) {
        queue.async { [weak self] in
            self?.sessionTitles = titles
            self?.sessionDescriptions = descriptions
        }
    }

    // Codex approval detection belongs to SessionMonitor, which already tails
    // the rollout files for the menu bar/table. Reuse those ids for native
    // notifications rather than reading every live rollout twice.
    func updateCodexWaitingSessionIds(_ ids: Set<String>) {
        queue.async { [weak self] in
            self?.codexWaitingSessionIds = ids
        }
    }

    // The user opened this session's home via EpiScope. Window focus can't
    // always be detected (notably the Claude desktop app), so acknowledge
    // explicitly: record the attended mark and wipe a pending `done` signal so
    // Finished or Error attention clears on the next tick. Permission/question
    // requests are not acknowledged by navigation; they remain active until CC
    // leaves waiting.
    func acknowledge(sessionId sid: String) {
        // The id names two files here, one of which we delete. It reaches us
        // from the session index (a transcript filename) as well as from a
        // session file, so re-check it at the entry point.
        guard SessionID.isValid(sid) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let sigPath = self.stateDir + "/sig-" + sid
            let sig = (try? String(contentsOfFile: sigPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let waiting = self.lastStates[sid] == "needs_permission"
                || SessionStore.shared.sessions().contains {
                    $0.sessionId == sid && $0.isWaiting
                }
            // Navigation never acknowledges a permission or question request,
            // and must not pre-acknowledge the `Finished` state that may follow
            // it if waiting transitions straight to idle between tracker ticks.
            if sig == "needs_permission" || waiting { return }
            if sig == "done" {
                try? fm.removeItem(atPath: sigPath)
            }
            Self.createOwnFile(atPath: self.stateDir + "/attended-" + sid, contents: nil)
        }
    }

    // createFile follows a symlink at the final component, so a link planted in
    // ~/.claude/state — a directory other tools also write to — would let these
    // markers truncate a file anywhere in the home dir. Everything we create
    // here is a zero-byte marker or our own tmp file; a symlink is never ours.
    @discardableResult
    private static func createOwnFile(atPath path: String, contents: Data?) -> Bool {
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            == .typeSymbolicLink {
            try? fm.removeItem(atPath: path)
        }
        return fm.createFile(atPath: path, contents: contents)
    }

    private func cleanupSignals(liveSids: Set<String>) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: stateDir)) ?? [] {
            let sid: String
            if name.hasPrefix("sig-") {
                sid = String(name.dropFirst(4))
            } else if name.hasPrefix("attended-") {
                sid = String(name.dropFirst(9))
            } else {
                continue
            }
            if !liveSids.contains(sid) {
                try? fm.removeItem(atPath: stateDir + "/" + name)
            }
        }
    }

    // MARK: - publish (the cc-states.json v1 contract, see SETUP.md)

    private struct Entry: Encodable {
        let state: String
        let session_id: String
        let term: String?
        let ref: String?
        let bundle_id: String?  // optional v1 extension: exact hosting app
        let sock: String?  // kitty: @-control socket owning `ref`
        let tty: String?
        let cwd: String
        let focused: Bool
        let wid: Int?  // deprecated kitty-only alias of ref
    }

    private struct Snapshot: Encodable {
        let v = 1
        let publisher = "episcope"
        let states: [String: Entry]
    }

    private func publish(_ states: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(Snapshot(states: states))
        else { return }
        let tmp = stateDir + "/.cc-states.tmp"
        let dst = stateDir + "/cc-states.json"
        guard Self.createOwnFile(atPath: tmp, contents: data)
        else { return }
        rename(tmp, dst)  // atomic — readers never see a half-written file
    }

    // MARK: - notifications

    // The system owns the banner width and may still clip for accessibility
    // sizes. A conservative grapheme limit keeps ordinary notification text to
    // one visual line without splitting emoji or composed Unicode characters.
    private static func compactNotificationDescription(_ raw: String) -> String? {
        let oneLine = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        let limit = 36
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func notificationDisplayPath(_ cwd: String) -> String {
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd.isEmpty ? "Claude Code" : cwd
    }

    private func notifyTransitions(_ bySid: [String: Entry]) {
        let center = UNUserNotificationCenter.current()
        for (sid, entry) in bySid {
            let state = entry.state
            // Require the state to hold for two consecutive ticks before acting.
            // A flapping session — e.g. Ghostty's surface list dropping in and
            // out flips located → done → idle every couple of seconds — never
            // settles, so it no longer spams add/remove.
            let stable = state == lastStates[sid]
            lastStates[sid] = state
            guard stable, state != settledStates[sid] else { continue }
            let hadPriorState = settledStates[sid] != nil
            settledStates[sid] = state
            switch state {
            case "done", "error", "needs_permission":
                // Suppress launch noise: only notify once we've settled on some
                // earlier state, not on whatever existed at startup.
                guard hadPriorState else { continue }
                let content = UNMutableNotificationContent()
                let path = notificationDisplayPath(entry.cwd)
                switch state {
                case "done": content.title = path + " · Finished"
                case "error": content.title = path + " · Error"
                default: content.title = path
                }
                let status = state == "needs_permission" ? "Needs permission" : nil
                if let raw = sessionDescriptions[sid],
                   let description = Self.compactNotificationDescription(raw) {
                    content.body = "✨ " + description
                    if let status { content.body += "\n" + status }
                } else if let status {
                    content.body = status
                }
                content.sound = .default
                content.interruptionLevel = state == "needs_permission"
                    ? .timeSensitive
                    : .active
                content.userInfo = ["sessionId": sid]
                center.add(UNNotificationRequest(
                    identifier: "cc-" + sid, content: content, trigger: nil))
            default:
                // Attended / busy again — retract the stale banner.
                center.removeDeliveredNotifications(withIdentifiers: ["cc-" + sid])
            }
        }
        for sid in Set(lastStates.keys) where bySid[sid] == nil {
            center.removeDeliveredNotifications(withIdentifiers: ["cc-" + sid])
            lastStates[sid] = nil
            settledStates[sid] = nil
        }
    }

    // MARK: - util

    private func runShell(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

extension TerminalTracker: UNUserNotificationCenterDelegate {
    // Clicking a banner brings the user to the session's terminal/app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["episcopeReport"] != nil {
            DispatchQueue.main.async { self.onReportNotificationClick?() }
            completionHandler()
            return
        }
        if let sid = info["sessionId"] as? String {
            DispatchQueue.main.async {
                if let handler = self.onNotificationClick {
                    handler(sid)
                } else {
                    TerminalIntegration.openSession(sessionId: sid)
                    // The system activates EpiScope to deliver this tap; yield
                    // immediately so our window doesn't flash in front of the
                    // target that cc-open is bringing forward.
                    NSApp.hide(nil)
                }
            }
        }
        completionHandler()
    }

    // Show banners even while EpiScope itself is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
