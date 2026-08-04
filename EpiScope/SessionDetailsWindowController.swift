import AppKit

// Cumulative input + cache + output line chart for a single session,
// plotted over the session timeline. Checkboxes along the top toggle
// individual series and conversation markers; the y-axis rescales to the
// tallest enabled series so a tiny line isn't squashed by a much larger one.
@MainActor
final class SessionUsageChartView: NSView {
    var events: [SessionIndexer.TranscriptEvent] = [] {
        didSet {
            canvas.events = events
            canvas.needsDisplay = true
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

        let legendHeight: CGFloat = 22
        NSLayoutConstraint.activate([
            inputToggle.topAnchor.constraint(equalTo: topAnchor),
            inputToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cacheToggle.topAnchor.constraint(equalTo: topAnchor),
            cacheToggle.leadingAnchor.constraint(equalTo: inputToggle.trailingAnchor, constant: 16),
            outputToggle.topAnchor.constraint(equalTo: topAnchor),
            outputToggle.leadingAnchor.constraint(equalTo: cacheToggle.trailingAnchor, constant: 16),
            userToggle.topAnchor.constraint(equalTo: topAnchor),
            userToggle.leadingAnchor.constraint(equalTo: outputToggle.trailingAnchor, constant: 16),
            assistantToggle.topAnchor.constraint(equalTo: topAnchor),
            assistantToggle.leadingAnchor.constraint(equalTo: userToggle.trailingAnchor, constant: 16),

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
}

@MainActor
final class ChartCanvas: NSView {
    static let inputColor = NSColor.systemGray
    static let cacheColor = NSColor.systemTeal
    static let outputColor = NSColor.systemBlue

    static let userMarkerColor = NSColor.systemOrange
    static let assistantMarkerColor = NSColor.systemPurple

    var events: [SessionIndexer.TranscriptEvent] = []
    var showInput: Bool = true
    var showCache: Bool = true
    var showOutput: Bool = true
    var showUserMarkers: Bool = true
    var showAssistantMarkers: Bool = true

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        // Cumulative usage snapshots, time-ordered — each series is a
        // monotonic line over the session timeline.
        let points: [(t: Date, input: Int64, cache: Int64, output: Int64)] =
            events.compactMap {
                guard let ts = $0.timestamp,
                      let i = $0.cumInput,
                      let w = $0.cumCacheWrite,
                      let c = $0.cumCacheRead,
                      let o = $0.cumOutput
                else { return nil }
                // Match the main table: cache creation is shown with Input;
                // cached reads remain the separate Cache series.
                return (ts, i + w, c, o)
            }
            .sorted { $0.t < $1.t }

        guard points.count >= 2 else {
            drawEmptyState()
            return
        }

        // Y domain: the tallest enabled (cumulative) series.
        var maxY: Int64 = 0
        for p in points {
            if showInput  { maxY = max(maxY, p.input) }
            if showCache  { maxY = max(maxY, p.cache) }
            if showOutput { maxY = max(maxY, p.output) }
        }
        guard maxY > 0 else { drawEmptyState(); return }

        // X domain spans every timestamped conversation event so markers near
        // the ends stay on-plot.
        let userTimes = events.compactMap { $0.kind == .user ? $0.timestamp : nil }
        let assistantTimes = events.compactMap { $0.kind == .assistant ? $0.timestamp : nil }
        let conversationTimes = userTimes + assistantTimes
        let tMin = min(points.first!.t, conversationTimes.min() ?? points.first!.t)
        let tMax = max(points.last!.t, conversationTimes.max() ?? points.last!.t)
        let span = max(tMax.timeIntervalSince(tMin), 1)

        let inset: CGFloat = 8
        let leftAxisWidth: CGFloat = 56
        let bottomAxisHeight: CGFloat = 14
        let plot = NSRect(
            x: bounds.minX + leftAxisWidth,
            y: bounds.minY + inset + bottomAxisHeight,
            width: bounds.width - leftAxisWidth - inset,
            height: bounds.height - 2 * inset - bottomAxisHeight
        )

        func xPos(_ t: Date) -> CGFloat {
            plot.minX + CGFloat(t.timeIntervalSince(tMin) / span) * plot.width
        }
        func yPos(_ v: Int64) -> CGFloat {
            plot.minY + CGFloat(Double(v) / Double(maxY)) * plot.height
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

        // User-message markers — solid verticals drawn under the data
        // lines so the curves read on top.
        if showUserMarkers, !userTimes.isEmpty {
            drawMarkers(userTimes, color: Self.userMarkerColor, in: plot, xPos: xPos)
        }
        if showAssistantMarkers, !assistantTimes.isEmpty {
            drawMarkers(assistantTimes, color: Self.assistantMarkerColor, in: plot, xPos: xPos)
        }

        // Data lines.
        func drawLine(_ value: (_ p: (t: Date, input: Int64, cache: Int64, output: Int64)) -> Int64,
                      color: NSColor) {
            let path = NSBezierPath()
            for (i, p) in points.enumerated() {
                let pt = NSPoint(x: xPos(p.t), y: yPos(value(p)))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
        if showInput  { drawLine({ $0.input },  color: Self.inputColor) }
        if showCache  { drawLine({ $0.cache },  color: Self.cacheColor) }
        if showOutput { drawLine({ $0.output }, color: Self.outputColor) }

        // Y-axis labels.
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let topLabel = NSAttributedString(string: formatTokens(maxY), attributes: axisAttrs)
        topLabel.draw(at: NSPoint(x: bounds.minX + 4, y: plot.maxY - topLabel.size().height))
        NSAttributedString(string: "0", attributes: axisAttrs)
            .draw(at: NSPoint(x: bounds.minX + 4, y: plot.minY))

        // Bottom time labels: start, middle, end of the time domain.
        func draw(_ s: String, atX x: CGFloat) {
            let str = NSAttributedString(string: s, attributes: axisAttrs)
            let sz = str.size()
            str.draw(at: NSPoint(
                x: max(plot.minX, min(x - sz.width / 2, plot.maxX - sz.width)),
                y: bounds.minY + 1
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

    private func drawEmptyState() {
        let s = NSAttributedString(string: "No usage data recorded yet", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let sz = s.size()
        s.draw(at: NSPoint(
            x: (bounds.width - sz.width) / 2,
            y: (bounds.height - sz.height) / 2
        ))
    }

    private func formatTokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
