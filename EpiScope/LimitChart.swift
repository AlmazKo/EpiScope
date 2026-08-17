import AppKit
import Foundation

// Rate-limit window view for the aggregate chart: Claude's usage is
// capped over a rolling 5-hour "session" and a 7-day week. Neither cap
// nor its reset time is recorded anywhere on disk (the transcript's
// `rateLimits` is null outside error records), so both the windows and
// the cap are RECONSTRUCTED from message timestamps:
//
//   * 5h sessions — greedy: the first message opens a window [t, t+5h);
//     the first message past that opens the next. Account-wide (all
//     projects), matching how Anthropic's session limit actually works.
//   * weekly — fixed 7-day blocks tiled from the first window's start.
//   * cap — auto-estimated as the tallest window observed (you hit the
//     limit ⇒ that window ≈ the cap), overridable in Settings.
//
// All of this is an approximation: the true anchor/cap is Anthropic's,
// and the real limit weighs tokens by model — we use raw token sums.
// History depth is bounded by how long Claude keeps the transcripts
// (~30 days); see horizonDays.

struct LimitBucket {
    let start: Date
    let end: Date
    var tokens: Int64
}

struct LimitData {
    var windows5h: [LimitBucket] = []
    var current5h: LimitBucket?       // window containing "now", else nil (idle)
    var weekly: [LimitBucket] = []
    var currentWeekly: LimitBucket?   // 7-day block containing "now"
}

enum LimitMode: String {
    case none, session5h
}

enum LimitChart {
    static let session5hSeconds: TimeInterval = 5 * 3600
    static let weekSeconds: TimeInterval = 7 * 24 * 3600
    // Raw transcripts rarely survive beyond ~30 days of Claude's own
    // cleanup, so scanning further back just wastes I/O.
    static let horizonDays = 35

    // MARK: - Settings

    private static let modeKey = "chartLimitMode"
    static var mode: LimitMode {
        get { LimitMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    // 0 = auto-estimate. Manual override is a token count.
    static var cap5hOverride: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "chartCap5h")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "chartCap5h") }
    }
    static var capWeeklyOverride: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "chartCapWeekly")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "chartCapWeekly") }
    }

    // Resolved cap for a history set: the override if set, else the
    // tallest observed window. `isAuto` drives the "~" estimate marker.
    static func cap(forHistory history: [LimitBucket], override ov: Int64) -> (value: Int64, isAuto: Bool) {
        if ov > 0 { return (ov, false) }
        let m = history.map(\.tokens).max() ?? 0
        return (max(m, 1), true)
    }

    // MARK: - Real limits (from the status-line integration)

    // Authoritative used-percentages Claude Code reports, captured by
    // episcope-statusline.sh into ~/.claude/state. nil when the
    // integration isn't installed or the file is stale (no recent CC
    // session) — the gauges then fall back to the token estimate.
    struct RealLimits {
        let fiveHour: Double?
        let sevenDay: Double?
        var fiveHourReset: Date?
        var sevenDayReset: Date?
    }

    private static let rateLimitsPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/state/cc-rate-limits.json").path
    private static let rateLimitsFreshness: TimeInterval = 3 * 3600

    static func realLimits() -> RealLimits? {
        guard let data = FileManager.default.contents(atPath: rateLimitsPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let updated = obj["updated"] as? Double,
              Date().timeIntervalSince1970 - updated < rateLimitsFreshness
        else { return nil }
        func reset(_ key: String) -> Date? {
            (obj[key] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        // A window whose reset is already in the past has rolled over but the
        // status line hasn't refreshed it (stale carried value) — treat it as
        // missing so the per-window merge falls back to the token estimate.
        func current(_ pct: Double?, _ r: Date?) -> (Double?, Date?) {
            guard let pct else { return (nil, r) }
            if let r, r <= Date() { return (nil, nil) }
            return (pct, r)
        }
        let five = current(obj["five_hour"] as? Double, reset("five_hour_reset"))
        let seven = current(obj["seven_day"] as? Double, reset("seven_day_reset"))
        return RealLimits(fiveHour: five.0, sevenDay: seven.0,
                          fiveHourReset: five.1, sevenDayReset: seven.1)
    }

    // Codex reports its rolling limits straight in the rollout. Primary and
    // secondary are slots, not window roles: their durations vary by plan, so
    // classify them by window_minutes instead of assuming a fixed order.
    // Values are account-wide, so the newest rollout's value is current.
    private static let codexSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/sessions", directoryHint: .isDirectory)

    private struct CodexTokenRec: Decodable {
        let type: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let rateLimits: RL?
            struct RL: Decodable {
                let primary: Win?
                let secondary: Win?
                struct Win: Decodable {
                    let usedPercent: Double?
                    let windowMinutes: Int?
                    let resetsAt: Double?
                }
            }
        }
    }

    static func codexLimits() -> RealLimits? {
        let fm = FileManager.default
        let now = Date()
        let cal = Calendar.current
        // Newest rollout across the last week+ (enough to cover the weekly
        // window — the recorded %s stay valid until their reset).
        var newest: (url: URL, mtime: Date)?
        for back in 0...8 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = codexSessionsDir
                .appendingPathComponent(String(format: "%04d", c.year ?? 0))
                .appendingPathComponent(String(format: "%02d", c.month ?? 0))
                .appendingPathComponent(String(format: "%02d", c.day ?? 0))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if newest == nil || m > newest!.mtime { newest = (url, m) }
            }
        }
        guard let target = newest else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: target.url) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 0 else { return nil }
        let tailSize: UInt64 = 64 * 1024
        try? handle.seek(toOffset: total > tailSize ? total - tailSize : 0)
        guard let tail = try? handle.readToEnd() else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var latest: CodexTokenRec.Payload.RL?
        for line in tail.split(separator: 0x0a, omittingEmptySubsequences: true) {
            guard let rec = try? decoder.decode(CodexTokenRec.self, from: Data(line)),
                  rec.type == "event_msg", rec.payload?.type == "token_count",
                  let rl = rec.payload?.rateLimits else { continue }
            latest = rl
        }
        guard let latest else { return nil }

        var fiveHour: CodexTokenRec.Payload.RL.Win?
        var sevenDay: CodexTokenRec.Payload.RL.Win?
        for window in [latest.primary, latest.secondary].compactMap({ $0 }) {
            switch window.windowMinutes {
            case 5 * 60: fiveHour = window
            case 7 * 24 * 60: sevenDay = window
            default: continue
            }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }

        // The recorded %s are account-wide and stay valid until their window
        // resets. If a window's reset is already in the past, it has rolled
        // over since this rollout was written → show 0% (a fresh window), not
        // the stale figure, and drop the expired reset.
        func current(_ pct: Double?, _ reset: Date?) -> (Double?, Date?) {
            guard let pct else { return (nil, reset) }
            if let reset, reset <= now { return (0, nil) }
            return (pct, reset)
        }
        let five = current(
            fiveHour?.usedPercent,
            fiveHour?.resetsAt.map { Date(timeIntervalSince1970: $0) })
        let seven = current(
            sevenDay?.usedPercent,
            sevenDay?.resetsAt.map { Date(timeIntervalSince1970: $0) })
        return RealLimits(fiveHour: five.0, sevenDay: seven.0,
                          fiveHourReset: five.1, sevenDayReset: seven.1)
    }

    // MARK: - Cached limits (for the status-bar gauges)

    // The status-bar menu must open instantly, so it reads these cached
    // snapshots instead of touching disk. refreshLimitsCache() recomputes
    // them off-main (timer + launch); the cache itself is written and read
    // only on the main thread.
    nonisolated(unsafe) private static var cachedClaude: RealLimits?
    nonisolated(unsafe) private static var cachedCodex: RealLimits?
    nonisolated(unsafe) private static var cachedClaudeEstimate = false
    // Throttle for the heavy transcript-estimate scan (queue-confined).
    nonisolated(unsafe) private static var lastEstimate: RealLimits?
    nonisolated(unsafe) private static var lastEstimateAt: Date = .distantPast

    static func cachedClaudeLimits() -> RealLimits? { cachedClaude }
    static func cachedCodexLimits() -> RealLimits? { cachedCodex }
    // True when the cached Claude numbers are the token estimate (no real
    // status-line data) — the gauge marks them with a "~".
    static func cachedClaudeIsEstimate() -> Bool { cachedClaudeEstimate }

    // Background refresh — nobody is looking at the result yet, so it waits for
    // the index's first pass rather than walking transcripts alongside it.
    static func refreshLimitsCache() {
        WorkScheduler.shared.run(.init(id: "limits-cache")) {
            let codex = codexLimits()
            let real = realLimits()
            // Refresh the token estimate (throttled — it walks transcripts) so
            // it can fill a window the real data lacks (rolled-over or absent)
            // instead of dropping the whole section to the estimate.
            if lastEstimate == nil || Date().timeIntervalSince(lastEstimateAt) > 15 * 60 {
                lastEstimate = estimatedClaude()
                lastEstimateAt = Date()
            }
            let est = lastEstimate
            // Per window: prefer the authoritative real value, fall back to the
            // estimate only for the window real is missing.
            let five = real?.fiveHour ?? est?.fiveHour
            let seven = real?.sevenDay ?? est?.sevenDay
            let claude: RealLimits? = (five != nil || seven != nil)
                ? RealLimits(fiveHour: five, sevenDay: seven,
                             fiveHourReset: real?.fiveHour != nil ? real?.fiveHourReset : est?.fiveHourReset,
                             sevenDayReset: real?.sevenDay != nil ? real?.sevenDayReset : est?.sevenDayReset)
                : nil
            let isEstimate = (real?.fiveHour == nil && five != nil)
                || (real?.sevenDay == nil && seven != nil)
            let c = claude, ce = isEstimate, x = codex
            DispatchQueue.main.async {
                cachedClaude = c
                cachedClaudeEstimate = ce
                cachedCodex = x
            }
        }
    }

    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    // The auto-cap (busiest 5h / weekly window ever) moves slowly, so the
    // full-history scan that finds it is done rarely and cached. Queue-confined.
    nonisolated(unsafe) private static var capCache: (five: Int64, week: Int64)?
    nonisolated(unsafe) private static var capCacheAt: Date = .distantPast

    private static func estimateCaps() -> (five: Int64, week: Int64) {
        if let c = capCache, Date().timeIntervalSince(capCacheAt) < 6 * 3600 { return c }
        let since = Date().addingTimeInterval(-Double(horizonDays) * 24 * 3600).timeIntervalSince1970
        let points = collectPoints(projectsDir: projectsDir, since: since).sorted { $0.ts < $1.ts }
        let five = cap(forHistory: greedyWindows(points, span: session5hSeconds),
                       override: cap5hOverride).value
        let week: Int64
        if let anchor = points.first?.ts {
            week = cap(forHistory: tiledWindows(points, anchor: anchor, span: weekSeconds),
                       override: capWeeklyOverride).value
        } else {
            week = cap(forHistory: [], override: capWeeklyOverride).value
        }
        let c = (five, week)
        capCache = c
        capCacheAt = Date()
        return c
    }

    // Token-based estimate of current 5h / weekly usage. The current-usage
    // scan is cheap — only the last ~8 days (covers the 7-day weekly window) —
    // using rolling sums; the slow-moving caps come from estimateCaps()'s
    // rarely-refreshed full scan. Call off-main. nil if no recent activity.
    static func estimatedClaude() -> RealLimits? {
        let nowE = Date().timeIntervalSince1970
        let recentSince = nowE - 8 * 24 * 3600
        let recent = collectPoints(projectsDir: projectsDir, since: recentSince)
        guard !recent.isEmpty else { return nil }

        // Align the weekly window to the real reset cadence when known (the
        // weekly reset time is stable even when the reported % lags), so a
        // just-reset week reads low instead of ~100% from a rolling 7 days.
        let weekAnchor = weeklyResetAnchor()
        let weekStart = weekAnchor.map { $0.timeIntervalSince1970 - weekSeconds } ?? (nowE - weekSeconds)
        let win5 = recent.filter { $0.ts >= nowE - session5hSeconds }
        let winW = recent.filter { $0.ts >= weekStart }
        let use5 = win5.reduce(Int64(0)) { $0 + $1.tokens }
        let useW = winW.reduce(Int64(0)) { $0 + $1.tokens }
        let caps = estimateCaps()
        func pct(_ tokens: Int64, _ cap: Int64) -> Double {
            min(100, Double(tokens) / Double(max(cap, 1)) * 100)
        }
        // Rolling-window "reset" ≈ when the oldest still-counting usage expires.
        func reset(_ pts: [(ts: TimeInterval, tokens: Int64)], _ span: TimeInterval) -> Date? {
            pts.map(\.ts).min().map { Date(timeIntervalSince1970: $0 + span) }
        }
        return RealLimits(
            fiveHour: pct(use5, caps.five),
            sevenDay: pct(useW, caps.week),
            fiveHourReset: reset(win5, session5hSeconds),
            sevenDayReset: weekAnchor ?? reset(winW, weekSeconds))
    }

    // The weekly reset repeats on a stable 7-day cadence, so even a past
    // seven_day_reset tells us when the current week began. Roll it forward to
    // the next future reset — used to align the token estimate's weekly window
    // (and the reset it shows) instead of a meaningless rolling 7 days.
    static func weeklyResetAnchor() -> Date? {
        guard let data = FileManager.default.contents(atPath: rateLimitsPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let r = obj["seven_day_reset"] as? Double else { return nil }
        var reset = Date(timeIntervalSince1970: r)
        let now = Date()
        while reset <= now { reset = reset.addingTimeInterval(weekSeconds) }
        return reset
    }

    // MARK: - Visual helpers

    static func fillColor(_ ratio: Double) -> NSColor {
        if ratio >= 0.85 { return .systemRed }
        if ratio >= 0.60 { return .systemOrange }
        return .systemGreen
    }

    // MARK: - Compute

    // Window reconstruction shares the scan queue — see WorkScheduler.scanQueue.

    static func compute(completion: @escaping (LimitData) -> Void) {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        let horizonStart = Date().addingTimeInterval(-Double(horizonDays) * 24 * 3600)
            .timeIntervalSince1970
        // The 5h history strip honours the chart's selected time window;
        // the weekly block and the current 5h window still use the full
        // horizon (a weekly limit is always a 7-day span).
        let windowDays = TokenChartView.windowDays

        WorkScheduler.shared.run(.init(id: "limits-compute", priority: .interactive, deferrable: false)) {
            let points = collectPoints(projectsDir: projectsDir, since: horizonStart)
                .sorted { $0.ts < $1.ts }
            var data = LimitData()
            guard !points.isEmpty else {
                DispatchQueue.main.async { completion(data) }
                return
            }
            let now = Date()

            let all5h = greedyWindows(points, span: session5hSeconds)
            data.current5h = all5h.last.flatMap { $0.end > now ? $0 : nil }
            let cutoff = now.timeIntervalSince1970 - Double(windowDays) * 24 * 3600
            data.windows5h = all5h.filter { $0.start.timeIntervalSince1970 >= cutoff }

            let anchor = points[0].ts
            data.weekly = tiledWindows(points, anchor: anchor, span: weekSeconds)
            data.currentWeekly = currentTile(points, anchor: anchor, span: weekSeconds, now: now)

            DispatchQueue.main.async { completion(data) }
        }
    }

    // Fixed blocks tiled from `anchor` — only blocks with activity are
    // emitted (for the auto-cap estimate).
    private static func tiledWindows(_ pts: [(ts: TimeInterval, tokens: Int64)],
                                     anchor: TimeInterval, span: TimeInterval) -> [LimitBucket] {
        var byIdx: [Int: Int64] = [:]
        for p in pts {
            byIdx[Int((p.ts - anchor) / span), default: 0] += p.tokens
        }
        return byIdx.keys.sorted().map { idx in
            let start = Date(timeIntervalSince1970: anchor + Double(idx) * span)
            return LimitBucket(start: start,
                               end: start.addingTimeInterval(span),
                               tokens: byIdx[idx] ?? 0)
        }
    }

    // The tiled block containing `now` (always exists, even if empty).
    private static func currentTile(_ pts: [(ts: TimeInterval, tokens: Int64)],
                                    anchor: TimeInterval, span: TimeInterval,
                                    now: Date) -> LimitBucket {
        let idx = Int((now.timeIntervalSince1970 - anchor) / span)
        let start = Date(timeIntervalSince1970: anchor + Double(idx) * span)
        let end = start.addingTimeInterval(span)
        let lo = start.timeIntervalSince1970, hi = end.timeIntervalSince1970
        let toks = pts.reduce(Int64(0)) { $0 + ($1.ts >= lo && $1.ts < hi ? $1.tokens : 0) }
        return LimitBucket(start: start, end: end, tokens: toks)
    }

    // Just the window start dates, for the aggregate chart's markers:
    // 5h session starts (activity-anchored) and weekly boundaries
    // (fixed 7-day tiles from the first session). The caller clips them
    // to its visible range.
    static func windowMarkers(completion: @escaping (_ session5h: [Date], _ weekly: [Date]) -> Void) {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        let horizonStart = Date().addingTimeInterval(-Double(horizonDays) * 24 * 3600)
            .timeIntervalSince1970

        WorkScheduler.shared.run(.init(id: "limit-window-markers", priority: .interactive, deferrable: false)) {
            let points = collectPoints(projectsDir: projectsDir, since: horizonStart)
                .sorted { $0.ts < $1.ts }
            guard let anchor = points.first?.ts else {
                DispatchQueue.main.async { completion([], []) }
                return
            }
            let s5h = greedyWindows(points, span: session5hSeconds).map(\.start)
            var weekly: [Date] = []
            let nowEpoch = Date().timeIntervalSince1970
            var t = anchor
            while t <= nowEpoch {
                weekly.append(Date(timeIntervalSince1970: t))
                t += weekSeconds
            }
            DispatchQueue.main.async { completion(s5h, weekly) }
        }
    }

    // Greedy activity-anchored windows: a point inside the open window
    // adds to it; the first point past it opens the next.
    private static func greedyWindows(_ pts: [(ts: TimeInterval, tokens: Int64)],
                                      span: TimeInterval) -> [LimitBucket] {
        var out: [LimitBucket] = []
        for p in pts {
            if var last = out.last, p.ts < last.end.timeIntervalSince1970 {
                last.tokens += p.tokens
                out[out.count - 1] = last
            } else {
                let start = Date(timeIntervalSince1970: p.ts)
                out.append(LimitBucket(start: start,
                                       end: start.addingTimeInterval(span),
                                       tokens: p.tokens))
            }
        }
        return out
    }

    // MARK: - Parsing (account-wide token points)

    private struct Rec: Decodable {
        let timestamp: String?
        let requestId: String?
        let message: Msg?
        struct Msg: Decodable {
            let usage: Usage?
            struct Usage: Decodable {
                let inputTokens: Int64?
                let outputTokens: Int64?
                let cacheCreationInputTokens: Int64?
                let cacheReadInputTokens: Int64?
            }
        }
    }

    private struct CachedFile {
        var parsedSize: Int64
        var mtime: Date
        var points: [(ts: TimeInterval, tokens: Int64)]
        // Per file, like the token chart's cache: request ids are unique within
        // a session, and keeping the set per file is what lets an appended tail
        // be folded without re-reading what came before.
        var seenRequestIds: Set<String>
    }

    // This walk was the most expensive thing in the app: every call streamed
    // and JSON-decoded every transcript touched inside the horizon, from byte
    // zero, with no cache at all — measured here at 1250 files / 563 MB — and
    // three separate call sites do it (the gauge, the window markers and the
    // 6-hourly cap estimate). Now it is incremental, like the token chart 200
    // lines down in TokenChartView, which is where this shape is copied from.
    //
    // Confined to the scan queue: every caller runs inside a WorkScheduler
    // scan-group body, and that group is one serial queue.
    nonisolated(unsafe) private static var pointCache: [String: CachedFile] = [:]

    private static func collectPoints(projectsDir: URL,
                                      since: TimeInterval) -> [(ts: TimeInterval, tokens: Int64)] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var points: [(ts: TimeInterval, tokens: Int64)] = []

        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for jsonl in files where jsonl.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: jsonl.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.int64Value,
                      mtime.timeIntervalSince1970 >= since
                else { continue }

                let path = jsonl.path
                var cached: CachedFile
                if let c = pointCache[path], c.parsedSize == size, c.mtime == mtime {
                    cached = c                      // unchanged — no I/O at all
                } else if var c = pointCache[path], size > c.parsedSize {
                    c.parsedSize = parsePoints(at: jsonl, fromOffset: c.parsedSize,
                                               decoder: decoder,
                                               seenRequestIds: &c.seenRequestIds,
                                               into: &c.points)
                    c.mtime = mtime
                    cached = c
                } else {
                    // New file, or rewritten / truncated → full parse.
                    var c = CachedFile(parsedSize: 0, mtime: mtime, points: [], seenRequestIds: [])
                    c.parsedSize = parsePoints(at: jsonl, fromOffset: 0,
                                               decoder: decoder,
                                               seenRequestIds: &c.seenRequestIds,
                                               into: &c.points)
                    cached = c
                }
                pointCache[path] = cached

                // Filtering by time happens here, not while parsing: the three
                // callers pass different horizons, and a cache keyed to one of
                // them would be wrong for the others.
                for p in cached.points where p.ts >= since { points.append(p) }
            }
        }
        // Drop only what left the disk. Pruning to the files this call visited
        // would be wrong here: the callers use very different horizons — a
        // 15-minute gauge against a 6-hourly 35-day estimate — so the narrow
        // one would evict everything the wide one just paid to read.
        pointCache = pointCache.filter { fm.fileExists(atPath: $0.key) }
        return points
    }

    // Streams the appended tail and returns the absolute offset parsed up to.
    // Line-by-line on purpose: these transcripts run to tens of MB, and only
    // the assistant usage lines matter.
    private static func parsePoints(at url: URL, fromOffset: Int64,
                                    decoder: JSONDecoder,
                                    seenRequestIds: inout Set<String>,
                                    into points: inout [(ts: TimeInterval, tokens: Int64)]) -> Int64 {
        let sig = "\"type\":\"assistant\"".data(using: .utf8)!
        var seen = seenRequestIds
        var out = points
        let consumed = JSONLReader.stream(at: url, from: fromOffset) { lineData in
            guard lineData.range(of: sig) != nil,
                  let rec = try? decoder.decode(Rec.self, from: lineData),
                  let tsString = rec.timestamp,
                  let date = parseDate(tsString),
                  let usage = rec.message?.usage
            else { return }
            if let rid = rec.requestId, !seen.insert(rid).inserted { return }
            // Exclude cache_read: Anthropic's rate limit weighs cache hits
            // almost to nothing, so counting them at face value (they dwarf
            // everything else) inflated the fill far past the real limit. This
            // is closer, though still an estimate — the true cap is model-
            // weighted and account-specific.
            let total = (usage.inputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
                + (usage.outputTokens ?? 0)
            guard total > 0 else { return }
            out.append((date.timeIntervalSince1970, total))
        }
        seenRequestIds = seen
        points = out
        return consumed
    }

    // CC timestamps carry fractional seconds ("…58.054Z"); the plain
    // internet-date formatter rejects those, so try fractional first.
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}

// Gauge header (current 5h window, live countdown) over a strip of
// capacity "tracks" — each is a full-height box (the cap) filled from
// the bottom by usage, coloured green→amber→red by fill ratio.
final class LimitChartView: NSView {
    var data = LimitData() { didSet { needsDisplay = true } }
    // Shown while the (slow, ~35-day) window reconstruction is running, so
    // the view doesn't read as "no usage" before the data lands.
    var loading = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static let labelFont = NSFont.systemFont(ofSize: 10)
    private static let tickFont = NSFont.systemFont(ofSize: 9)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        if loading {
            let s = NSAttributedString(string: "Computing…", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
            return
        }

        let pad: CGFloat = 8
        let gaugeH: CGFloat = 16

        // Real, server-reported percentages when the integration is on;
        // otherwise the gauges fall back to the token estimate and a
        // warning is shown.
        let real = LimitChart.realLimits()
        let cap5h = LimitChart.cap(forHistory: data.windows5h, override: LimitChart.cap5hOverride)
        let capWk = LimitChart.cap(forHistory: data.weekly, override: LimitChart.capWeeklyOverride)
        let gap: CGFloat = 18
        let gaugeW = (bounds.width - 2 * pad - gap) / 2
        let rowY = pad
        drawGauge(label: "5h", bucket: data.current5h, cap: cap5h,
                  realPercent: real?.fiveHour,
                  in: NSRect(x: pad, y: rowY, width: gaugeW, height: gaugeH))
        drawGauge(label: "Week", bucket: data.currentWeekly, cap: capWk,
                  realPercent: real?.sevenDay,
                  in: NSRect(x: pad + gaugeW + gap, y: rowY, width: gaugeW, height: gaugeH))

        var y = rowY + gaugeH + 6

        // Estimate warning when we have no authoritative numbers.
        if real == nil {
            drawText("Estimate — exact limits appear after a Claude Code session runs",
                     at: NSPoint(x: pad, y: y),
                     font: Self.tickFont, color: LimitChart.fillColor(0.7))
            y += 14
        }
        y += 4

        // Below: the capacity-track history of 5h windows.
        let tracksRect = NSRect(x: pad, y: y,
                                width: bounds.width - 2 * pad,
                                height: bounds.maxY - y - pad)
        if tracksRect.height > 24 {
            drawTracks(data.windows5h, cap: cap5h.value, in: tracksRect)
        }
    }

    private func drawGauge(label: String, bucket: LimitBucket?,
                           cap: (value: Int64, isAuto: Bool), realPercent: Double?,
                           in rect: NSRect) {
        let labelW: CGFloat = 34
        let barW: CGFloat = min(120, max(40, rect.width * 0.32))
        let used = bucket?.tokens ?? 0
        let ratio: Double = realPercent.map { min(1.0, $0 / 100) }
            ?? min(1.0, Double(used) / Double(max(cap.value, 1)))
        let textY = rect.minY + (rect.height - 12) / 2

        // Label.
        drawText(label, at: NSPoint(x: rect.minX, y: textY),
                 font: Self.labelFont, color: .secondaryLabelColor)

        // Track + fill.
        let track = NSRect(x: rect.minX + labelW, y: rect.minY, width: barW, height: rect.height)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        trackPath.fill()
        if ratio > 0 {
            let fill = NSRect(x: track.minX, y: track.minY,
                              width: max(rect.height, track.width * CGFloat(ratio)), height: rect.height)
            let fillPath = NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2)
            LimitChart.fillColor(ratio).setFill()
            fillPath.fill()
        }

        // Text to the right: percent (· used/cap when estimated) · reset.
        var text = "\(Int(ratio * 100))%"
        if realPercent == nil {
            let capStr = (cap.isAuto ? "~" : "") + Self.fmtTokens(cap.value)
            text += "  ·  \(Self.fmtTokens(used)) / \(capStr)"
        }
        if let b = bucket, b.end > Date() {
            text += "  ·  " + Self.fmtRemaining(b.end)
        } else if realPercent == nil {
            text += "  ·  idle"
        }
        let textRect = NSRect(x: track.maxX + 8, y: textY,
                              width: max(0, rect.maxX - track.maxX - 8), height: 14)
        drawText(text, in: textRect, font: Self.labelFont, color: .secondaryLabelColor)
    }

    // Waterfall (à la Chrome's Network tab): one horizontal row per 5h
    // session, positioned along a shared time axis (the selected chart
    // window). Each row is a faint full-span track with a filled portion
    // = usage / cap, coloured green→amber→red.
    private func drawTracks(_ history: [LimitBucket], cap: Int64, in rect: NSRect) {
        guard !history.isEmpty else {
            drawText("No window data yet",
                     at: NSPoint(x: rect.minX, y: rect.midY - 6),
                     font: Self.labelFont, color: .tertiaryLabelColor)
            return
        }
        let labelH: CGFloat = 12
        let plot = NSRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height - labelH)

        // Time axis = the selected chart window.
        let now = Date().timeIntervalSince1970
        let days = max(1, TokenChartView.windowDays)
        let tMin = now - Double(days) * 24 * 3600
        let span = max(now - tMin, 1)
        func x(_ ts: TimeInterval) -> CGFloat {
            plot.minX + CGFloat((ts - tMin) / span) * plot.width
        }

        // Hour/date guides + labels, matching the main token chart.
        drawTimeAxis(in: plot, days: days, windowEnd: now, windowSeconds: span)

        // One row per session; keep the most recent that fit.
        let minRow: CGFloat = 3
        let maxRows = max(1, Int(plot.height / minRow))
        let shown = Array(history.suffix(maxRows))
        let rowH = min(plot.height / CGFloat(shown.count), 16)
        let barH = max(2, rowH - 2)

        for (i, b) in shown.enumerated() {
            // isFlipped → row 0 sits at the top.
            let y = plot.minY + CGFloat(i) * rowH
            let x0 = max(plot.minX, x(b.start.timeIntervalSince1970))
            let x1 = min(plot.maxX, x(b.end.timeIntervalSince1970))
            let track = NSRect(x: x0, y: y, width: max(2, x1 - x0), height: barH)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()

            let ratio = min(1.0, Double(b.tokens) / Double(max(cap, 1)))
            guard ratio > 0 else { continue }
            let fill = NSRect(x: x0, y: y,
                              width: max(barH, track.width * CGFloat(ratio)), height: barH)
            LimitChart.fillColor(ratio).withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
        }

    }

    // Vertical hour/date guides + axis labels over the waterfall plot,
    // mirroring TokenChartView's x-axis: a tick every few hours back
    // from now (spacing widens with the window), midnight ticks show the
    // date and a stronger guide. (isFlipped → y grows downward.)
    private func drawTimeAxis(in plot: NSRect, days: Int,
                             windowEnd nowEpoch: TimeInterval, windowSeconds: TimeInterval) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.tickFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.tickFont, .foregroundColor: NSColor.labelColor,
        ]
        let config = TokenChartView.WindowConfig(days: days)
        let tickHours = config.tickHours
        let cal = Calendar.current
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("MMMd")

        let now = Date(timeIntervalSince1970: nowEpoch)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        let snappedHour = (comps.hour ?? 0) / tickHours * tickHours
        var snapped = cal.date(from: DateComponents(
            year: comps.year, month: comps.month, day: comps.day, hour: snappedHour)) ?? now
        let windowStart = now.addingTimeInterval(-windowSeconds)

        while snapped >= windowStart {
            let frac = 1.0 - now.timeIntervalSince(snapped) / windowSeconds
            let x = plot.minX + plot.width * CGFloat(frac)
            let hour = cal.component(.hour, from: snapped)
            let isMidnight = hour == 0

            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: x, y: plot.minY))
            guide.line(to: CGPoint(x: x, y: plot.maxY))
            guide.lineWidth = 0.5
            if isMidnight {
                NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.10).setStroke()
            }
            guide.stroke()

            let label = isMidnight ? df.string(from: snapped) : String(format: "%02d:00", hour)
            let str = NSAttributedString(string: label, attributes: isMidnight ? dateAttrs : attrs)
            let sz = str.size()
            var lx = x - sz.width / 2
            lx = max(plot.minX - 4, min(plot.maxX - sz.width + 4, lx))
            str.draw(at: NSPoint(x: lx, y: plot.maxY + 2))

            guard let next = config.previousTick(before: snapped, calendar: cal) else { break }
            snapped = next
        }
    }

    private func drawText(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            .draw(at: p)
    }

    private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
        ]).draw(in: rect)
    }

    static func fmtTokens(_ n: Int64) -> String {
        let d = Double(n)
        if d < 1_000 { return "\(n)" }
        if d < 1_000_000 { return String(format: "%.0fK", d / 1_000) }
        if d < 1_000_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        return String(format: "%.1fB", d / 1_000_000_000)
    }

    static func fmtRemaining(_ end: Date) -> String {
        let s = Int(end.timeIntervalSinceNow)
        guard s > 0 else { return "resetting…" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }
}
