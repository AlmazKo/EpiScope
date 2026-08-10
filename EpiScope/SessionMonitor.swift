import Foundation

// Polls ~/.claude/sessions/<pid>.json — Claude Code rewrites these
// every time a session changes state. Files where status == "waiting"
// normally have the agent paused on a permission prompt; `waitingFor` carries
// the human-readable tool name (e.g. "approve Bash"). The user-opened `/btw`
// overlay is the exception: it reports `waitingFor == "dialog open"` while the
// main turn continues, so it is ignored unless a real hook state independently
// says `needs_permission`.
//
// SDK-CLI sessions (entrypoint == "sdk-cli", spawned with
// --permission-prompt-tool stdio) never write status/waitingFor —
// permission goes through stdio to the parent SDK. For those we tail
// the per-session jsonl: if the last record is an assistant message
// whose content carries a tool_use block, the agent is parked waiting
// for the parent to approve. The jsonl mtime serves as updatedAt.
//
// Stale files for dead PIDs sometimes linger after a crash, so we
// filter by `kill(0)` before surfacing a session as waiting.

@MainActor
final class SessionMonitor {
    private(set) var waiting: [SessionInfo] = []
    // Every alive session keyed by sessionId, regardless of status.
    // Consumers that need to colour rows by live state (the terminal column
    // in MainWindowController) read this; the menu bar icon still only
    // cares about `waiting`.
    private(set) var liveSessions: [String: SessionInfo] = [:]
    var onUpdate: (() -> Void)?
    // Fired whenever the live status map changes — even on transitions
    // (busy → idle, etc.) that don't move the waiting set. Used by the
    // window controller so rows repaint as soon as status flips.
    var onLiveStateChange: (() -> Void)?

    private var started = false
    static let jobId = "session-monitor"
    private static let interval: TimeInterval = 1.0

    // Codex live sessions are read off the main thread (rollout tails are
    // heavy) and cached here; sample() consumes the cache and never blocks
    // on disk. Refreshed on a background queue, at most one read in flight.
    private var codexLive: [SessionInfo] = []
    private var codexRefreshing = false
    private let codexQueue = DispatchQueue(label: "episcope.codex-poll", qos: .utility)

    private static let projectsDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/projects", directoryHint: .isDirectory)

    // mtime-keyed cache so an unchanged jsonl skips the tail read.
    // `toolName` nil means "checked, not waiting".
    private struct SdkCacheEntry {
        let mtime: Date
        let toolName: String?
    }
    private static var sdkCache: [String: SdkCacheEntry] = [:]

    // Verdicts published by ~/dotfiles/kitty/state-daemon.sh
    // (cc-states.json, rewritten every tracker tick): thinking /
    // needs_permission / done / error / error_attended / idle. "done" = the
    // turn finished and the user hasn't focused that kitty window since;
    // "error" is an unacknowledged failed turn, while "error_attended" keeps
    // the table's neutral Error label after its attention alarm is cleared.
    // All the focus / attended bookkeeping lives in the publisher; we only
    // read its output.
    // Keyed by sessionId (stable across pid reuse); the daemon keys
    // its file by pid but ships session_id in every entry.
    private(set) var kittyStates: [String: String] = [:]
    // sessionId -> hosting terminal kind ("kitty" / "iterm2" / "terminal"
    // / "ghostty" / "xterm"); absent = no known terminal. Drives the
    // per-terminal icon in the sessions table.
    private(set) var terminalKinds: [String: String] = [:]
    // Exact installed application hosting the process. Unlike `term`, this is
    // intentionally open-ended: unknown terminals and desktop apps work without
    // adding another hard-coded kind to EpiScope.
    private(set) var hostBundleIds: [String: String] = [:]
    private var kittyStatesMtime: Date = .distantPast
    private static let kittyStatesURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/state/cc-states.json")
    // v1 envelope: {"v": 1, "states": {"<pid>": {"state": "done",
    // "session_id": "…", "term": "kitty", …}}}. Unknown v → ignore the
    // file (the publisher bumps v on any change a v1 reader would
    // misread). Optional fields may be absent instead of null.
    private struct CCStatesFile: Decodable {
        let v: Int
        let states: [String: Entry]
        struct Entry: Decodable {
            let state: String
            let sessionId: String?
            let term: String?
            let bundleId: String?
        }
    }

    // Returns true when the maps changed (callers repaint the rows).
    private func refreshKittyStates() -> Bool {
        var fresh: [String: String] = [:]
        var freshTerms: [String: String] = [:]
        var freshBundleIds: [String: String] = [:]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.kittyStatesURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           // A stale file means the tracker died — don't trust it.
           Date().timeIntervalSince(mtime) < 5 {
            if mtime == kittyStatesMtime { return false }
            kittyStatesMtime = mtime
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let data = try? Data(contentsOf: Self.kittyStatesURL),
               let raw = try? decoder.decode(CCStatesFile.self, from: data),
               raw.v == 1 {
                for entry in raw.states.values {
                    guard let sid = entry.sessionId else { continue }
                    fresh[sid] = entry.state
                    if let term = entry.term { freshTerms[sid] = term }
                    if let bundleId = entry.bundleId { freshBundleIds[sid] = bundleId }
                }
            }
        }
        guard fresh != kittyStates || freshTerms != terminalKinds
                || freshBundleIds != hostBundleIds else { return false }
        kittyStates = fresh
        terminalKinds = freshTerms
        hostBundleIds = freshBundleIds
        return true
    }

    // MARK: - Permission-wait accounting

    // Cumulative seconds each session has spent parked on a permission
    // prompt over its whole life. Completed segments live in waitTotals;
    // an open segment exists only as its start date in waitingSince and
    // is folded in when the wait ends, so nothing double-counts.
    // Persisted to ~/.claude/state/permission-wait.json so the numbers
    // survive app restarts (an open segment's start is saved too — if
    // the session is still waiting on relaunch the clock continues).
    //
    // Each wait segment is capped at waitCap: up to the cap counts as a real
    // perm-wait (a human actively blocked on the dialog), the overflow accrues
    // as idle-open (prompt left sitting while away). Splitting at the source
    // keeps "stalled on approval" from masquerading as hours of idle time.
    // `SessionTimeline` splits a painted segment at the same boundary.
    nonisolated static let waitCap: TimeInterval = 15 * 60
    private var waitTotals: [String: TimeInterval] = [:]
    private var idleTotals: [String: TimeInterval] = [:]
    private var waitingSince: [String: Date] = [:]
    // Closed segments, newest last. The totals above say how long a session
    // spent waiting; only these say *when*, which is what the details-mode
    // lifecycle strip paints — nothing else on disk remembers a wait that is
    // already over. Capped globally so the file cannot grow without bound.
    private static let segmentCap = 4000
    private static let segmentFloor: TimeInterval = 3
    private var waitSegments: [WaitFile.Segment] = []
    // Open-segment starts restored from disk, consumed by the first
    // sample: still-waiting sessions resume their clock; anything else
    // ended at an unknowable moment and is dropped (undercounting beats
    // inventing time).
    private var restoredSince: [String: Date] = [:]

    private static let waitFileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/state/permission-wait.json")

    private struct WaitFile: Codable {
        var totals: [String: TimeInterval]
        var since: [String: TimeInterval]  // epoch seconds
        var idle: [String: TimeInterval]?  // optional: older files lack it
        var segments: [Segment]?           // optional: older files lack it

        // Short keys — one closed wait each, and there are thousands.
        struct Segment: Codable {
            let s: String          // session id
            let a: TimeInterval    // start, epoch seconds
            let b: TimeInterval    // end, epoch seconds
        }
    }

    // When this session's prompts were on screen, oldest first. Read on the
    // main actor and handed to the timeline builder before it hops off.
    func permissionSegments(for sessionId: String) -> [(start: Date, end: Date)] {
        waitSegments
            .filter { $0.s == sessionId }
            .map { (Date(timeIntervalSince1970: $0.a), Date(timeIntervalSince1970: $0.b)) }
    }

    func permissionWait(for sessionId: String) -> TimeInterval {
        var total = waitTotals[sessionId] ?? 0
        if let since = waitingSince[sessionId] {
            total += min(Date().timeIntervalSince(since), Self.waitCap)
        }
        return total
    }

    private func updateWaitClocks(nowWaiting: Set<String>) {
        let now = Date()
        var dirty = false
        for sid in nowWaiting where waitingSince[sid] == nil {
            waitingSince[sid] = min(restoredSince[sid] ?? now, now)
            dirty = true
        }
        restoredSince = [:]
        for (sid, since) in waitingSince where !nowWaiting.contains(sid) {
            let elapsed = now.timeIntervalSince(since)
            waitTotals[sid, default: 0] += min(elapsed, Self.waitCap)
            if elapsed > Self.waitCap {
                idleTotals[sid, default: 0] += elapsed - Self.waitCap
            }
            // A prompt answered within a couple of samples is noise on a
            // timeline measured in hours; keep the totals, drop the segment.
            if elapsed >= Self.segmentFloor {
                waitSegments.append(WaitFile.Segment(
                    s: sid, a: since.timeIntervalSince1970, b: now.timeIntervalSince1970))
                if waitSegments.count > Self.segmentCap {
                    waitSegments.removeFirst(waitSegments.count - Self.segmentCap)
                }
            }
            waitingSince.removeValue(forKey: sid)
            dirty = true
        }
        if dirty { saveWaitClocks() }
    }

    private func loadWaitClocks() {
        guard let data = try? Data(contentsOf: Self.waitFileURL),
              let file = try? JSONDecoder().decode(WaitFile.self, from: data)
        else { return }
        waitTotals = file.totals
        idleTotals = file.idle ?? [:]
        waitSegments = file.segments ?? []
        restoredSince = file.since.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveWaitClocks() {
        let file = WaitFile(
            totals: waitTotals,
            since: waitingSince.mapValues { $0.timeIntervalSince1970 },
            idle: idleTotals,
            segments: waitSegments)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: Self.waitFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: Self.waitFileURL, options: .atomic)
    }

    // Reads Codex live sessions off the main thread and publishes them to
    // codexLive for the next sample. At most one read in flight.
    private func refreshCodexLiveAsync() {
        guard !codexRefreshing else { return }
        codexRefreshing = true
        codexQueue.async { [weak self] in
            let sessions = Self.readCodexSessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.codexLive = sessions
                self.codexRefreshing = false
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // Screenshot mode: the badges and host icons come from the demo
        // document. No sampling job is registered, so no real process ever
        // appears next to the staged fleet.
        if DemoFleet.isEnabled {
            let demo = DemoFleet.liveState()
            liveSessions = demo.live
            waiting = demo.waiting
            terminalKinds = demo.kinds
            kittyStates = demo.states
            onUpdate?()
            onLiveStateChange?()
            return
        }
        loadWaitClocks()
        sample()
        // Sampling touches @MainActor state, so the job runs on main; the
        // scheduler's heartbeat carries the same 1 s cadence (and the same
        // let-the-OS-coalesce leeway) the private Timer used to.
        WorkScheduler.shared.register(.init(
            id: Self.jobId, interval: Self.interval, target: .main,
            initialDelay: Self.interval
        ) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        })
    }

    private func sample() {
        var found: [SessionInfo] = []
        var live: [String: SessionInfo] = [:]
        // Decoded session files come from the shared store (mtime-gated).
        for var info in SessionStore.shared.sessions()
        where Self.isProcessAlive(pid: info.pid) {
            if info.isWaiting || kittyStates[info.sessionId] == "needs_permission" {
                found.append(info)
            } else if info.isSdkCli,
                      let pending = Self.detectSdkCliPending(sessionId: info.sessionId, cwd: info.cwd) {
                info.status = "waiting"
                info.waitingFor = "approve \(pending.toolName)"
                info.updatedAt = pending.mtimeMs
                found.append(info)
            }
            live[info.sessionId] = info
        }
        // Codex sessions: served from the background-refreshed cache (no
        // disk I/O on the main thread). Keyed by the rollout uuid the
        // indexer uses. Kick the next refresh for the following tick.
        for codex in codexLive {
            live[codex.sessionId] = codex
            if codex.isWaiting { found.append(codex) }
        }
        refreshCodexLiveAsync()

        found.sort { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        updateWaitClocks(nowWaiting: Set(found.map(\.sessionId)))

        let liveChanged = !sameLiveStatus(live, liveSessions)
        let kittyChanged = refreshKittyStates()
        let waitingChanged = found != waiting
        if liveChanged { liveSessions = live }
        updateBusyClocks(live: live)
        if waitingChanged { waiting = found }
        if waitingChanged { onUpdate?() }
        if liveChanged || kittyChanged { onLiveStateChange?() }
    }

    // When each session began its current busy spell, so the badge can show how
    // long it's been "thinking". Seeded from the session file's statusUpdatedAt
    // (exact) when present, else from first observation. Cleared when it leaves
    // the busy state.
    private var busySince: [String: Date] = [:]
    var hasBusy: Bool { !busySince.isEmpty }

    func busyDuration(for sessionId: String) -> TimeInterval? {
        guard let since = busySince[sessionId] else { return nil }
        return max(0, Date().timeIntervalSince(since))
    }

    private func updateBusyClocks(live: [String: SessionInfo]) {
        let now = Date()
        var nowBusy = Set<String>()
        for (sid, info) in live where !info.isWaiting {
            if info.status == "busy" || kittyStates[sid] == "thinking" { nowBusy.insert(sid) }
        }
        for sid in nowBusy where busySince[sid] == nil {
            if let ts = live[sid]?.statusUpdatedAt {
                busySince[sid] = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            } else {
                busySince[sid] = now
            }
        }
        busySince = busySince.filter { nowBusy.contains($0.key) }
    }

    // Compare live maps by sessionId → status only — pid/cwd/etc.
    // don't matter for repainting rows.
    private func sameLiveStatus(_ a: [String: SessionInfo], _ b: [String: SessionInfo]) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in a {
            guard let other = b[k], other.status == v.status else { return false }
        }
        return true
    }

    private static func detectSdkCliPending(sessionId: String, cwd: String) -> (toolName: String, mtimeMs: Int64)? {
        let url = ClaudeProjectPath.transcript(sessionId: sessionId, cwd: cwd, in: projectsDir)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)

        if let cached = sdkCache[sessionId], cached.mtime == mtime {
            return cached.toolName.map { ($0, mtimeMs) }
        }

        let toolName = scanLastPendingTool(at: url)
        sdkCache[sessionId] = SdkCacheEntry(mtime: mtime, toolName: toolName)
        return toolName.map { ($0, mtimeMs) }
    }

    // Reads the last ~8KB of the jsonl, parses the final line, and
    // returns the tool name if it's an `assistant` record whose
    // content array contains a `tool_use` block. nil otherwise.
    private struct AssistantTail: Decodable {
        let type: String?
        // The turn's permission mode. Auto-running modes (bypassPermissions /
        // auto) never pause for approval, so a trailing tool_use there is the
        // tool executing (e.g. a long Bash), not the agent waiting on the user.
        let permissionMode: String?
        let message: Message?
        struct Message: Decodable {
            let content: [Block]?
            struct Block: Decodable {
                let type: String
                let name: String?
            }
        }
    }

    private static func scanLastPendingTool(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 0 else { return nil }

        let chunkSize: UInt64 = 8 * 1024
        let pos = total > chunkSize ? total - chunkSize : 0
        try? handle.seek(toOffset: pos)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return nil }

        let lines = chunk.split(separator: 0x0a, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        // The trailing record must be an assistant turn ending on a tool_use.
        guard let last = lines.last,
              let record = try? decoder.decode(AssistantTail.self, from: Data(last)),
              record.type == "assistant",
              let tool = record.message?.content?.first(where: { $0.type == "tool_use" })?.name
        else { return nil }

        // permissionMode isn't on every record — take the most recent one that
        // carries it (it's stable within a session).
        var mode = record.permissionMode
        if mode == nil {
            for line in lines.reversed() {
                if let r = try? decoder.decode(AssistantTail.self, from: Data(line)),
                   let m = r.permissionMode { mode = m; break }
            }
        }
        switch mode {
        case "bypassPermissions", "auto", "plan":
            return nil   // auto-runs / no approval prompt — the tool is executing
        case "acceptEdits":
            // edits are auto-approved; Bash and other tools still prompt.
            return ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) ? nil : tool
        default:
            return tool  // "default" or unknown → a genuine approval prompt
        }
    }

    private static func isProcessAlive(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // MARK: - Codex live state (polled from the rollout files)

    // Codex has no session-state file or working hooks, so we read its
    // rollout jsonl directly. A session is "waiting for approval" when
    // its newest record is a `function_call` with no matching
    // `function_call_output` yet (the agent paused for the user to
    // approve a command/patch) and the file has settled.
    private static let codexSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions", directoryHint: .isDirectory)
    private static let codexRecentWindow: TimeInterval = 10 * 60   // "live" rollout
    private static let codexSettleAge: TimeInterval = 2            // skip mid-write

    nonisolated private struct CodexRec: Decodable {
        let type: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let callId: String?
            let cwd: String?
        }
    }

    private static func readCodexSessions() -> [SessionInfo] {
        let fm = FileManager.default
        let now = Date()
        // Active rollouts live in the start-date folder; today + yesterday
        // covers anything recently appended without walking the whole tree.
        let cal = Calendar.current
        var dirs: [URL] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            dirs.append(codexSessionsDir
                .appendingPathComponent(String(format: "%04d", c.year ?? 0))
                .appendingPathComponent(String(format: "%02d", c.month ?? 0))
                .appendingPathComponent(String(format: "%02d", c.day ?? 0)))
        }

        var out: [SessionInfo] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                let age = now.timeIntervalSince(mtime)
                guard age < codexRecentWindow, age >= codexSettleAge else { continue }
                guard let cwd = codexWaitingCwd(url: url) else { continue }
                let sid = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                out.append(SessionInfo(
                    pid: 0, sessionId: sid, cwd: cwd,
                    status: "waiting", waitingFor: "approve (Codex)",
                    updatedAt: Int64(mtime.timeIntervalSince1970 * 1000),
                    entrypoint: "codex"))
            }
        }
        return out
    }

    // Returns the session cwd if the rollout's last tool call is still
    // unresolved (waiting on approval), else nil.
    nonisolated private static func codexWaitingCwd(url: URL) -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Tail: track the last function_call and whether it resolved.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 0 else { return nil }
        let tailSize: UInt64 = 64 * 1024
        try? handle.seek(toOffset: total > tailSize ? total - tailSize : 0)
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else { return nil }

        var pendingCall: String? = nil
        var sawAny = false
        for line in tail.split(separator: 0x0a, omittingEmptySubsequences: true) {
            guard let rec = try? decoder.decode(CodexRec.self, from: Data(line)) else { continue }
            guard rec.type == "response_item" || rec.type == "event_msg" else { continue }
            let pt = rec.payload?.type
            switch pt {
            case "function_call":
                pendingCall = rec.payload?.callId ?? ""
                sawAny = true
            case "function_call_output":
                if rec.payload?.callId == pendingCall { pendingCall = nil }
            case "task_complete", "task_started":
                pendingCall = nil
            default:
                break
            }
        }
        guard sawAny, pendingCall != nil else { return nil }

        // Waiting → read cwd from the session_meta on the first line.
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 32 * 1024)) ?? Data()
        if let nl = head.firstIndex(of: 0x0a),
           let meta = try? decoder.decode(CodexRec.self, from: head[head.startIndex..<nl]),
           let cwd = meta.payload?.cwd {
            return cwd
        }
        return ""
    }

}
