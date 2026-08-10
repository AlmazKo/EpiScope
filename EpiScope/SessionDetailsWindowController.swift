import AppKit

// Cumulative input + cache + output line chart for a single session,
// plotted over the session timeline, with the lifecycle strip beneath it on
// the same time axis. Checkboxes along the top toggle individual series and
// conversation markers; the y-axis rescales to the tallest enabled series so a
// tiny line isn't squashed by a much larger one. The totals at the right of
// that row double as the strip's legend.
@MainActor
final class SessionUsageChartView: NSView {
    // Curves, markers and strip all come from one whole-file pass. The
    // transcript's own 4 MB tail cap governs what the conversation below shows
    // and nothing else — a big session used to draw a month of phases against
    // the last tenth of a curve.
    var timeline = SessionTimeline() {
        didSet {
            canvas.timeline = timeline
            canvas.needsDisplay = true
            summary.attributedStringValue = Self.summaryText(for: timeline)
        }
    }

    private let canvas = ChartCanvas()
    private let inputToggle = NSButton(checkboxWithTitle: "Input",
                                       target: nil, action: nil)
    private let cacheToggle = NSButton(checkboxWithTitle: "Cache",
                                       target: nil, action: nil)
    private let outputToggle = NSButton(checkboxWithTitle: "Output",
                                        target: nil, action: nil)
    private let userToggle = NSButton(checkboxWithTitle: "Your messages",
                                      target: nil, action: nil)
    private let assistantToggle = NSButton(checkboxWithTitle: "AI responses",
                                           target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupSubviews() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)

        let buttons: [(NSButton, NSColor, Int)] = [
            (inputToggle,  ChartCanvas.inputColor,  0),
            (cacheToggle,  ChartCanvas.cacheColor,  1),
            (outputToggle, ChartCanvas.outputColor, 2),
            (userToggle,   ChartCanvas.userMarkerColor, 3),
            (assistantToggle, ChartCanvas.assistantMarkerColor, 4),
        ]
        for (button, color, tag) in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.state = .on
            button.tag = tag
            button.target = self
            button.action = #selector(toggleSeries(_:))
            // Colour the title to match the line colour it controls.
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: color,
                ]
            )
            addSubview(button)
        }

        // The toggles own their width; the totals give theirs up first and
        // truncate rather than pushing a checkbox off the row.
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.alignment = .right
        summary.usesSingleLineMode = true
        summary.cell?.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(summary)

        // Not required: below roughly 530pt of window the checkboxes alone fill
        // the row, and a required gap here would break against the trailing
        // edge instead of simply letting the totals slide under them.
        let summaryGap = summary.leadingAnchor.constraint(
            greaterThanOrEqualTo: assistantToggle.trailingAnchor, constant: 16)
        summaryGap.priority = .defaultHigh

        // The row sat flush against the toolbar and against the plot below it.
        let legendTop: CGFloat = 6
        let legendHeight: CGFloat = 28
        NSLayoutConstraint.activate([
            summaryGap,
            inputToggle.topAnchor.constraint(equalTo: topAnchor, constant: legendTop),
            inputToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cacheToggle.topAnchor.constraint(equalTo: inputToggle.topAnchor),
            cacheToggle.leadingAnchor.constraint(equalTo: inputToggle.trailingAnchor, constant: 18),
            outputToggle.topAnchor.constraint(equalTo: inputToggle.topAnchor),
            outputToggle.leadingAnchor.constraint(equalTo: cacheToggle.trailingAnchor, constant: 18),
            userToggle.topAnchor.constraint(equalTo: inputToggle.topAnchor),
            userToggle.leadingAnchor.constraint(equalTo: outputToggle.trailingAnchor, constant: 18),
            assistantToggle.topAnchor.constraint(equalTo: inputToggle.topAnchor),
            assistantToggle.leadingAnchor.constraint(equalTo: userToggle.trailingAnchor, constant: 18),

            summary.centerYAnchor.constraint(equalTo: inputToggle.centerYAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            canvas.topAnchor.constraint(equalTo: topAnchor, constant: legendHeight),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func toggleSeries(_ sender: NSButton) {
        let on = (sender.state == .on)
        switch sender.tag {
        case 0: canvas.showInput = on
        case 1: canvas.showCache = on
        case 2: canvas.showOutput = on
        case 3: canvas.showUserMarkers = on
        case 4: canvas.showAssistantMarkers = on
        default: break
        }
        canvas.needsDisplay = true
    }

    // Where the session's wall clock went, in the strip's own colours — the
    // line is the legend. Zero-length phases and absent events are dropped
    // rather than printed as "0m", so the row says only what happened.
    private static func summaryText(for timeline: SessionTimeline) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            if out.length > 0 {
                out.append(NSAttributedString(string: " · ", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
            out.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
            ]))
        }
        let phases: [(String, SessionTimeline.Phase, NSColor)] = [
            ("Working", .working, ChartCanvas.workingColor),
            ("Permission", .permission, ChartCanvas.permissionColor),
            ("Idle", .idle, NSColor.secondaryLabelColor),
            ("Away", .away, NSColor.tertiaryLabelColor),
        ]
        for (label, phase, color) in phases {
            let seconds = timeline.total(phase)
            if seconds >= 1 { append("\(label) \(duration(seconds))", color) }
        }
        let edits = timeline.editCount
        if edits > 0 { append(count(edits, "edit"), ChartCanvas.editColor) }
        let interrupts = timeline.count(.interrupt)
        if interrupts > 0 { append(count(interrupts, "interrupt"), ChartCanvas.interruptColor) }
        let errors = timeline.count(.error)
        if errors > 0 { append(count(errors, "error"), ChartCanvas.errorColor) }
        return out
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)" + (n == 1 ? "" : "s")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}

@MainActor
final class ChartCanvas: NSView {
    static let inputColor = NSColor.systemGray
    static let cacheColor = NSColor.systemTeal
    static let outputColor = NSColor.systemBlue

    static let userMarkerColor = NSColor.systemOrange
    static let assistantMarkerColor = NSColor.systemPurple

    // Lifecycle strip — one explicit palette per appearance, see Theme. The
    // system colours these replaced are tuned for dark backgrounds and washed
    // out on white, and the translucent label greys blended into one slab.
    static let workingColor = Theme.lifeWorking
    static let permissionColor = Theme.lifePermission
    static let idleColor = Theme.lifeIdle
    static let awayColor = Theme.lifeAway
    static let trackColor = Theme.lifeTrack
    static let editColor = Theme.lifeEdit
    static let errorColor = Theme.lifeError
    static let interruptColor = Theme.lifeInterrupt
    static let compactColor = Theme.lifeCompact

    var timeline = SessionTimeline()
    var showInput: Bool = true
    var showCache: Bool = true
    var showOutput: Bool = true
    var showUserMarkers: Bool = true
    var showAssistantMarkers: Bool = true

    override var isFlipped: Bool { false }

    private static let stripHeight: CGFloat = 18   // 6pt event lane over a 12pt bar
    private static let stripGap: CGFloat = 10
    private static let eventLaneHeight: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        // Cumulative usage snapshots, time-ordered — each series is a
        // monotonic line over the session timeline.
        let points = timeline.usage

        // X domain spans every timestamped conversation event and the whole
        // lifecycle strip, so markers near the ends stay on-plot and a phase
        // always sits under the tokens it produced.
        let userTimes = timeline.userMessages
        let assistantTimes = timeline.assistantMessages
        var domain = points.map(\.at) + userTimes + assistantTimes
        if let start = timeline.start, let end = timeline.end { domain += [start, end] }
        guard let tMin = domain.min(), let tMax = domain.max() else {
            drawEmptyState(in: bounds)
            return
        }
        let span = max(tMax.timeIntervalSince(tMin), 1)

        let inset: CGFloat = 10
        let leftAxisWidth: CGFloat = 62
        let bottomAxisHeight: CGFloat = 17
        let stripSpace = timeline.isEmpty ? 0 : Self.stripHeight + Self.stripGap
        let plotBottom = bounds.minY + inset + bottomAxisHeight + stripSpace
        let plot = NSRect(
            x: bounds.minX + leftAxisWidth,
            y: plotBottom,
            width: bounds.width - leftAxisWidth - inset,
            height: max(1, bounds.maxY - inset - plotBottom)
        )

        func xPos(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(t.timeIntervalSince(tMin) / span) * plot.width
        }

        // Faint top + zero grid lines.
        NSColor.separatorColor.setStroke()
        for y in [plot.minY, plot.maxY] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.lineWidth = 0.5
            p.stroke()
        }

        // Y domain: the tallest enabled (cumulative) series.
        var maxY: Int64 = 0
        for p in points {
            if showInput  { maxY = max(maxY, p.input) }
            if showCache  { maxY = max(maxY, p.cacheRead) }
            if showOutput { maxY = max(maxY, p.output) }
        }
        let hasSeries = points.count >= 2 && maxY > 0

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        if hasSeries {
            func yPos(_ v: Int64) -> CGFloat {
                plot.minY + CGFloat(Double(v) / Double(maxY)) * plot.height
            }

            // User-message markers — solid verticals drawn under the data
            // lines so the curves read on top.
            if showUserMarkers, !userTimes.isEmpty {
                drawMarkers(userTimes, color: Self.userMarkerColor, in: plot, xPos: xPos)
            }
            if showAssistantMarkers, !assistantTimes.isEmpty {
                drawMarkers(assistantTimes, color: Self.assistantMarkerColor, in: plot, xPos: xPos)
            }

            // Data lines.
            func drawLine(_ value: (SessionTimeline.UsagePoint) -> Int64, color: NSColor) {
                let path = NSBezierPath()
                for (i, p) in points.enumerated() {
                    let pt = NSPoint(x: xPos(p.at), y: yPos(value(p)))
                    if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
                }
                path.lineWidth = 1.5
                path.lineJoinStyle = .round
                color.setStroke()
                path.stroke()
            }
            if showInput  { drawLine({ $0.input },     color: Self.inputColor) }
            if showCache  { drawLine({ $0.cacheRead }, color: Self.cacheColor) }
            if showOutput { drawLine({ $0.output },    color: Self.outputColor) }

            // Y-axis labels, right-aligned into the gutter so they end at a
            // fixed distance from the plot instead of at a ragged edge.
            func drawAxisLabel(_ s: String, alignedTo y: CGFloat, dropping: Bool) {
                let str = NSAttributedString(string: s, attributes: axisAttrs)
                let size = str.size()
                str.draw(at: NSPoint(x: plot.minX - 8 - size.width,
                                     y: dropping ? y - size.height : y))
            }
            drawAxisLabel(formatTokens(maxY), alignedTo: plot.maxY, dropping: true)
            drawAxisLabel("0", alignedTo: plot.minY, dropping: false)
        } else {
            // A session can have a shape without ever recording usage — a
            // Codex rollout with no token_count yet, a desktop audit. The
            // strip below still says what happened.
            drawEmptyState(in: plot)
        }

        if !timeline.isEmpty {
            drawTimeline(in: NSRect(x: plot.minX,
                                    y: plot.minY - Self.stripGap - Self.stripHeight,
                                    width: plot.width,
                                    height: Self.stripHeight),
                         xPos: xPos)
        }

        // Bottom time labels: start, middle, end of the time domain.
        func draw(_ s: String, atX x: CGFloat) {
            let str = NSAttributedString(string: s, attributes: axisAttrs)
            let sz = str.size()
            str.draw(at: NSPoint(
                x: max(plot.minX, min(x - sz.width / 2, plot.maxX - sz.width)),
                y: bounds.minY + 3
            ))
        }
        let labelFmt = Self.timeFormatter
        draw(labelFmt.string(from: tMin), atX: plot.minX)
        if span > 1 {
            draw(labelFmt.string(from: Date(timeInterval: span / 2, since: tMin)),
                 atX: plot.midX)
            draw(labelFmt.string(from: tMax), atX: plot.maxX)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return f
    }()

    private func drawMarkers(_ timestamps: [Date],
                             color: NSColor,
                             in plot: NSRect,
                             xPos: (Date) -> CGFloat) {
        let marks = NSBezierPath()
        marks.lineWidth = 1
        color.withAlphaComponent(0.5).setStroke()
        for timestamp in timestamps {
            let x = xPos(timestamp)
            marks.move(to: NSPoint(x: x, y: plot.minY))
            marks.line(to: NSPoint(x: x, y: plot.maxY))
        }
        marks.stroke()
    }

    // The lifecycle strip: a phase bar with a lane of edit ticks above it, and
    // point events struck across both. Same x mapping as the curves.
    private func drawTimeline(in rect: NSRect, xPos: (Date) -> CGFloat) {
        let bar = NSRect(x: rect.minX, y: rect.minY,
                         width: rect.width, height: rect.height - Self.eventLaneHeight)
        let lane = NSRect(x: rect.minX, y: bar.maxY,
                          width: rect.width, height: Self.eventLaneHeight)

        Self.trackColor.setFill()
        bar.fill()

        for span in timeline.spans {
            let x0 = max(rect.minX, xPos(span.start))
            let x1 = min(rect.maxX, xPos(span.end))
            guard x1 > rect.minX, x0 < rect.maxX else { continue }
            Self.color(for: span.phase).setFill()
            // A minute of a ten-hour session is still worth a pixel; a
            // sub-pixel rect would simply vanish.
            NSRect(x: x0, y: bar.minY, width: max(1, x1 - x0), height: bar.height).fill()
        }

        // Hairline edge over the phases: a month-long session is almost
        // entirely Away, and without it the bar's extent would be guesswork.
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(rect: bar.insetBy(dx: 0.25, dy: 0.25))
        outline.lineWidth = 0.5
        outline.stroke()

        for mark in timeline.marks {
            let x = xPos(mark.at)
            guard x >= rect.minX, x <= rect.maxX else { continue }
            switch mark.event {
            case let .edit(lines):
                // Churn lane: a taller tick moved more lines. Codex reports
                // that a patch landed but never how big it was, so its ticks
                // all sit at the floor.
                let share = min(1, CGFloat(max(lines, 0)) / 120)
                let height = max(1.5, lane.height * share)
                Self.editColor.withAlphaComponent(0.85).setFill()
                NSRect(x: min(x, lane.maxX - 1.5), y: lane.minY,
                       width: 1.5, height: height).fill()
            case .error:
                strike(at: x, in: rect, color: Self.errorColor, width: 1.5)
            case .interrupt:
                strike(at: x, in: rect, color: Self.interruptColor, width: 1.5)
            case .compact:
                strike(at: x, in: rect, color: Self.compactColor, width: 1.5)
            case .resume:
                strike(at: x, in: rect, color: NSColor.labelColor.withAlphaComponent(0.45), width: 1)
            }
        }
    }

    private func strike(at x: CGFloat, in rect: NSRect, color: NSColor, width: CGFloat) {
        color.setFill()
        NSRect(x: min(x, rect.maxX - width), y: rect.minY,
               width: width, height: rect.height).fill()
    }

    private static func color(for phase: SessionTimeline.Phase) -> NSColor {
        switch phase {
        case .working:    return workingColor
        case .permission: return permissionColor
        case .idle:       return idleColor
        case .away:       return awayColor
        }
    }

    private func drawEmptyState(in rect: NSRect) {
        let s = NSAttributedString(string: "No usage data recorded yet", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(
            x: rect.minX + (rect.width - sz.width) / 2,
            y: rect.minY + (rect.height - sz.height) / 2
        ))
    }

    private func formatTokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
