import AppKit
import Foundation

// Compact stacked bar chart of total tokens consumed across every
// session over the last 2 days, bucketed into 15-minute columns.
//
// Each session is mapped to one of 20 distinct hand-picked colours
// (Tableau-20 palette) via a deterministic hash of its sessionId, so
// the same session always renders in the same colour across runs.
// Within each 15-minute bucket the per-session counts are stacked
// from bottom up, sorted by per-session contribution descending — the
// largest contributor in a bucket sits at the bottom.
//
// Computation walks Claude transcripts and Codex rollout files line-by-line,
// then adds (input + cache_creation + cache_read + output) tokens to the right
// bucket / session pair.
// The walk runs on a utility queue, kicked once per window-open;
// the result is held in the view until the window closes (or the
// user hits the reindex button).

final class TokenChartView: NSView {
    // The chart window is user-configurable (Settings → Chart Window).
    // Bucket duration scales with the window so the column count stays
    // in the ~100–250 range, and tick spacing widens so axis labels
    // don't collide.
    nonisolated struct WindowConfig {
        let days: Int
        // 0 = auto: bucket duration scales with the window (below).
        // Anything else is a user-picked bar size (Settings → Chart Bars).
        var barSeconds: TimeInterval = 0
        var windowSeconds: TimeInterval { TimeInterval(days) * 24 * 3600 }
        var bucketSeconds: TimeInterval {
            if barSeconds > 0 { return barSeconds }
            switch days {
            case ...2: return 15 * 60   // 1d → 96, 2d → 192 columns
            case ...5: return 30 * 60   // 5d → 240 columns
            default:   return 60 * 60   // 7d → 168 columns
            }
        }
        var bucketCount: Int { Int(windowSeconds / bucketSeconds) }
        var tickHours: Int {
            switch days {
            case 1:  return 2
            case 2:  return 4
            default: return 12
            }
        }
    }

    nonisolated static let windowDayChoices = [1, 2, 5, 7]
    nonisolated private static let windowDaysKey = "chartWindowDays"
    nonisolated static var windowDays: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: windowDaysKey)
            return windowDayChoices.contains(stored) ? stored : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: windowDaysKey) }
    }

    nonisolated static let barChoices: [(title: String, seconds: TimeInterval)] = [
        ("Auto", 0), ("5 min", 5 * 60), ("15 min", 15 * 60), ("1 hour", 60 * 60),
    ]
    nonisolated private static let barSecondsKey = "chartBarSeconds"
    nonisolated static var barSeconds: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: barSecondsKey)
            return barChoices.contains { $0.seconds == stored } ? stored : 0
        }
        set { UserDefaults.standard.set(newValue, forKey: barSecondsKey) }
    }

    nonisolated private static func currentConfig() -> WindowConfig {
        WindowConfig(days: windowDays, barSeconds: barSeconds)
    }

    // Snapshot of the config the current buckets were computed with —
    // keeps drawing consistent if the setting changes while an async
    // recompute is still in flight (a stale completion is dropped by
    // the count guard in setBuckets).
    private var config = TokenChartView.currentConfig()

    struct BucketData {
        var bySession: [String: Int64] = [:]
        var bySessionCost: [String: Double] = [:]
        var bySessionAdded: [String: Int64] = [:]
        var bySessionRemoved: [String: Int64] = [:]
        var total: Int64 = 0
        var totalCost: Double = 0
        var totalAdded: Int64 = 0
        var totalRemoved: Int64 = 0
        mutating func add(sessionId: String, tokens: Int64, cost: Double,
                          linesAdded: Int64, linesRemoved: Int64) {
            if tokens > 0 {
                bySession[sessionId, default: 0] &+= tokens
                total &+= tokens
            }
            if cost > 0 {
                bySessionCost[sessionId, default: 0] += cost
                totalCost += cost
            }
            if linesAdded > 0 {
                bySessionAdded[sessionId, default: 0] &+= linesAdded
                totalAdded &+= linesAdded
            }
            if linesRemoved > 0 {
                bySessionRemoved[sessionId, default: 0] &+= linesRemoved
                totalRemoved &+= linesRemoved
            }
        }
    }

    // What the bars measure: raw token counts, their USD cost, or
    // lines of code added/removed (green up / red down). All metrics
    // are carried in every BucketData, so flipping the mode is a pure
    // redraw — no recompute, no file I/O.
    enum ValueMode: String {
        case tokens
        case cost
        case lines
    }

    private static let modeKey = "chartValueMode"
    private var mode: ValueMode =
        ValueMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .tokens

    // The toolbar's segmented control (owned by MainWindowController)
    // drives this; the choice persists across launches.
    var valueMode: ValueMode {
        get { mode }
        set {
            guard mode != newValue else { return }
            mode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
            needsDisplay = true
        }
    }

    private var buckets: [BucketData] =
        Array(repeating: BucketData(), count: TokenChartView.currentConfig().bucketCount)
    private var windowEnd: Date = .distantPast
    private var hasData = false
    // When set, all non-matching session segments are drawn at a low
    // alpha so the highlighted session pops. nil = uniform colour.
    var highlightedSessionId: String? {
        didSet {
            guard oldValue != highlightedSessionId else { return }
            needsDisplay = true
        }
    }

    // Rate-limit window starts overlaid as vertical markers: 5h session
    // boundaries (teal) and weekly boundaries (purple). Set by the
    // window controller; each is clipped to the visible range at draw.
    var session5hStarts: [Date] = [] { didSet { needsDisplay = true } }
    var weeklyStarts: [Date] = [] { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setBuckets(_ data: [BucketData], windowEnd: Date = Date()) {
        let cfg = Self.currentConfig()
        guard data.count == cfg.bucketCount else { return }
        self.config = cfg
        self.buckets = data
        self.windowEnd = windowEnd
        self.hasData = true
        needsDisplay = true
    }

    // Switch back to the "Computing…" placeholder until the next
    // setBuckets call lands.
    func reset() {
        self.config = Self.currentConfig()
        self.hasData = false
        self.buckets = Array(repeating: BucketData(), count: config.bucketCount)
        needsDisplay = true
    }

    // MARK: - Palette

    // FNV-1a 64-bit hash → HSB. The hash is deterministic across runs
    // (Swift's String.hashValue is randomised), so the same sessionId
    // always produces the same colour. Mapping to a full 0..360° hue
    // space gives a distinct colour per session instead of bucketing
    // many sessions into a small palette.
    // All temporary (/private) sessions are folded into this one synthetic
    // series when Show Temporary is off — drawn as a single neutral bar that
    // adapts to the theme (near-black in light mode, near-white in dark).
    static let temporaryKey = "__temporary__"
    private static let temporaryColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.78)
            : NSColor(white: 0, alpha: 0.78)
    }

    static func color(for sessionId: String) -> NSColor {
        if sessionId == temporaryKey { return temporaryColor }
        var h: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        // Fixed saturation + brightness keep colours visually balanced
        // (no near-black or near-white anywhere in the palette).
        let hue = CGFloat(h % 3600) / 3600.0
        return NSColor(
            hue: hue,
            saturation: 0.70,
            brightness: 0.80,
            alpha: 1.0
        )
    }

    // MARK: - Layout / axes

    private static let leftMargin: CGFloat = 44
    private static let rightMargin: CGFloat = 6
    private static let topMargin: CGFloat = 6
    private static let bottomMargin: CGFloat = 16

    // Each 5h session window is shaded as a faint, semi-transparent
    // grey band (adaptive: a touch of black in light mode, of white in
    // dark) rather than a marker line.
    private static let session5hBandColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0, alpha: 0.06)
    }
    private static let tickFont = NSFont.systemFont(ofSize: 9)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let plotRect = NSRect(
            x: Self.leftMargin,
            y: Self.bottomMargin,
            width: bounds.width - Self.leftMargin - Self.rightMargin,
            height: bounds.height - Self.topMargin - Self.bottomMargin
        )
        guard plotRect.width > 30 && plotRect.height > 20 else { return }

        // Axis lines: bottom (X) + left (Y).
        ctx.saveGState()
        NSColor.separatorColor.setStroke()
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY + 0.5))
        ctx.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.minY + 0.5))
        ctx.move(to: CGPoint(x: plotRect.minX + 0.5, y: plotRect.minY))
        ctx.addLine(to: CGPoint(x: plotRect.minX + 0.5, y: plotRect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        drawXAxisLabels(in: plotRect)

        if !hasData {
            drawPlaceholder(in: plotRect)
            return
        }

        if mode == .lines {
            drawLinesChart(in: plotRect)
            return
        }

        let maxValue = buckets.map { bucketTotal($0) }.max() ?? 0
        guard maxValue > 0 else {
            drawPlaceholder(in: plotRect, text: mode == .cost
                ? "No spend in the last \(windowLabel)"
                : "No tokens in the last \(windowLabel)")
            return
        }

        drawYAxisLabels(in: plotRect, maxValue: maxValue)
        drawStackedBars(in: plotRect, maxValue: maxValue)
    }

    // Diverging bar chart for the lines mode: added lines stack up
    // in green from a zero baseline, removed lines stack down in red.
    // The baseline splits the plot proportionally to the two maxima,
    // so both directions share one scale and neither half is wasted.
    private func drawLinesChart(in plotRect: NSRect) {
        let maxAdded = buckets.map(\.totalAdded).max() ?? 0
        let maxRemoved = buckets.map(\.totalRemoved).max() ?? 0
        guard maxAdded > 0 || maxRemoved > 0 else {
            drawPlaceholder(in: plotRect, text: "No code changes in the last \(windowLabel)")
            return
        }

        // Markers first → bars paint over them (lines sit under bars).
        drawWindowMarkers(in: plotRect)

        let gap: CGFloat = 1
        let slot = plotRect.width / CGFloat(buckets.count)
        let barWidth = max(1, slot - gap)
        let pad: CGFloat = 2
        let scale = (plotRect.height - pad * 2) / CGFloat(maxAdded + maxRemoved)
        let baselineY = plotRect.minY + pad + CGFloat(maxRemoved) * scale

        // Zero line.
        NSColor.separatorColor.setStroke()
        let zero = NSBezierPath()
        zero.move(to: CGPoint(x: plotRect.minX, y: baselineY))
        zero.line(to: CGPoint(x: plotRect.maxX, y: baselineY))
        zero.lineWidth = 1
        zero.stroke()

        let highlighted = highlightedSessionId
        let mutedAlpha: CGFloat = 0.18
        let green = Theme.diffAdded
        let red = Theme.diffRemoved

        func drawStack(_ values: [String: Int64], from startY: CGFloat,
                       direction: CGFloat, color: NSColor, x: CGFloat) {
            // Highlighted session sits against the baseline; the rest
            // sort largest-first, mirroring the token stack.
            let sorted = values.sorted { a, b in
                if let hl = highlighted {
                    if a.key == hl && b.key != hl { return true }
                    if b.key == hl && a.key != hl { return false }
                }
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }
            var y = startY
            for (sessionId, count) in sorted {
                let h = max(1, CGFloat(count) * scale)
                let isHighlighted = highlighted == nil || sessionId == highlighted
                (isHighlighted ? color : color.withAlphaComponent(mutedAlpha)).setFill()
                let rect = direction > 0
                    ? NSRect(x: x, y: y, width: barWidth, height: h)
                    : NSRect(x: x, y: y - h, width: barWidth, height: h)
                rect.fill()
                y += direction * h
            }
        }

        for (i, bucket) in buckets.enumerated() {
            guard bucket.totalAdded > 0 || bucket.totalRemoved > 0 else { continue }
            let x = plotRect.minX + CGFloat(i) * slot
            if bucket.totalAdded > 0 {
                drawStack(bucket.bySessionAdded, from: baselineY,
                          direction: 1, color: green, x: x)
            }
            if bucket.totalRemoved > 0 {
                drawStack(bucket.bySessionRemoved, from: baselineY,
                          direction: -1, color: red, x: x)
            }
        }

        // Axis extremes: +max in green up top, −max in red at the
        // bottom, both against the left margin like the other modes.
        func drawAxisLabel(_ text: String, color: NSColor, y: CGFloat) {
            let str = NSAttributedString(string: text, attributes: [
                .font: Self.tickFont,
                .foregroundColor: color,
            ])
            let sz = str.size()
            str.draw(at: NSPoint(x: plotRect.minX - sz.width - 4, y: y))
        }
        if maxAdded > 0 {
            drawAxisLabel("+\(Self.formatTokenCount(maxAdded))",
                          color: green, y: plotRect.maxY - 10)
        }
        if maxRemoved > 0 {
            drawAxisLabel("−\(Self.formatTokenCount(maxRemoved))",
                          color: red, y: plotRect.minY - 1)
        }
    }

    // Each 5h session window is shaded as a faint grey band spanning
    // [start, start + 5h) — drawn under the bars as a background region
    // rather than a marker line. (Weekly starts aren't shaded: a 7-day
    // band would cover the whole view.)
    private func drawWindowMarkers(in plotRect: NSRect) {
        guard !session5hStarts.isEmpty else { return }
        let now = windowEnd == .distantPast ? Date() : windowEnd
        let nowEpoch = now.timeIntervalSince1970
        let windowStartEpoch = nowEpoch - config.windowSeconds

        func x(_ ts: TimeInterval) -> CGFloat {
            let clamped = min(max(ts, windowStartEpoch), nowEpoch)
            let frac = (clamped - windowStartEpoch) / config.windowSeconds
            return plotRect.minX + plotRect.width * CGFloat(frac)
        }

        let span = LimitChart.session5hSeconds
        Self.session5hBandColor.setFill()
        for start in session5hStarts {
            let s = start.timeIntervalSince1970
            guard s + span >= windowStartEpoch, s <= nowEpoch else { continue }
            let x0 = x(s)
            let x1 = x(s + span)
            guard x1 > x0 else { continue }
            NSRect(x: x0, y: plotRect.minY, width: x1 - x0, height: plotRect.height).fill()
        }
    }

    private func bucketTotal(_ bucket: BucketData) -> Double {
        mode == .cost ? bucket.totalCost : Double(bucket.total)
    }

    private func bucketSessionValues(_ bucket: BucketData) -> [String: Double] {
        mode == .cost ? bucket.bySessionCost : bucket.bySession.mapValues(Double.init)
    }

    private var windowLabel: String {
        config.days == 1 ? "24 hours" : "\(config.days) days"
    }

    private func drawStackedBars(in plotRect: NSRect, maxValue: Double) {
        // Markers first → the bars paint over the lines (lines sit under
        // the bars; the baseline notches stay visible below them).
        drawWindowMarkers(in: plotRect)

        let count = buckets.count
        let gap: CGFloat = 1
        let slot = plotRect.width / CGFloat(count)
        let barWidth = max(1, slot - gap)
        let topPadding: CGFloat = 2
        let scale = (plotRect.height - topPadding) / CGFloat(maxValue)

        let highlighted = highlightedSessionId
        // When highlighting one session, mute everything else.
        let mutedAlpha: CGFloat = 0.18
        for (i, bucket) in buckets.enumerated() {
            guard bucketTotal(bucket) > 0 else { continue }
            // Sort so the highlighted session lands at the bottom
            // of the stack (visually grounded against the baseline).
            // Otherwise fall back to "largest contributor at bottom".
            let sorted = bucketSessionValues(bucket).sorted { a, b in
                if let hl = highlighted {
                    if a.key == hl && b.key != hl { return true }
                    if b.key == hl && a.key != hl { return false }
                }
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }
            let x = plotRect.minX + CGFloat(i) * slot
            var y = plotRect.minY + 1
            for (sessionId, value) in sorted {
                let h = max(1, CGFloat(value) * scale)
                let isHighlighted = highlighted == nil || sessionId == highlighted
                let color = isHighlighted
                    ? Self.color(for: sessionId)
                    : Self.color(for: sessionId).withAlphaComponent(mutedAlpha)
                color.setFill()
                NSRect(x: x, y: y, width: barWidth, height: h).fill()
                y += h
            }
        }
    }

    // X axis: tick every config.tickHours back from `now`. Each tick
    // gets a short tick mark below the axis line; the label is the
    // HH:00 time-of-day, except midnight ticks which show the
    // locale-aware date instead so day transitions are spelled out.
    //
    // Vertical guides are drawn through the plot at every tick:
    //   - intraday ticks: barely-there solid line
    //   - midnight ticks: solid, prominent line
    private func drawXAxisLabels(in plotRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.tickFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.tickFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let now = windowEnd == .distantPast ? Date() : windowEnd
        let cal = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMd")

        // Snap the rightmost tick down to the nearest tick boundary
        // so the grid is regular even when "now" is at e.g. 13:47.
        let tickHours = config.tickHours
        let nowComponents = cal.dateComponents([.year, .month, .day, .hour], from: now)
        let snappedHour = (nowComponents.hour ?? 0) / tickHours * tickHours
        var snapped = cal.date(from: DateComponents(
            year: nowComponents.year, month: nowComponents.month,
            day: nowComponents.day, hour: snappedHour
        )) ?? now

        let windowStart = now.addingTimeInterval(-config.windowSeconds)
        while snapped >= windowStart {
            let secondsAgo = now.timeIntervalSince(snapped)
            let frac = 1.0 - secondsAgo / config.windowSeconds
            let x = plotRect.minX + plotRect.width * CGFloat(frac)

            // Tick mark below the axis line.
            NSColor.separatorColor.setStroke()
            let tickPath = NSBezierPath()
            tickPath.move(to: CGPoint(x: x, y: plotRect.minY))
            tickPath.line(to: CGPoint(x: x, y: plotRect.minY - 3))
            tickPath.lineWidth = 1
            tickPath.stroke()

            let hour = cal.component(.hour, from: snapped)
            let isMidnight = (hour == 0)

            // Vertical guide.
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: x, y: plotRect.minY))
            guide.line(to: CGPoint(x: x, y: plotRect.maxY))
            guide.lineWidth = 0.5
            if isMidnight {
                NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.10).setStroke()
            }
            guide.stroke()

            let label: String
            let labelAttrs: [NSAttributedString.Key: Any]
            if isMidnight {
                label = dateFormatter.string(from: snapped)
                labelAttrs = dateAttrs
            } else {
                label = String(format: "%02d:00", hour)
                labelAttrs = attrs
            }
            let str = NSAttributedString(string: label, attributes: labelAttrs)
            let sz = str.size()
            var labelX = x - sz.width / 2
            labelX = max(plotRect.minX - 4, min(plotRect.maxX - sz.width + 4, labelX))
            str.draw(at: NSPoint(x: labelX, y: plotRect.minY - 13))

            guard let next = cal.date(byAdding: .hour, value: -tickHours, to: snapped) else { break }
            snapped = next
        }
    }

    // Y axis: just a max-value label so the bar scale is legible.
    private func drawYAxisLabels(in plotRect: NSRect, maxValue: Double) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.tickFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = mode == .cost
            ? Self.formatCostLabel(maxValue)
            : Self.formatTokenCount(Int64(maxValue))
        let label = NSAttributedString(string: text, attributes: attrs)
        let sz = label.size()
        label.draw(at: NSPoint(
            x: plotRect.minX - sz.width - 4,
            y: plotRect.maxY - sz.height
        ))
        let zero = NSAttributedString(string: "0", attributes: attrs)
        let zsz = zero.size()
        zero.draw(at: NSPoint(
            x: plotRect.minX - zsz.width - 4,
            y: plotRect.minY - 1
        ))
    }

    private func drawPlaceholder(in area: NSRect, text: String = "Computing…") {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(
            x: area.minX + (area.width - size.width) / 2,
            y: area.minY + (area.height - size.height) / 2
        ))
    }

    private static func formatTokenCount(_ n: Int64) -> String {
        let d = Double(n)
        if d < 1_000 { return "\(n)" }
        if d < 1_000_000 { return String(format: "%.0fK", d / 1_000) }
        if d < 1_000_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        return String(format: "%.1fB", d / 1_000_000_000)
    }

    private static func formatCostLabel(_ usd: Double) -> String {
        if usd >= 10 { return String(format: "$%.0f", usd) }
        if usd >= 1 { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    // MARK: - Computation

    nonisolated private struct AssistantRecord: Decodable {
        let timestamp: Date?
        let type: String?
        let sessionId: String?
        // Claude Code emits several assistant records per API call
        // (one per streamed content block), each carrying the same
        // cumulative usage. Count only the first per requestId — same
        // dedupe SessionIndexer.foldUsage does, so the chart totals
        // line up with the table.
        let requestId: String?
        // Claude writes the session's real working directory into every
        // assistant record. It is the same field deepScan trusts, and it is
        // the only exact answer available here: the project directory name it
        // came from is ambiguous (see ClaudeProjectPath), so grouping by the
        // decoded name splits or merges the projects whose own name has a dash.
        let cwd: String?
        let message: Message?
        struct Message: Decodable {
            let model: String?
            let usage: Usage?
            struct Usage: Decodable {
                let inputTokens: Int64?
                let outputTokens: Int64?
                let cacheCreationInputTokens: Int64?
                let cacheReadInputTokens: Int64?
            }
        }
    }

    // Edit / Write tool results: user-type records whose toolUseResult
    // carries a structuredPatch ("update") or fresh file content
    // ("create"). Lines prefixed +/- in the hunks are the add/remove
    // counts; a created file counts every line as added.
    nonisolated private struct PatchRecord: Decodable {
        let timestamp: Date?
        let sessionId: String?
        let toolUseResult: ToolUseResult?
        struct ToolUseResult: Decodable {
            let type: String?          // "update" | "create" | other
            let content: String?
            let structuredPatch: [Hunk]?
            struct Hunk: Decodable {
                let lines: [String]?
            }
        }
    }

    nonisolated private struct CodexChartRecord: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let id: String?
            let cwd: String?
            let model: String?
            let info: TokenInfo?
            struct TokenInfo: Decodable {
                let totalTokenUsage: CodexTokenUsage?
            }
        }
    }

    // One parsed point per record. Cached per file so a window
    // re-open only reads bytes appended since last time instead of
    // re-reading every recent jsonl wholesale. Cost is priced per
    // record from its own model, so a session that switched models
    // mid-flight bills each call at the right rate. Usage points have
    // zero line counts; patch points have zero tokens/cost.
    nonisolated private struct ChartPoint {
        let ts: TimeInterval   // epoch seconds
        let sessionId: String
        let tokens: Int64
        let cost: Double       // USD
        let linesAdded: Int64
        let linesRemoved: Int64
        // Codex records its real cwd in session_meta. Claude points leave this
        // nil because their project directory already supplies it.
        let cwd: String?
    }

    nonisolated private struct CachedFile {
        // Bytes parsed so far (ends on a line boundary). The next
        // compute reads only [parsedSize, EOF).
        var parsedSize: Int64
        var mtime: Date
        var points: [ChartPoint]
        var seenRequestIds: Set<String>
        // Codex usage is cumulative. Preserve the last snapshot and context at
        // the byte cursor so an appended tail can be converted to exact deltas.
        var codexLastUsage: TokenBreakdown?
        var codexModel: String?
        var codexCwd: String?
        var codexSessionId: String?
    }

    // Bucket folding runs on the shared scan queue (WorkScheduler.scanQueue),
    // so it can't walk the transcripts alongside the other background readers.
    // Confined to that serial queue — every read and write happens
    // inside a scanQueue.async block.
    nonisolated(unsafe) private static var fileCache: [String: CachedFile] = [:]

    // Call when the chart-window setting changes: cached cursors have
    // already pruned points older than the previous window, so a
    // longer window has to re-read the files from scratch.
    nonisolated static func flushCache() {
        WorkScheduler.shared.run(.init(id: "chart-flush", priority: .interactive, deferrable: false)) { fileCache.removeAll() }
    }

    // Transform per-bucket (incremental) token data into a running
    // cumulative since the last 5h-session start: at the bucket holding
    // each reset boundary the running totals drop to zero and climb
    // again — a sawtooth showing how much of each 5h session was used.
    // Only token totals are carried (limit mode is token-only).
    static func cumulativeReset(_ buckets: [BucketData],
                                resetBoundaries: [Date],
                                windowEnd: Date) -> [BucketData] {
        let cfg = currentConfig()
        let count = buckets.count
        guard count > 0 else { return buckets }
        let windowStartEpoch = windowEnd.timeIntervalSince1970 - cfg.windowSeconds
        let endEpoch = windowEnd.timeIntervalSince1970

        var resetAt = Set<Int>()
        for d in resetBoundaries {
            let e = d.timeIntervalSince1970
            guard e >= windowStartEpoch, e <= endEpoch else { continue }
            var idx = Int((e - windowStartEpoch) / cfg.bucketSeconds)
            if idx < 0 { idx = 0 }
            if idx >= count { idx = count - 1 }
            resetAt.insert(idx)
        }

        var out: [BucketData] = []
        out.reserveCapacity(count)
        var runBySession: [String: Int64] = [:]
        var runTotal: Int64 = 0
        for i in 0..<count {
            if resetAt.contains(i) {
                runBySession.removeAll(keepingCapacity: true)
                runTotal = 0
            }
            for (s, v) in buckets[i].bySession { runBySession[s, default: 0] &+= v }
            runTotal &+= buckets[i].total
            var nb = BucketData()
            nb.bySession = runBySession
            nb.total = runTotal
            out.append(nb)
        }
        return out
    }

    static func computeBuckets(completion: @escaping ([BucketData], Date) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        let codexSessionsDir = home
            .appending(path: ".codex/sessions", directoryHint: .isDirectory)
        let cfg = currentConfig()
        let bucketSize = cfg.bucketSeconds
        // Anchor the bucket grid to fixed clock boundaries. With windowEnd =
        // "now", windowStart (= now − span) slides every second, so the same
        // records land in different bars on each recompute and past bars
        // visibly grow/shrink (their tokens slosh between neighbours). Snapping
        // the trailing edge up to the next bucket fixes the grid phase: every
        // bar spans the same wall-clock interval between recomputes, and the
        // window advances in clean one-bucket steps. windowSeconds is a whole
        // multiple of bucketSize, so windowStart stays aligned too.
        let snappedEnd = (Date().timeIntervalSince1970 / bucketSize).rounded(.up) * bucketSize
        let windowEnd = Date(timeIntervalSince1970: snappedEnd)
        let windowStart = windowEnd.addingTimeInterval(-cfg.windowSeconds)
        let bucketCount = cfg.bucketCount

        WorkScheduler.shared.run(.init(id: "chart-buckets", priority: .interactive, deferrable: false)) {
            let fm = FileManager.default
            var counts = Array(repeating: BucketData(), count: bucketCount)
            let projectDirs = (try? fm.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil
            )) ?? []

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601

            let windowStartEpoch = windowStart.timeIntervalSince1970
            let windowEndEpoch = windowEnd.timeIntervalSince1970
            var visited: Set<String> = []
            // /private/tmp and /private/var projects are sub-task scratch / e2e
            // test runs. When Show Temporary is off we still count them (they're
            // real spend) but fold them all into one grey "temporary" series so
            // the chart isn't a forest of one-off colours.
            let includeTemporary = UserDefaults.standard.bool(forKey: "showTemporarySessions")
            // When grouping by directory, bars stack & colour per directory
            // (the project cwd) instead of per session — matching the table.
            let groupByDir = UserDefaults.standard.bool(forKey: "groupByDirectory")

            for projectDir in projectDirs {
                // Only for classifying the directory as temporary, and as the
                // fallback group key; the exact cwd comes per-point from the
                // record itself (see AssistantRecord.cwd).
                let cwd = ClaudeProjectPath.decode(projectDir.lastPathComponent)
                let foldTemporary = !includeTemporary
                    && (cwd.hasPrefix("/private/tmp/") || cwd.hasPrefix("/private/var/"))
                guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
                else { continue }
                for jsonl in files where jsonl.pathExtension == "jsonl" {
                  autoreleasepool {
                    // Per-file pool: drain the JSON-decode temporaries from each
                    // transcript rather than holding them all until the scan ends.
                    guard let attrs = try? fm.attributesOfItem(atPath: jsonl.path),
                          let mtime = attrs[.modificationDate] as? Date,
                          let size = (attrs[.size] as? NSNumber)?.int64Value
                    else { return }
                    // Nothing in this file can be newer than its
                    // mtime → no points inside the window. Don't read
                    // it, and let its cache entry fall out below.
                    if mtime < windowStart { return }

                    let path = jsonl.path
                    visited.insert(path)

                    // Fallback sessionId: jsonl basename matches the
                    // session UUID. We still prefer the embedded
                    // sessionId on the record when present.
                    let fallbackSessionId = jsonl.deletingPathExtension().lastPathComponent

                    var cached: CachedFile
                    if let c = fileCache[path], c.parsedSize == size, c.mtime == mtime {
                        // Unchanged since last compute — no I/O at all.
                        cached = c
                    } else if var c = fileCache[path], size > c.parsedSize {
                        // File grew — parse only the appended tail. parsePoints
                        // returns the absolute offset it parsed up to.
                        c.parsedSize = parseClaudePoints(
                            at: jsonl, fromOffset: c.parsedSize,
                            decoder: decoder, fallbackSessionId: fallbackSessionId,
                            notBefore: windowStartEpoch,
                            seenRequestIds: &c.seenRequestIds, into: &c.points
                        )
                        c.mtime = mtime
                        cached = c
                    } else {
                        // New file, or rewritten/truncated → full parse.
                        var c = CachedFile(
                            parsedSize: 0, mtime: mtime, points: [],
                            seenRequestIds: [], codexLastUsage: nil,
                            codexModel: nil, codexCwd: nil, codexSessionId: nil
                        )
                        let consumed = parseClaudePoints(
                            at: jsonl, fromOffset: 0,
                            decoder: decoder, fallbackSessionId: fallbackSessionId,
                            notBefore: windowStartEpoch,
                            seenRequestIds: &c.seenRequestIds, into: &c.points
                        )
                        c.parsedSize = consumed
                        cached = c
                    }

                    // The window only ever moves forward — points that
                    // fell off its left edge are dead weight.
                    cached.points.removeAll { $0.ts < windowStartEpoch }
                    fileCache[path] = cached

                    for point in cached.points {
                        guard point.ts <= windowEndEpoch else { continue }
                        var idx = Int((point.ts - windowStartEpoch) / bucketSize)
                        if idx < 0 { idx = 0 }
                        if idx >= bucketCount { idx = bucketCount - 1 }
                        // Group by the cwd the record itself carried; the
                        // directory-derived one is only the fallback for a
                        // record that predates the field.
                        let key = foldTemporary ? Self.temporaryKey
                            : (groupByDir ? (point.cwd ?? cwd) : point.sessionId)
                        counts[idx].add(sessionId: key,
                                        tokens: point.tokens,
                                        cost: point.cost,
                                        linesAdded: point.linesAdded,
                                        linesRemoved: point.linesRemoved)
                    }
                  }
                }
            }

            // Codex stores rollouts by date rather than project directory. Its
            // token_count records are cumulative, so parseCodexPoints turns
            // each new snapshot into a per-response delta before bucketing it.
            if let enumerator = fm.enumerator(
                at: codexSessionsDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) {
                while let jsonl = enumerator.nextObject() as? URL {
                    guard jsonl.pathExtension == "jsonl",
                          jsonl.lastPathComponent.hasPrefix("rollout-")
                    else { continue }
                    autoreleasepool {
                        guard let attrs = try? fm.attributesOfItem(atPath: jsonl.path),
                              let mtime = attrs[.modificationDate] as? Date,
                              let size = (attrs[.size] as? NSNumber)?.int64Value,
                              mtime >= windowStart
                        else { return }

                        let path = jsonl.path
                        visited.insert(path)
                        let basename = jsonl.deletingPathExtension().lastPathComponent
                        let fallbackSessionId = basename.count >= 36
                            ? String(basename.suffix(36)) : basename

                        var cached: CachedFile
                        if let c = fileCache[path], c.parsedSize == size, c.mtime == mtime {
                            cached = c
                        } else if var c = fileCache[path], size > c.parsedSize {
                            c.parsedSize = parseCodexPoints(
                                at: jsonl, fromOffset: c.parsedSize,
                                decoder: decoder, fallbackSessionId: fallbackSessionId,
                                notBefore: windowStartEpoch, cache: &c
                            )
                            c.mtime = mtime
                            cached = c
                        } else {
                            var c = CachedFile(
                                parsedSize: 0, mtime: mtime, points: [],
                                seenRequestIds: [], codexLastUsage: nil,
                                codexModel: nil, codexCwd: nil, codexSessionId: nil
                            )
                            c.parsedSize = parseCodexPoints(
                                at: jsonl, fromOffset: 0,
                                decoder: decoder, fallbackSessionId: fallbackSessionId,
                                notBefore: windowStartEpoch, cache: &c
                            )
                            cached = c
                        }

                        cached.points.removeAll { $0.ts < windowStartEpoch }
                        fileCache[path] = cached
                        for point in cached.points where point.ts <= windowEndEpoch {
                            var idx = Int((point.ts - windowStartEpoch) / bucketSize)
                            if idx < 0 { idx = 0 }
                            if idx >= bucketCount { idx = bucketCount - 1 }
                            let cwd = point.cwd ?? cached.codexCwd ?? "Codex"
                            let foldTemporary = !includeTemporary
                                && (cwd.hasPrefix("/private/tmp/") || cwd.hasPrefix("/private/var/"))
                            let key = foldTemporary ? Self.temporaryKey
                                : (groupByDir ? cwd : point.sessionId)
                            counts[idx].add(
                                sessionId: key, tokens: point.tokens, cost: point.cost,
                                linesAdded: point.linesAdded, linesRemoved: point.linesRemoved
                            )
                        }
                    }
                }
            }

            // Deleted files / files whose mtime left the window.
            fileCache = fileCache.filter { visited.contains($0.key) }

            DispatchQueue.main.async { completion(counts, windowEnd) }
        }
    }

    // Streams the jsonl from `offset` line-by-line into ChartPoints and
    // returns the absolute offset parsed up to (past the last complete line).
    // A trailing partial line is left for the next pass (the writer mid-append).
    nonisolated private static func parseClaudePoints(
        at url: URL, fromOffset offset: Int64,
        decoder: JSONDecoder, fallbackSessionId: String,
        notBefore windowStartEpoch: TimeInterval,
        seenRequestIds: inout Set<String>, into points: inout [ChartPoint]
    ) -> Int64 {
        let assistantSig = "\"type\":\"assistant\"".data(using: .utf8)!
        let patchSig = "\"structuredPatch\"".data(using: .utf8)!

        func foldUsage(_ lineData: Data) {
            guard let rec = try? decoder.decode(AssistantRecord.self, from: lineData),
                  let ts = rec.timestamp,
                  let usage = rec.message?.usage else { return }
            if let rid = rec.requestId, !seenRequestIds.insert(rid).inserted { return }
            let epoch = ts.timeIntervalSince1970
            // Skip points that already pre-date the window — they'd
            // be pruned immediately anyway.
            guard epoch >= windowStartEpoch else { return }
            let input = usage.inputTokens ?? 0
            let cacheWrite = usage.cacheCreationInputTokens ?? 0
            let cacheRead = usage.cacheReadInputTokens ?? 0
            let output = usage.outputTokens ?? 0
            let total = input + cacheWrite + cacheRead + output
            guard total > 0 else { return }
            // Same pricing source as the table's Cost column, so the
            // two views agree.
            let p = SessionIndex.pricing(for: rec.message?.model)
            let cost = (Double(input) * p.input
                + Double(cacheWrite) * p.cacheWrite
                + Double(cacheRead) * p.cacheRead
                + Double(output) * p.output) / 1_000_000
            points.append(ChartPoint(
                ts: epoch,
                sessionId: rec.sessionId ?? fallbackSessionId,
                tokens: total,
                cost: cost,
                linesAdded: 0,
                linesRemoved: 0,
                cwd: rec.cwd
            ))
        }

        func foldPatch(_ lineData: Data) {
            guard let rec = try? decoder.decode(PatchRecord.self, from: lineData),
                  let ts = rec.timestamp,
                  let result = rec.toolUseResult else { return }
            let epoch = ts.timeIntervalSince1970
            guard epoch >= windowStartEpoch else { return }
            var added: Int64 = 0
            var removed: Int64 = 0
            switch result.type {
            case "update":
                for hunk in result.structuredPatch ?? [] {
                    for line in hunk.lines ?? [] {
                        if line.hasPrefix("+") { added += 1 }
                        else if line.hasPrefix("-") { removed += 1 }
                    }
                }
            case "create":
                // A fresh file: every line of the written content is
                // an addition.
                if let content = result.content, !content.isEmpty {
                    added = Int64(content.utf8.lazy.filter { $0 == 0x0a }.count) + 1
                }
            default:
                // "text" (Read echoes), "file_unchanged", bash output
                // that merely mentions structuredPatch, etc.
                return
            }
            guard added > 0 || removed > 0 else { return }
            points.append(ChartPoint(
                ts: epoch,
                sessionId: rec.sessionId ?? fallbackSessionId,
                tokens: 0,
                cost: 0,
                linesAdded: added,
                linesRemoved: removed,
                cwd: nil
            ))
        }

        func fold(_ lineData: Data) {
            if lineData.range(of: assistantSig) != nil {
                foldUsage(lineData)
            } else if lineData.range(of: patchSig) != nil {
                foldPatch(lineData)
            }
        }

        // Stream complete lines from the cursor; the returned offset (past the
        // last full line) becomes the new cursor. A trailing partial line — the
        // writer mid-append — is left for the next pass.
        return JSONLReader.stream(at: url, from: offset) { fold($0) }
    }

    // Streams Codex records from the cached byte cursor. session_meta and
    // turn_context are retained as parser state; cumulative token snapshots
    // are converted to deltas so repeated snapshots are naturally ignored.
    nonisolated private static func parseCodexPoints(
        at url: URL, fromOffset offset: Int64,
        decoder: JSONDecoder, fallbackSessionId: String,
        notBefore windowStartEpoch: TimeInterval,
        cache: inout CachedFile
    ) -> Int64 {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        return JSONLReader.stream(at: url, from: offset) { lineData in
            guard let rec = try? decoder.decode(CodexChartRecord.self, from: lineData),
                  let payload = rec.payload else { return }
            switch rec.type {
            case "session_meta":
                if let id = payload.id, !id.isEmpty { cache.codexSessionId = id }
                if let cwd = payload.cwd, !cwd.isEmpty { cache.codexCwd = cwd }
            case "turn_context":
                if let model = payload.model, !model.isEmpty {
                    cache.codexModel = model.hasPrefix("openai-") ? model : "openai-\(model)"
                }
            case "event_msg":
                guard payload.type == "token_count",
                      let usage = payload.info?.totalTokenUsage else { return }
                let current = usage.breakdown
                let previous = cache.codexLastUsage ?? .zero
                let didReset = current.input < previous.input
                    || current.cacheWrite < previous.cacheWrite
                    || current.cacheRead < previous.cacheRead
                    || current.output < previous.output
                let delta = didReset ? current : current.subtractingClamped(previous)
                cache.codexLastUsage = current
                guard delta.total > 0,
                      let stamp = rec.timestamp,
                      let date = isoFractional.date(from: stamp) ?? isoPlain.date(from: stamp)
                else { return }
                let epoch = date.timeIntervalSince1970
                guard epoch >= windowStartEpoch else { return }

                let p = SessionIndex.pricing(for: cache.codexModel)
                let cost = (Double(delta.input) * p.input
                    + Double(delta.cacheWrite) * p.cacheWrite
                    + Double(delta.cacheRead) * p.cacheRead
                    + Double(delta.output) * p.output) / 1_000_000
                cache.points.append(ChartPoint(
                    ts: epoch,
                    sessionId: cache.codexSessionId ?? fallbackSessionId,
                    tokens: delta.total,
                    cost: cost,
                    linesAdded: 0,
                    linesRemoved: 0,
                    cwd: cache.codexCwd
                ))
            default:
                break
            }
        }
    }
}
