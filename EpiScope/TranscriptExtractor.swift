import Foundation

// Builds the material an analysis agent reads: per-session "packets" —
// compact markdown digests of a transcript (index stats, tool-activity
// summary, conversation) — plus a catalog listing every session in scope.
// Raw jsonl transcripts run to tens of MB with 100KB+ tool-result lines,
// so the agent gets these digests as its primary source and only greps
// the raw files to verify specifics.
nonisolated enum TranscriptExtractor {

    // MARK: - Packet

    // Writes one packet file. Returns false when the transcript can't be
    // located (the session row still exists but the jsonl is gone).
    @discardableResult
    static func buildPacket(for entry: SessionIndexEntry, to url: URL,
                            maxBytes: Int = 150_000) -> Bool {
        guard let transcript = SessionIndexer.transcriptURL(for: entry),
              FileManager.default.fileExists(atPath: transcript.path) else { return false }

        var md = statsSection(entry: entry, transcript: transcript)
        if entry.provider == .claude {
            md += toolActivitySection(transcript: transcript)
        }
        md += conversationSection(entry: entry, transcript: transcript,
                                  budget: max(20_000, maxBytes - md.utf8.count))
        return (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    private static func statsSection(entry: SessionIndexEntry, transcript: URL) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let sizeMB = Double((try? FileManager.default
            .attributesOfItem(atPath: transcript.path))?[.size] as? Int64 ?? entry.fileSize)
            / 1_048_576

        var lines = [
            "# Session \(entry.sessionId) — \(entry.displayTitle)",
            "",
            "## Stats (from EpiScope index)",
        ]
        var head = "project: \(entry.relativePath)"
        if let b = entry.lastGitBranch, !b.isEmpty { head += " · branch: \(b)" }
        if let m = entry.model { head += " · model: \(m)" }
        if let e = entry.effort { head += " (\(e))" }
        lines.append(head)
        var when = ""
        if let s = entry.startedAt { when += "started: \(day.string(from: s)) · " }
        when += "last activity: \(day.string(from: entry.lastActivity))"
        lines.append(when)
        lines.append(String(format: "turns: %d · user messages: %d · cost: $%.2f",
                            entry.turns, entry.userMessageCount, entry.costUSD))
        lines.append("tokens: input \(compact(entry.inputTokens))"
            + " · cache-write \(compact(entry.cacheCreationTokens))"
            + " · cache-read \(compact(entry.cacheReadTokens))"
            + " · output \(compact(entry.outputTokens))")
        if entry.linesAdded + entry.linesRemoved > 0 {
            lines.append("code lines touched: +\(entry.linesAdded) / -\(entry.linesRemoved)")
        }
        lines.append(String(format: "raw transcript: %@ (%.1f MB)", transcript.path, sizeMB))
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func compact(_ n: Int64) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.0fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    // MARK: - Tool activity (Claude jsonl only)

    // Just enough of a transcript record to count tool calls and their
    // failures. tool_use lives in assistant records (id, name, input);
    // tool_result echoes land in user records carrying tool_use_id +
    // is_error — matching ids attributes each failure to its tool.
    private struct Rec: Decodable {
        let type: String?
        let message: Msg?
        struct Msg: Decodable {
            let content: Content?
        }
        enum Content: Decodable {
            case text(String)
            case blocks([Block])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .text(s); return }
                self = .blocks((try? c.decode([Block].self)) ?? [])
            }
        }
        struct Block: Decodable {
            let type: String?
            let id: String?
            let name: String?
            let input: Input?
            let toolUseId: String?
            let isError: Bool?
        }
        struct Input: Decodable {
            let filePath: String?
            let command: String?
        }
    }

    private static func toolActivitySection(transcript: URL) -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var calls: [String: Int] = [:]          // tool name → call count
        var fails: [String: Int] = [:]          // tool name → failed results
        var fileTouches: [String: [String: Int]] = [:]  // tool → file → count
        var bashWords: [String: Int] = [:]      // first word of command → count
        var idToName: [String: String] = [:]    // tool_use id → tool name

        _ = JSONLReader.stream(at: transcript) { line in
            guard let rec = try? decoder.decode(Rec.self, from: line),
                  case let .blocks(blocks)? = rec.message?.content else { return }
            for b in blocks {
                switch b.type {
                case "tool_use":
                    guard let name = b.name else { continue }
                    calls[name, default: 0] += 1
                    if let id = b.id { idToName[id] = name }
                    if let path = b.input?.filePath {
                        let file = URL(fileURLWithPath: path).lastPathComponent
                        fileTouches[name, default: [:]][file, default: 0] += 1
                    }
                    if name == "Bash", let cmd = b.input?.command,
                       let word = cmd.split(separator: " ").first {
                        bashWords[String(word), default: 0] += 1
                    }
                case "tool_result":
                    if b.isError == true, let id = b.toolUseId, let name = idToName[id] {
                        fails[name, default: 0] += 1
                    }
                default: break
                }
            }
        }
        guard !calls.isEmpty else { return "" }

        var lines = ["## Tool activity"]
        for (name, count) in calls.sorted(by: { $0.value > $1.value }) {
            var line = "\(name): \(count) calls"
            if let f = fails[name] { line += ", \(f) failed" }
            // Files the tool hit repeatedly — the retro's re-read/re-edit
            // churn signal. Only worth naming from 3 touches up.
            let repeated = (fileTouches[name] ?? [:])
                .filter { $0.value >= 3 }
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key) ×\($0.value)" }
            if !repeated.isEmpty { line += " (repeated: \(repeated.joined(separator: ", ")))" }
            if name == "Bash" {
                let top = bashWords.sorted { $0.value > $1.value }.prefix(5)
                    .map { "\($0.key) ×\($0.value)" }
                if !top.isEmpty { line += " (top: \(top.joined(separator: ", ")))" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Conversation

    private static func conversationSection(entry: SessionIndexEntry, transcript: URL,
                                            budget: Int) -> String {
        // A single pasted log can dwarf the whole budget — cap each message
        // before the head/tail split so one giant paste can't eat the packet.
        let perMessageCap = 20_000
        let stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm"

        var rendered: [String] = []
        _ = SessionIndexer.indexableMessages(provider: entry.provider,
                                             at: transcript, fromOffset: 0) { role, ts, text in
            var body = text
            if body.utf8.count > perMessageCap {
                body = String(body.prefix(perMessageCap)) + "\n[… message truncated …]"
            }
            let time = ts.map { stamp.string(from: $0) } ?? "—"
            rendered.append("### [\(time)] \(role == "user" ? "USER" : "ASSISTANT")\n\n\(body)\n")
        }

        var out = "## Conversation\n\n"
        let total = rendered.reduce(0) { $0 + $1.utf8.count }
        if total <= budget {
            return out + rendered.joined(separator: "\n")
        }

        // Head + tail: openings set the goal, endings hold the outcome; the
        // middle is what the agent can grep the raw transcript for.
        let headBudget = budget * 2 / 5
        let tailBudget = budget / 2
        var head: [String] = []
        var used = 0
        for msg in rendered {
            if used + msg.utf8.count > headBudget { break }
            head.append(msg)
            used += msg.utf8.count
        }
        var tail: [String] = []
        used = 0
        for msg in rendered.reversed() {
            if used + msg.utf8.count > tailBudget { break }
            tail.insert(msg, at: 0)
            used += msg.utf8.count
        }
        let omitted = rendered.count - head.count - tail.count
        if omitted <= 0 {
            return out + rendered.joined(separator: "\n")
        }
        out += head.joined(separator: "\n")
        out += "\n[… \(omitted) messages omitted — grep the raw transcript for specifics …]\n\n"
        out += tail.joined(separator: "\n")
        return out
    }

    // MARK: - Catalog

    // Cumulative seconds each session sat on a permission prompt —
    // SessionMonitor persists them across app restarts; the catalog reads
    // the file directly so the extractor stays decoupled from the monitor.
    private struct PermWaitFile: Decodable {
        let totals: [String: Double]
        let idle: [String: Double]?
    }

    private static func loadPermWaits() -> (wait: [String: Double], idle: [String: Double]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/state/permission-wait.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PermWaitFile.self, from: data)
        else { return ([:], [:]) }
        return (file.totals, file.idle ?? [:])
    }

    // Per-session metric lines plus pre-summed per-project totals — the
    // agent ranks and narrates, but sums come from here (models are bad
    // at adding columns). One line per session keeps a fleet of hundreds
    // surveyable in a few KB.
    // Per-session metric row — either the session's lifetime totals or, when a
    // window is set, only the work done inside it (see windowedStats).
    private struct MetricRow {
        let e: SessionIndexEntry
        let cost: Double
        let input: Int64, cacheRead: Int64
        let added: Int64, removed: Int64
        let turns: Int, userMsgs: Int
        let lastActivity: Date
        let periodSec: Double?   // lifetime span, or active-time within the window
        let windowed: Bool
    }

    @discardableResult
    static func buildCatalog(entries: [SessionIndexEntry], to url: URL,
                             since: Date? = nil) -> Bool {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let (waits, idles) = loadPermWaits()

        // Attribute metrics to the interval when `since` is set: a long-open
        // session contributes only the tokens/lines/turns it spent inside the
        // window, not its whole life. Sessions with no in-window work drop out.
        var rows: [MetricRow] = []
        // Sessions we can only quote whole, because their provider has no
        // per-interval fold. Counted so the totals below can stay interval-only.
        var lifetimeOnly = 0
        for e in entries {
            let lifetimeRow = MetricRow(
                e: e, cost: e.costUSD, input: e.inputTokens, cacheRead: e.cacheReadTokens,
                added: e.linesAdded, removed: e.linesRemoved,
                turns: e.turns, userMsgs: e.userMessageCount, lastActivity: e.lastActivity,
                periodSec: e.startedAt.map { e.lastActivity.timeIntervalSince($0) }, windowed: false)
            guard let since else { rows.append(lifetimeRow); continue }
            if let w = windowedStats(for: e, since: since) {
                rows.append(MetricRow(
                    e: e, cost: w.cost, input: w.input, cacheRead: w.cacheRead,
                    added: w.linesAdded, removed: w.linesRemoved,
                    turns: w.turns, userMsgs: w.userMsgs, lastActivity: w.last,
                    periodSec: w.last.timeIntervalSince(w.first), windowed: true))
            } else if !e.provider.supportsWindowedStats, e.lastActivity >= since,
                      !e.cwd.isEmpty {
                // The cwd test drops a stub whose deep scan has not run yet:
                // it has no project and zeroed totals, and its freshness makes
                // it pass the activity test every time.
                // Active inside the interval, but only its whole life can be
                // quoted. Dropping it made every report understate the fleet
                // silently; adding lifetime cost to interval totals would
                // overstate them instead. So: listed, flagged, not summed.
                rows.append(lifetimeRow)
                lifetimeOnly += 1
            }
        }

        let scope = since != nil ? "work in the selected interval" : "all-time totals"
        // Two counts, never one: `rows` holds both kinds, and a single number
        // next to "work in the selected interval" would be a third figure that
        // matches neither section below.
        let heading = lifetimeOnly > 0
            ? "# Session catalog (\(rows.count - lifetimeOnly) sessions · \(scope)"
                + " · plus \(lifetimeOnly) with lifetime totals only)"
            : "# Session catalog (\(rows.count) sessions · \(scope))"
        var lines = [heading, ""]
        if lifetimeOnly > 0 {
            lines.append("Note: \(lifetimeOnly) of these sessions carry lifetime totals rather "
                + "than interval work — their provider records no per-request timestamps. "
                + "They appear under Sessions marked `span`, and are left out of Project "
                + "totals so those stay interval-only. Do not add the two together.")
            lines.append("")
        }

        struct ProjectAgg {
            var sessions = 0
            var cost = 0.0
            var added: Int64 = 0
            var removed: Int64 = 0
            var waitSec = 0.0
            var idleSec = 0.0
        }
        var byProject: [String: ProjectAgg] = [:]
        // An interval report sums only rows actually folded over the interval.
        for r in rows where since == nil || r.windowed {
            var agg = byProject[r.e.relativePath] ?? ProjectAgg()
            agg.sessions += 1
            agg.cost += r.cost
            agg.added += r.added
            agg.removed += r.removed
            agg.waitSec += waits[r.e.sessionId] ?? 0
            agg.idleSec += idles[r.e.sessionId] ?? 0
            byProject[r.e.relativePath] = agg
        }
        lines.append("## Project totals")
        for (path, agg) in byProject.sorted(by: { $0.value.cost > $1.value.cost }) {
            lines.append(String(
                format: "- %@ · %d sessions · $%.2f · +%d/-%d lines · perm-wait %@ · idle-open %@",
                path, agg.sessions, agg.cost, agg.added, agg.removed,
                duration(agg.waitSec), duration(agg.idleSec)))
        }
        lines.append("")

        lines.append("## Sessions")
        for r in rows.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let e = r.e
            var line = "- \(e.sessionId) · \(day.string(from: r.lastActivity))"
                + " · \(e.displayTitle) · \(e.relativePath)"
            if let m = e.model { line += " · \(m)" }
            line += String(format: " · $%.2f · %d turns · %d user msgs",
                           r.cost, r.turns, r.userMsgs)
            if r.added + r.removed > 0 { line += " · +\(r.added)/-\(r.removed)" }
            if let p = r.periodSec {
                line += r.windowed ? " · active \(duration(p))" : " · span \(duration(p))"
            }
            // Unconditional, unlike the span above, which is missing whenever
            // startedAt is unknown: inside an interval catalog a lifetime row
            // must never be able to read as an interval one.
            if since != nil, !r.windowed { line += " · lifetime totals" }
            if let wait = waits[e.sessionId], wait >= 60 {
                line += " · perm-wait \(duration(wait))"
            }
            if let idle = idles[e.sessionId], idle >= 60 {
                line += " · idle-open \(duration(idle))"
            }
            // Deterministic signals from the indexed numbers (no re-parse):
            // cache-read blowup (long-open context re-read) and the effort knob.
            let ratio = r.input > 0 ? r.cacheRead / r.input : 0
            if ratio >= 100 { line += " · cache-read \(ratio)x" }
            if let eff = e.effort, !eff.isEmpty { line += " · effort=\(eff)" }
            if let t = SessionIndexer.toolActivity(for: e), !t.isEmpty {
                line += " · tools: \(t)"
            }
            if let raw = SessionIndexer.transcriptURL(for: e) {
                line += " · raw: \(raw.path)"
            }
            lines.append(line)
        }
        return (try? lines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // Work done inside [since, now] for one Claude session: sums usage / lines /
    // turns from transcript records timestamped in the window (assistant dedup
    // by requestId, lines from structuredPatch — mirrors SessionIndex.foldUsage
    // but time-filtered). nil if the session had no activity in the window or
    // isn't a Claude transcript. Cost uses the entry's model pricing.
    struct WindowStats {
        var cost: Double
        var input: Int64, cacheRead: Int64
        var linesAdded: Int64, linesRemoved: Int64
        var turns: Int, userMsgs: Int
        var first: Date, last: Date
    }

    static func windowedStats(for entry: SessionIndexEntry, since: Date) -> WindowStats? {
        guard entry.provider.supportsWindowedStats,
              let url = SessionIndexer.transcriptURL(for: entry) else { return nil }
        struct Rec: Decodable {
            let type: String?; let timestamp: String?; let requestId: String?
            let message: Msg?; let toolUseResult: TUR?
            struct Msg: Decodable {
                let usage: Usage?
                struct Usage: Decodable {
                    let inputTokens: Int64?; let outputTokens: Int64?
                    let cacheCreationInputTokens: Int64?; let cacheReadInputTokens: Int64?
                }
            }
            struct TUR: Decodable {
                let type: String?; let content: String?; let structuredPatch: [Hunk]?
                struct Hunk: Decodable { let lines: [String]? }
            }
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let toolUseIdData = Data("tool_use_id".utf8)

        var inp: Int64 = 0, cc: Int64 = 0, cr: Int64 = 0, out: Int64 = 0
        var turns = 0, userMsgs = 0
        var added: Int64 = 0, removed: Int64 = 0
        var first: Date?, last: Date?
        var counted = Set<String>()

        _ = JSONLReader.stream(at: url) { line in
            guard let rec = try? dec.decode(Rec.self, from: line),
                  let ts = rec.timestamp,
                  let when = isoFrac.date(from: ts) ?? iso.date(from: ts),
                  when >= since else { return }
            if first == nil || when < first! { first = when }
            if last == nil || when > last! { last = when }
            switch rec.type {
            case "assistant":
                if let rid = rec.requestId, !counted.insert(rid).inserted { return }
                turns += 1
                if let u = rec.message?.usage {
                    inp += u.inputTokens ?? 0
                    cc  += u.cacheCreationInputTokens ?? 0
                    cr  += u.cacheReadInputTokens ?? 0
                    out += u.outputTokens ?? 0
                }
            case "user":
                if let r = rec.toolUseResult {
                    switch r.type {
                    case "update":
                        for h in r.structuredPatch ?? [] {
                            for l in h.lines ?? [] {
                                if l.hasPrefix("+") { added += 1 }
                                else if l.hasPrefix("-") { removed += 1 }
                            }
                        }
                    case "create":
                        if let c = r.content, !c.isEmpty {
                            added += Int64(c.utf8.lazy.filter { $0 == 0x0a }.count) + 1
                        }
                    default: break
                    }
                } else if line.range(of: toolUseIdData) == nil {
                    userMsgs += 1
                }
            default: break
            }
        }
        guard let f = first, let l = last else { return nil }
        let p = entry.pricing
        let cost = (Double(inp) * p.input + Double(cc) * p.cacheWrite
                    + Double(cr) * p.cacheRead + Double(out) * p.output) / 1_000_000
        return WindowStats(cost: cost, input: inp, cacheRead: cr,
                           linesAdded: added, linesRemoved: removed,
                           turns: turns, userMsgs: userMsgs, first: f, last: l)
    }

    private static func duration(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: return String(format: "%.0fs", seconds)
        case ..<3600: return String(format: "%.0fm", seconds / 60)
        default: return String(format: "%.1fh", seconds / 3600)
        }
    }
}
