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

    // MARK: - Time-range brush

    // Dragging across the chart asks "who was working then". This is the only
    // time axis over the whole fleet, so the answer comes from the buckets
    // already drawn rather than from any new scan: a session is in the range
    // if it billed tokens in a bucket the range touches, which is exactly the
    // segments the drag covered.
    struct Selection {
        let range: ClosedRange<Date>
        let sessionIds: Set<String>
    }

    // Called on every committed change: a finished drag, an edge move, or a
    // click that clears (nil).
    var onSelectionChange: ((Selection?) -> Void)?

    // A click on the chart that was not a drag. Kept separate from
    // onSelectionChange(nil), which also fires when the range is dropped for
    // reasons the user did not click for — switching the chart away from
    // tokens, say. Only the click means "clear what I am looking through",
    // and only it should reach the table's selection.
    var onBackgroundClick: (() -> Void)?

    // Buckets are keyed by session id (or by cwd when grouping by directory),
    // and neither is readable. The controller owns the index, so it names them;
    // an unknown key falls back to itself rather than vanishing from the list.
    var seriesLabel: ((String) -> String)?

    private(set) var selection: ClosedRange<Date>?
    // Live drag state, in epoch seconds; nil when not dragging.
    private var dragAnchor: TimeInterval?
    private var dragCurrent: TimeInterval?
    private var dragStartX: CGFloat?
    // Whether the press has travelled far enough to count as a range drag.
    // Until it has, the in-flight range is held but never drawn.
    private var dragArmed = false
    // A drag shorter than this is a click, and a click clears.
    // A press only becomes a range drag once it has travelled this far. Below
    // it nothing is drawn and nothing is committed, so a plain click on the
    // chart stays a click — the gesture people use to clear things — instead of
    // flashing a one-pixel range under the cursor.
    private static let dragThreshold: CGFloat = 10
    // How close to an edge you must press to move it instead of starting over.
    private static let edgeGrab: CGFloat = 6

    // Everything outside the range is dimmed rather than the inside tinted, so
    // the bars that matter keep their real per-session colours.
    private static let dimColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.5)
            : NSColor(white: 1, alpha: 0.62)
    }

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return f
    }()

    private var windowStartEpoch: TimeInterval {
        let end = windowEnd == .distantPast ? Date() : windowEnd
        return end.timeIntervalSince1970 - config.windowSeconds
    }

    private func epoch(atX x: CGFloat) -> TimeInterval {
        let r = plotRect
        let frac = Double(min(max(x - r.minX, 0), r.width) / max(r.width, 1))
        return windowStartEpoch + frac * config.windowSeconds
    }

    private func x(forEpoch epoch: TimeInterval) -> CGFloat {
        let r = plotRect
        let frac = (epoch - windowStartEpoch) / config.windowSeconds
        return r.minX + CGFloat(min(max(frac, 0), 1)) * r.width
    }

    // Sessions that billed tokens in a bucket the range touches. Bucket
    // granularity is the chart's own, so the answer can never disagree with
    // the bars the drag covered.
    private func sessionIds(inEpochs range: ClosedRange<TimeInterval>) -> Set<String> {
        let slot = config.bucketSeconds
        guard slot > 0 else { return [] }
        let origin = windowStartEpoch
        var ids: Set<String> = []
        for (i, bucket) in buckets.enumerated() {
            let start = origin + Double(i) * slot
            guard start + slot > range.lowerBound, start < range.upperBound else { continue }
            ids.formUnion(bucket.bySession.keys)
        }
        return ids
    }

    func clearSelection() {
        guard selection != nil else { return }
        commitSelection(nil)
    }

    private func commitSelection(_ range: ClosedRange<Date>?) {
        selection = range
        needsDisplay = true
        onSelectionChange?(range.map {
            Selection(range: $0,
                      sessionIds: sessionIds(inEpochs: $0.lowerBound.timeIntervalSince1970
                                                     ... $0.upperBound.timeIntervalSince1970))
        })
    }

    // Which bar the pointer is over, if it is over one with anything in it.
    // The panel is drawn by the chart rather than handed to the system tooltip:
    // it has to appear at once and sit beside the bar it describes, while a
    // tooltip arrives after a delay wherever the pointer happens to be.
    private var hoverIndex: Int? {
        didSet { if hoverIndex != oldValue { needsDisplay = true } }
    }

    private func refreshHoverTracking() {
        trackingAreas.forEach(removeTrackingArea)
        guard hasData else { hoverIndex = nil; return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only over the plot, and not while a drag is in flight — the range's
        // own caption already sits in that corner.
        guard hasData, dragAnchor == nil, plotRect.contains(point) else {
            hoverIndex = nil
            return
        }
        hoverIndex = bucketIndex(atX: point.x)
            .flatMap { breakdown(at: $0).isEmpty ? nil : $0 }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }

    // Bars are a few pixels wide and stack several sessions, so the numbers
    // behind one are unreadable by eye. The tooltip answers for the bar under
    // the pointer, in whatever the chart is currently measuring — asking about
    // tokens while it draws cost would be a different chart's answer.
    // Lines for one bar: a heading with its interval and total, then the
    // sessions stacked inside it. Empty when the bar holds nothing.
    // One line of the hover panel. `key` is the series it belongs to — nil for
    // the heading and the "+N more" tail, which stand for no single colour.
    private struct Row {
        let key: String?
        // The number this row is about. Carried apart from the label so the
        // panel can lead with it and align it into a column — the figures are
        // what the panel is read for, and a ragged left edge buries them.
        let value: String?
        let text: String
    }

    private func breakdown(at index: Int) -> [Row] {
        guard buckets.indices.contains(index) else { return [] }
        let slot = config.bucketSeconds
        let start = windowStartEpoch
        let bucket = buckets[index]

        let from = Date(timeIntervalSince1970: start + Double(index) * slot)
        let to = from.addingTimeInterval(slot)
        let when = "\(Self.rangeFormatter.string(from: from)) – \(Self.timeOnlyFormatter.string(from: to))"

        // The stack is what the bar is: one segment per session (or project).
        // Its height alone cannot say which of them spent the tokens, and that
        // is the question a bar this wide actually raises.
        let parts: [(key: String, text: String, weight: Double)]
        switch mode {
        case .tokens:
            parts = bucket.bySession.map {
                ($0.key, "\(Self.formatTokenCount($0.value)) tokens", Double($0.value))
            }
        case .cost:
            parts = bucket.bySessionCost.map {
                ($0.key, Self.formatCostLabel($0.value), $0.value)
            }
        case .lines:
            let keys = Set(bucket.bySessionAdded.keys).union(bucket.bySessionRemoved.keys)
            parts = keys.map { key in
                let added = bucket.bySessionAdded[key] ?? 0
                let removed = bucket.bySessionRemoved[key] ?? 0
                // Both directions: at this width a bar of deletions reads the
                // same as one of additions.
                return (key, "+\(added) / −\(removed)", Double(added + removed))
            }
        }

        let total: String
        switch mode {
        case .tokens: total = "\(Self.formatTokenCount(bucket.total)) tokens"
        case .cost: total = Self.formatCostLabel(bucket.totalCost)
        case .lines: total = "+\(bucket.totalAdded) / −\(bucket.totalRemoved) lines"
        }

        let ranked = parts.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !ranked.isEmpty else { return [] }

        // The key travels with the line so the panel can carry each row's own
        // swatch. Without it the reader has to match a name to a colour by
        // guessing, which is the whole thing a stacked bar makes hard.
        // The heading goes through the same value column as the rows, so the
        // bar's total sits above the figures that add up to it.
        var lines: [Row] = [Row(key: nil, value: total, text: when)]
        for part in ranked.prefix(Self.hoverRows) {
            lines.append(Row(key: part.key, value: part.text,
                             text: seriesLabel?(part.key) ?? part.key))
        }
        // The tail is summed rather than merely counted: "+12 more" without a
        // figure leaves the rows visible not adding up to the total, and no way
        // to tell whether the rest is a rounding error or half the bar.
        let tail = ranked.dropFirst(Self.hoverRows).map(\.key)
        if !tail.isEmpty {
            lines.append(Row(key: nil, value: aggregate(of: tail, in: bucket),
                             text: "+\(tail.count) more"))
        }
        return lines
    }

    private static let hoverRows = 5

    // What the folded-away series add up to, in the units on screen. Summed
    // from the bucket rather than from the formatted rows, so it stays exact.
    private func aggregate(of keys: [String], in bucket: BucketData) -> String {
        switch mode {
        case .tokens:
            let n = keys.reduce(Int64(0)) { $0 + (bucket.bySession[$1] ?? 0) }
            return "\(Self.formatTokenCount(n)) tokens"
        case .cost:
            return Self.formatCostLabel(keys.reduce(0) { $0 + (bucket.bySessionCost[$1] ?? 0) })
        case .lines:
            let added = keys.reduce(Int64(0)) { $0 + (bucket.bySessionAdded[$1] ?? 0) }
            let removed = keys.reduce(Int64(0)) { $0 + (bucket.bySessionRemoved[$1] ?? 0) }
            return "+\(added) / −\(removed)"
        }
    }

    // Marks which bar the panel is about. Drawn with the background bands and
    // before the bars, so the column stays on top of its own marker — a line
    // painted over a bar hides the very thing being described.
    private func drawHoverGuide(in plotRect: NSRect) {
        guard let index = hoverIndex else { return }
        // Rounded to the pixel grid: a half-pixel line renders as two grey ones
        // and reads as misaligned however exact the maths was.
        let barX = barCenterX(index, in: plotRect)
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        NSRect(x: (barX - 0.5).rounded(), y: plotRect.minY,
               width: 1, height: plotRect.height).fill()
    }

    // The breakdown panel, beside the bar it belongs to. Same materials as the
    // range caption above it — translucent window background, 3 pt corners —
    // so it reads as part of the chart rather than a system popover.
    private func drawHoverPanel(in plotRect: NSRect) {
        guard let index = hoverIndex else { return }
        let rows = breakdown(at: index)
        guard !rows.isEmpty else { return }

        let headAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        // The value carries the weight; the name is context for it.
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let values = rows.map { row in
            row.value.map { NSAttributedString(string: $0, attributes: valueAttrs) }
        }
        let texts = rows.enumerated().map { i, row in
            NSAttributedString(string: row.text,
                               attributes: i == 0 ? headAttrs : labelAttrs)
        }

        let padding: CGFloat = 6
        let leading: CGFloat = 2
        // Every row is indented by the swatch column, heading included, so the
        // text starts on one line down the panel.
        let swatch: CGFloat = 7
        let swatchGap: CGFloat = 5
        let valueGap: CGFloat = 8
        let textInset = swatch + swatchGap
        // Values share one right-aligned column, so the eye runs down the
        // numbers instead of hunting for them at the end of each name.
        let valueWidth = values.compactMap { $0?.size().width }.max() ?? 0
        let valueColumn = valueWidth > 0 ? valueWidth + valueGap : 0
        let bodyWidth = zip(rows, texts).map { row, text in
            (row.value == nil ? 0 : valueColumn) + text.size().width
        }.max() ?? 0
        let width = bodyWidth + 2 * padding + textInset
        let lineHeight = (texts.first?.size().height ?? 11) + leading
        let height = lineHeight * CGFloat(texts.count) + 2 * padding - leading

        // Prefer the right of the bar; flip to its left when that would run off
        // the plot, so the panel never covers the axis or leaves the view.
        let barX = barCenterX(index, in: plotRect)
        var origin = NSPoint(x: barX + 8, y: plotRect.maxY - height)
        if origin.x + width > plotRect.maxX { origin.x = barX - 8 - width }
        origin.x = min(max(origin.x, plotRect.minX), max(plotRect.minX, plotRect.maxX - width))
        origin.y = max(origin.y, plotRect.minY)

        let box = NSRect(origin: origin, size: NSSize(width: width, height: height))
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()


        var y = box.maxY - padding
        let textX = box.minX + padding + textInset
        for (i, row) in rows.enumerated() {
            let text = texts[i]
            y -= lineHeight
            // The same colour the segment is drawn in, from the same function —
            // a legend that could drift from the bars would be worse than none.
            if let key = row.key {
                let chip = NSRect(x: box.minX + padding,
                                  y: y + (text.size().height - swatch) / 2,
                                  width: swatch, height: swatch)
                Self.color(for: key).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let value = values[i] {
                value.draw(at: NSPoint(x: textX + valueWidth - value.size().width, y: y))
                text.draw(at: NSPoint(x: textX + valueColumn, y: y))
            } else {
                text.draw(at: NSPoint(x: textX, y: y))
            }
        }
    }

    // Middle of the bar, computed the way the bars themselves are laid out
    // (slot per bucket, 1 pt gap) rather than from the time axis — the axis
    // maps a bucket's *start*, which put the marker on the bar's left edge.
    private func barCenterX(_ index: Int, in plotRect: NSRect) -> CGFloat {
        let slot = plotRect.width / CGFloat(max(buckets.count, 1))
        return plotRect.minX + CGFloat(index) * slot + max(1, slot - 1) / 2
    }

    private func bucketIndex(atX x: CGFloat) -> Int? {
        let index = Int((epoch(atX: x) - windowStartEpoch) / config.bucketSeconds)
        return buckets.indices.contains(index) ? index : nil
    }

    // The end of a bucket only needs its time: the date is already in the start.
    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard hasData else { return }
        addCursorRect(plotRect, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let r = plotRect
        guard hasData, r.width > 30,
              point.x >= r.minX - Self.edgeGrab, point.x <= r.maxX + Self.edgeGrab,
              point.y >= r.minY, point.y <= r.maxY
        else { super.mouseDown(with: event); return }

        dragStartX = point.x
        // Pressing near an edge of the current range moves that edge, anchoring
        // the drag on the opposite one.
        if let selection {
            let low = x(forEpoch: selection.lowerBound.timeIntervalSince1970)
            let high = x(forEpoch: selection.upperBound.timeIntervalSince1970)
            // Grabbing an edge is unambiguous — there is a range on screen and
            // the cursor is on its handle — so it arms at once and the edge
            // tracks the pointer from the first pixel.
            if abs(point.x - low) <= Self.edgeGrab {
                dragAnchor = selection.upperBound.timeIntervalSince1970
                dragCurrent = epoch(atX: point.x)
                dragArmed = true
                needsDisplay = true
                return
            }
            if abs(point.x - high) <= Self.edgeGrab {
                dragAnchor = selection.lowerBound.timeIntervalSince1970
                dragCurrent = epoch(atX: point.x)
                dragArmed = true
                needsDisplay = true
                return
            }
        }
        // A fresh press is still just a press: remember where it started, draw
        // nothing, and let mouseDragged decide whether it becomes a range.
        dragAnchor = epoch(atX: point.x)
        dragCurrent = dragAnchor
        dragArmed = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragAnchor != nil else { super.mouseDragged(with: event); return }
        let x = convert(event.locationInWindow, from: nil).x
        if !dragArmed {
            guard let startX = dragStartX,
                  abs(x - startX) >= Self.dragThreshold
            else { return }
            dragArmed = true
        }
        dragCurrent = epoch(atX: x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor = dragAnchor else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let armed = dragArmed
        dragAnchor = nil
        dragCurrent = nil
        dragStartX = nil
        dragArmed = false
        // Never travelled far enough to be a range, so it was a click — and a
        // click clears. One test, the same one that decides whether to draw.
        if !armed {
            commitSelection(nil)
            onBackgroundClick?()
            return
        }
        let current = epoch(atX: point.x)
        commitSelection(Date(timeIntervalSince1970: min(anchor, current))
                        ... Date(timeIntervalSince1970: max(anchor, current)))
    }

    private func drawSelection(in plotRect: NSRect) {
        let active: ClosedRange<TimeInterval>?
        // Only an armed drag paints; an unarmed one is still a click in
        // progress and must leave the chart exactly as it was.
        if dragArmed, let anchor = dragAnchor, let current = dragCurrent {
            active = min(anchor, current)...max(anchor, current)
        } else if let selection {
            active = selection.lowerBound.timeIntervalSince1970
                ... selection.upperBound.timeIntervalSince1970
        } else {
            active = nil
        }
        guard let active else { return }

        let x0 = x(forEpoch: active.lowerBound)
        let x1 = max(x(forEpoch: active.upperBound), x0 + 1)

        Self.dimColor.setFill()
        NSRect(x: plotRect.minX, y: plotRect.minY,
               width: x0 - plotRect.minX, height: plotRect.height).fill()
        NSRect(x: x1, y: plotRect.minY,
               width: plotRect.maxX - x1, height: plotRect.height).fill()

        NSColor.controlAccentColor.setFill()
        NSRect(x: x0, y: plotRect.minY, width: 1, height: plotRect.height).fill()
        NSRect(x: x1 - 1, y: plotRect.minY, width: 1, height: plotRect.height).fill()

        let count = sessionIds(inEpochs: active).count
        let span = active.upperBound - active.lowerBound
        let text = Self.rangeFormatter.string(from: Date(timeIntervalSince1970: active.lowerBound))
            + " – "
            + Self.rangeFormatter.string(from: Date(timeIntervalSince1970: active.upperBound))
            + " · " + Self.spanLabel(span)
            + " · \(count) session" + (count == 1 ? "" : "s")
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        let size = label.size()
        let padding: CGFloat = 5
        var box = NSRect(x: (x0 + x1) / 2 - size.width / 2 - padding,
                         y: plotRect.maxY - size.height - 2 * padding,
                         width: size.width + 2 * padding,
                         height: size.height + padding)
        box.origin.x = min(max(box.minX, plotRect.minX), plotRect.maxX - box.width)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        label.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    private static func spanLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

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
        // Cursor rects are computed once and cached by the window. The chart is
        // still empty when that first happens — the buckets are folded on a
        // background queue — so without asking for a recount here the crosshair
        // never appears at all. Tooltip rects are cached the same way and are
        // gated on the same `hasData`.
        window?.invalidateCursorRects(for: self)
        refreshHoverTracking()
    }

    // Switch back to the "Computing…" placeholder until the next
    // setBuckets call lands.
    func reset() {
        self.config = Self.currentConfig()
        self.hasData = false
        self.buckets = Array(repeating: BucketData(), count: config.bucketCount)
        // The brush answers a question about buckets that are about to be
        // thrown away; keeping it would filter the table by a stale set.
        clearSelection()
        needsDisplay = true
        // And back to an arrow, with nothing to describe, while there is
        // nothing to brush.
        window?.invalidateCursorRects(for: self)
        refreshHoverTracking()
    }

    // The rect is in view coordinates, so every geometry change invalidates it:
    // the chart spans the window's width and its height switches with the
    // Details chart, and a stale rect leaves the crosshair over the wrong band.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
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

    private var plotRect: NSRect {
        NSRect(
            x: Self.leftMargin,
            y: Self.bottomMargin,
            width: bounds.width - Self.leftMargin - Self.rightMargin,
            height: bounds.height - Self.topMargin - Self.bottomMargin
        )
    }

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
        let plotRect = self.plotRect
        guard plotRect.width > 30 && plotRect.height > 20 else { return }
        drawChart(in: plotRect)
        // Last, over every variant of the chart body — each of which returns
        // early on its own placeholder path.
        drawSelection(in: plotRect)
        drawHoverPanel(in: plotRect)
    }

    private func drawChart(in plotRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

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
        drawHoverGuide(in: plotRect)

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
        drawHoverGuide(in: plotRect)

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

    static func computeBuckets(externalEntries: [SessionIndexEntry] = [],
                               completion: @escaping ([BucketData], Date) -> Void) {
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

        // Deliberately NOT staged. The chart keys its series by session id, and
        // the demo entries keep the real ones, so the ordinary fold already
        // draws the real thing — including the nights and the gaps between
        // sessions that any synthesised version smears over.
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

            // Custom sources are already local snapshots. Fold their files
            // after the built-in roots so the aggregate chart includes the
            // same fleet as the table without ever touching a mounted path.
            for entry in externalEntries where entry.isExternalSource {
                guard entry.provider != .claudeDesktop,
                      let jsonl = SessionIndexer.transcriptURL(for: entry),
                      let attrs = try? fm.attributesOfItem(atPath: jsonl.path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.int64Value,
                      mtime >= windowStart else { continue }
                let path = jsonl.path
                guard !visited.contains(path) else { continue }
                visited.insert(path)

                var cached: CachedFile
                if let existing = fileCache[path], existing.parsedSize == size,
                   existing.mtime == mtime {
                    cached = existing
                } else if var existing = fileCache[path], size > existing.parsedSize {
                    switch entry.provider {
                    case .claude:
                        existing.parsedSize = parseClaudePoints(
                            at: jsonl, fromOffset: existing.parsedSize,
                            decoder: decoder, fallbackSessionId: entry.sessionId,
                            notBefore: windowStartEpoch,
                            seenRequestIds: &existing.seenRequestIds, into: &existing.points)
                    case .codex:
                        existing.parsedSize = parseCodexPoints(
                            at: jsonl, fromOffset: existing.parsedSize,
                            decoder: decoder, fallbackSessionId: entry.sessionId,
                            notBefore: windowStartEpoch, cache: &existing)
                    case .claudeDesktop: break
                    }
                    existing.mtime = mtime
                    cached = existing
                } else {
                    var fresh = CachedFile(
                        parsedSize: 0, mtime: mtime, points: [], seenRequestIds: [],
                        codexLastUsage: nil, codexModel: nil, codexCwd: nil,
                        codexSessionId: nil)
                    switch entry.provider {
                    case .claude:
                        fresh.parsedSize = parseClaudePoints(
                            at: jsonl, fromOffset: 0, decoder: decoder,
                            fallbackSessionId: entry.sessionId,
                            notBefore: windowStartEpoch,
                            seenRequestIds: &fresh.seenRequestIds, into: &fresh.points)
                    case .codex:
                        fresh.parsedSize = parseCodexPoints(
                            at: jsonl, fromOffset: 0, decoder: decoder,
                            fallbackSessionId: entry.sessionId,
                            notBefore: windowStartEpoch, cache: &fresh)
                    case .claudeDesktop: break
                    }
                    cached = fresh
                }

                cached.points.removeAll { $0.ts < windowStartEpoch }
                fileCache[path] = cached
                for point in cached.points where point.ts <= windowEndEpoch {
                    var idx = Int((point.ts - windowStartEpoch) / bucketSize)
                    if idx < 0 { idx = 0 }
                    if idx >= bucketCount { idx = bucketCount - 1 }
                    let cwd = point.cwd ?? cached.codexCwd ?? entry.cwd
                    let foldTemporary = !includeTemporary
                        && (cwd.hasPrefix("/private/tmp/") || cwd.hasPrefix("/private/var/"))
                    let key = foldTemporary ? Self.temporaryKey
                        : (groupByDir ? cwd : point.sessionId)
                    counts[idx].add(
                        sessionId: key, tokens: point.tokens, cost: point.cost,
                        linesAdded: point.linesAdded, linesRemoved: point.linesRemoved)
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
            // Claude Code 2.1 stopped labelling Edit results: an update now
            // carries oldString / newString / structuredPatch and no `type` at
            // all. Older transcripts still say "update", so both shapes count.
            switch result.type {
            case "update", nil:
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
