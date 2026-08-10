import Foundation

// Marketing-screenshot mode: stage a fleet so a screenshot shows the product
// rather than the author's real project names and chat titles. Off unless the
// hidden pref is set, like `menuBarDemo` and `debugMode`:
//
//     defaults write almazko.EpiScope demoFleet -bool YES
//
// The fleet is a document at
// ~/Library/Application Support/EpiScope/demo-fleet.json, built by
// make-demo-fleet.py from the real index — every number, timestamp and session
// id copied verbatim, only the names rewritten. Invented numbers never look
// like a real fleet, and keeping the ids keeps each row's colour. Edit the JSON
// to re-stage a shot; no rebuild needed.
//
// The main window is fed by three independent sources, so all three are
// intercepted and their scanners stay parked: the index (rows and their
// numbers), the monitor (status badges and host icons) and the aggregate
// chart. Intercepting only one leaves the other two showing real data.
enum DemoFleet {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoFleet") }

    static let documentURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appending(path: "EpiScope", directoryHint: .isDirectory)
            .appending(path: "demo-fleet.json")
    }()

    // MARK: - Document

    struct Document: Codable {
        // The real index, verbatim. make-demo-fleet.py copies
        // sessions.json and rewrites only what names the work — cwd, title,
        // name, branch, transcript path. Every number, timestamp and session id
        // is untouched, which is the whole point: invented token counts and
        // spans never look like a real fleet, and the ids keep each row's
        // colour identical to the real table.
        var entries: [SessionIndexEntry]
        // Which of those sessions wear a live badge, by session id.
        var live: [Live]?
        // Insights mode: the runs list on the left and the report on the right.
        var insights: [Report]?
        // Details mode: the conversation any staged session opens into. The
        // first user line is replaced by that row's own title, so the
        // transcript matches the row that was double-clicked.
        var conversation: [Message]?

        struct Report: Codable {
            var title: String
            var type: String?           // retro | question | insights | digest
            var hoursAgo: Double?
            var model: String?
            var costUSD: Double?
            var durationSec: Double?
            var turns: Int?
            var markdown: String
        }

        struct Message: Codable {
            var role: String            // user | assistant
            var text: String
        }

        struct Live: Codable {
            var sessionId: String
            var status: String              // busy | waiting | idle | finished | error
            var busySeconds: Int?           // elapsed shown on the Busy badge
            var terminal: String?           // ghostty | kitty | iterm2 | terminal | xterm
        }
    }

    // Loaded once per launch: a screenshot session should not shift under the
    // photographer because a timer refired.
    private static var cached: Document?

    static func document() -> Document {
        if let cached { return cached }
        let doc = loadOrSeed()
        cached = doc
        return doc
    }

    private static func loadOrSeed() -> Document {
        let fm = FileManager.default
        // Same date strategy the index writes with, so entries copied out of
        // sessions.json decode with their timestamps intact.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let data = fm.contents(atPath: documentURL.path),
           let doc = try? decoder.decode(Document.self, from: data) {
            return doc
        }
        let starter = starterDocument
        try? fm.createDirectory(at: documentURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(starter) {
            try? data.write(to: documentURL, options: .atomic)
        }
        return starter
    }

    // MARK: - Rows

    // Verbatim: the table shows exactly what the real index held, minus the
    // names. Nothing here derives, scales or invents a number.
    static func entries() -> [SessionIndexEntry] { document().entries }

    // MARK: - Live state

    // The monitor's view of the same fleet: which rows carry a Busy / Waiting
    // badge and which host icon sits in the App column. Only the handful listed
    // in `live` — a few hundred simultaneously "running" processes would not be
    // believable.
    static func liveState() -> (live: [String: SessionInfo],
                                waiting: [SessionInfo],
                                kinds: [String: String],
                                states: [String: String]) {
        let doc = document()
        var live: [String: SessionInfo] = [:]
        var waiting: [SessionInfo] = []
        var kinds: [String: String] = [:]
        // The tracker's own verdict, which the menu-bar fleet chart reads for
        // the states a raw status cannot express (a finished turn, a failed one).
        var states: [String: String] = [:]
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let byId = Dictionary(doc.entries.map { ($0.sessionId, $0) },
                              uniquingKeysWith: { a, _ in a })

        for (i, spec) in (doc.live ?? []).enumerated() {
            guard let entry = byId[spec.sessionId] else { continue }
            let id = spec.sessionId
            if let term = spec.terminal, term != "none" { kinds[id] = term }
            switch spec.status {
            case "finished": states[id] = "done"
            case "error":    states[id] = "error"
            case "busy":     states[id] = "thinking"
            default:         break
            }
            var info = SessionInfo(pid: 40_000 + i, sessionId: id, cwd: entry.cwd)
            info.status = spec.status == "finished" ? "idle" : spec.status
            info.entrypoint = entry.isClaudeDesktop ? "claude-desktop" : "cli"
            info.name = entry.name
            info.updatedAt = nowMs
            // The Busy badge counts up from this moment, so a fixed elapsed in
            // the document ("00:16") lands as written at screenshot time.
            info.statusUpdatedAt = nowMs - Int64((spec.busySeconds ?? 0) * 1000)
            if spec.status == "waiting" { info.waitingFor = "Bash"; waiting.append(info) }
            live[id] = info
        }
        return (live, waiting, kinds, states)
    }

    // MARK: - Insights

    static func reports() -> [AnalysisReport] {
        let now = Date()
        return (document().insights ?? []).enumerated().map { i, r in
            AnalysisReport(
                id: "de400000-0000-4000-8000-\(String(format: "%012x", i &+ 1))",
                type: AnalysisType(rawValue: r.type ?? "insights") ?? .insights,
                createdAt: now.addingTimeInterval(-(r.hoursAgo ?? Double(i) * 24) * 3600),
                title: r.title,
                question: nil,
                scopeSessionIds: [],
                scopeCwd: nil,
                model: r.model ?? "claude-sonnet-4-6",
                costUSD: r.costUSD,
                agentSessionId: nil,
                durationSec: r.durationSec,
                numTurns: r.turns,
                status: .completed,
                errorSummary: nil,
                // Doubles as the index into the document: the store is bypassed,
                // nothing is read from disk.
                fileBase: "demo-\(i)"
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func markdown(for report: AnalysisReport) -> String? {
        guard let base = report.fileBase, base.hasPrefix("demo-"),
              let i = Int(base.dropFirst("demo-".count)),
              let staged = document().insights, staged.indices.contains(i)
        else { return nil }
        return staged[i].markdown
    }

    // MARK: - Transcript

    // Details mode reads the same events for its message list and its
    // per-session spend chart, so the cumulative counters are carried here too:
    // they are what the chart differentiates into bars.
    static func transcript(for entry: SessionIndexEntry) -> [SessionIndexer.TranscriptEvent] {
        let script = document().conversation ?? []
        guard !script.isEmpty else { return [] }
        let started = entry.startedAt ?? entry.lastActivity.addingTimeInterval(-3600)
        let span = max(600, entry.lastActivity.timeIntervalSince(started))
        let step = span / Double(max(1, script.count))

        var cumInput: Int64 = 0, cumWrite: Int64 = 0, cumRead: Int64 = 0, cumOutput: Int64 = 0
        let shareIn = entry.inputTokens / Int64(max(1, script.count / 2))
        let shareWrite = entry.cacheCreationTokens / Int64(max(1, script.count / 2))
        let shareRead = entry.cacheReadTokens / Int64(max(1, script.count / 2))
        let shareOut = entry.outputTokens / Int64(max(1, script.count / 2))

        return script.enumerated().map { i, m in
            let isUser = m.role == "user"
            // The first prompt is the row's own title, so the transcript opens
            // on the sentence the table shows.
            let text = (isUser && i == 0)
                ? (entry.title ?? m.text)
                : m.text
            if !isUser {
                cumInput &+= shareIn
                cumWrite &+= shareWrite
                cumRead &+= shareRead
                cumOutput &+= shareOut
            }
            return SessionIndexer.TranscriptEvent(
                kind: isUser ? .user : .assistant,
                timestamp: started.addingTimeInterval(step * Double(i)),
                text: text,
                cumInput: isUser ? nil : cumInput,
                cumCacheWrite: isUser ? nil : cumWrite,
                cumCacheRead: isUser ? nil : cumRead,
                cumOutput: isUser ? nil : cumOutput
            )
        }
    }

    // MARK: - Deep search

    // Staged results for the search mode. This is not a nicety: without it the
    // one surface that reads its own database would answer a screenshot query
    // with the author's real conversations, which is the thing demo mode exists
    // to prevent.
    static func search(_ raw: String) -> [MessageHit] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        let script = document().conversation ?? []
        let rows = entries()
        var hits: [MessageHit] = []

        for (i, e) in rows.enumerated() where hits.count < 40 {
            // Match the row's own title first, then the staged dialogue, so a
            // query typed for the screenshot lands on visibly relevant rows.
            let haystacks: [(role: String, text: String)] =
                [("user", e.title ?? "")] + script.map { ($0.role, $0.text) }
            for (role, text) in haystacks where hits.count < 40 {
                guard let range = text.lowercased().range(of: needle) else { continue }
                hits.append(MessageHit(
                    sessionId: e.sessionId,
                    provider: e.provider,
                    role: role,
                    timestamp: e.lastActivity.addingTimeInterval(-Double(i) * 90),
                    marked: marked(text, range: range),
                    locator: String(text.prefix(120))
                ))
                break   // one excerpt per session keeps the result list readable
            }
        }
        return hits
    }

    // Wrap the match in the sentinels the results view highlights on, and trim
    // the excerpt to a window around it the way FTS5's snippet() would.
    private static func marked(_ text: String, range: Range<String.Index>) -> String {
        let lead = text.index(range.lowerBound,
                              offsetBy: -60,
                              limitedBy: text.startIndex) ?? text.startIndex
        let tail = text.index(range.upperBound,
                              offsetBy: 90,
                              limitedBy: text.endIndex) ?? text.endIndex
        let prefix = lead == text.startIndex ? "" : "…"
        let suffix = tail == text.endIndex ? "" : "…"
        return prefix
            + text[lead..<range.lowerBound]
            + SearchIndex.hlStart + text[range] + SearchIndex.hlEnd
            + text[range.upperBound..<tail]
            + suffix
    }

    // MARK: - Empty fallback

    // Demo mode with no document is a mistake, not a mode: the answer is to
    // run make-demo-fleet.py, which is the only thing holding a real index to
    // copy. An empty table says that louder than invented rows would.
    private static let starterDocument = Document(entries: [], live: nil,
                                                  insights: nil, conversation: nil)
}
