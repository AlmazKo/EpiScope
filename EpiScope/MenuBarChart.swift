import AppKit

// The menu-bar face of the fleet: one vertical bar per live session.
//
//   * a running session is a dashed bar scrolling slowly upward — the
//     gaps are what makes the motion readable at this size;
//   * a session waiting on an answer (the `Finished` state) is an amber
//     bar, and one parked on a permission prompt is a red one. Neither
//     scrolls: they stand still and blink, at the same rates the old
//     status icon blinked (half a second red, a second amber).
//
// Rendering follows the low-level path from `dots`: we draw into our own
// CGContext and hand the CGImage to a CALayer we own, instead of setting
// `button.image`. The image setter drags NSButton's whole display chain
// (intrinsic size invalidation, Auto Layout, bezel and title drawing)
// into every frame, which costs several times more than a layer update —
// affordable once a second, not ten times a second.
//
// The frame clock is a plain main-run-loop Timer on purpose: WorkScheduler
// owns *expensive* work and beats at 1 s, and a redraw of a dozen filled
// rects is neither. It runs only while at least one session is live.

// The view that owns the render layer. It fills the status button and
// keeps the layer centred itself: the button's width follows the status
// item's length only on a later layout pass, so centring at the moment we
// set the length would use a stale width and drift with every resize.
//
// hitTest returns nil so the host doesn't swallow clicks — the status
// button still gets its mouse events and opens the menu.
private final class ChartHostView: NSView {
    let renderLayer = CALayer()
    var contentSize: NSSize = .zero { didSet { centreContent() } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centreContent()
    }

    private func centreContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLayer.frame = NSRect(
            x: ((bounds.width - contentSize.width) / 2).rounded(),
            y: ((bounds.height - contentSize.height) / 2).rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
        CATransaction.commit()
    }
}

@MainActor
final class MenuBarChart {
    enum Bar: Equatable {
        case active       // busy right now — dashes march upward
        case question     // finished a step, waiting on the operator
        case permission   // parked on a permission prompt
    }

    // Geometry, in points.
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let height: CGFloat = 16
    // One dash plus the gap after it. 4 + 2 puts not quite three dashes in
    // the bar — enough breaks for the eye to track the movement, without
    // the bar reading as dotted.
    private static let dashOn: CGFloat = 4
    private static let dashOff: CGFloat = 2
    // Points per second. 5 is the base — at 10 fps exactly half a point,
    // one Retina pixel, per frame. Each lit slot runs at 0.8–1.2 of it (in
    // tenths, so five possible rates), which is enough for bars to drift
    // apart instead of marching as one block. Positions are snapped back
    // to the half-point grid when drawing, so an off-grid rate costs no
    // crispness.
    private static let speed: CGFloat = 5
    private static let speedSpread = 8...12   // in tenths of the base

    // The chart is always these six slots wide: a fleet that outgrows the
    // menu bar would push everything else off screen, and a chart that
    // resized with the session count would make the whole right-hand side
    // of the menu bar jitter. Sessions fill the slots from the left (the
    // caller sorts requests first, so a cut only ever drops the least
    // urgent bars); the leftovers stay as faint, still placeholders.
    private static let slots = 6
    private static let emptyAlpha: CGFloat = 0.15

    private static let fps = 10
    private static let frameInterval: TimeInterval = 0.1

    // Blink periods in frames: a permission bar toggles every half
    // second, a question bar every second — the rates the blinking `?`
    // icon used before the bars replaced it.
    private static let permissionBlinkFrames = 5
    private static let questionBlinkFrames = 10
    // The blink-off phase dims rather than hides: a bar that vanishes
    // reads as "gone", and the count of sessions must stay legible.
    private static let dimmedAlpha: CGFloat = 0.35

    // Warm amber, like the macOS microphone-in-use indicator and the
    // `Finished` badge in the table — not a glaring yellow.
    private static let amber = NSColor(srgbRed: 0.91, green: 0.58, blue: 0.12, alpha: 1)

    private weak var statusItem: NSStatusItem?
    private weak var button: NSStatusBarButton?
    private var host: ChartHostView?

    private var bars: [Bar] = []
    // Monotonic frame counter — the single source of both the scroll
    // phase and the blink phase, so everything on screen shares one clock.
    private var frame = 0
    private var timer: Timer?
    private var appearanceObserver: NSKeyValueObservation?
    // Per slot, the rate its bar scrolls at. Rolled when the slot lights up
    // and kept until it goes dark again: re-rolling while it runs would
    // make the bar surge and stall.
    private var slotSpeeds = [CGFloat?](repeating: nil, count: MenuBarChart.slots)

    func attach(to item: NSStatusItem) {
        statusItem = item
        guard let button = item.button else { return }
        self.button = button
        button.image = nil
        button.title = ""

        let host = ChartHostView(frame: button.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.renderLayer.contentsScale = scale
        host.layer?.addSublayer(host.renderLayer)
        button.addSubview(host)
        self.host = host

        // The colours are resolved against the *button's* appearance at draw
        // time, so a theme change only needs a repaint — which the clock
        // does for us while it runs, but not while it is parked on an idle
        // fleet. Two triggers, because neither covers the other:
        //
        //   * the global light/dark switch arrives as a distributed
        //     notification, the way `dots` catches it;
        //   * effectiveAppearance also moves without that notification (the
        //     item lands on another screen, the menu-bar tint changes) and,
        //     crucially, right after launch — see the deferred first draw
        //     below.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.draw() }
        }
        appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.draw() }
            }
        }

        layout()
        // At applicationDidFinishLaunching the item is not in the menu bar
        // yet, so its effectiveAppearance still reports .aqua even when the
        // menu bar is dark — drawing now would paint the bars black on a
        // dark bar until the first real update. Let the run loop attach it
        // first. (`dots` defers its first render for the same reason.)
        DispatchQueue.main.async { [weak self] in self?.draw() }
    }

    // The whole input: which sessions to show, in the order to show them.
    // Anything past the six slots is dropped — the caller sorts requests
    // first, so the bars that survive are the ones worth the space.
    func update(bars newBars: [Bar]) {
        bars = Array(newBars.prefix(Self.slots))
        for i in 0..<Self.slots {
            guard i < bars.count, bars[i] == .active else { slotSpeeds[i] = nil; continue }
            if slotSpeeds[i] == nil {
                slotSpeeds[i] = Self.speed * CGFloat(Int.random(in: Self.speedSpread)) / 10
            }
        }
        syncClock()
        draw()
    }

    // MARK: - Layout

    // Constant: the chart is always `slots` bars wide, filled or not.
    private static let contentWidth =
        CGFloat(slots) * barWidth + CGFloat(slots - 1) * barGap

    private var scale: CGFloat {
        button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func layout() {
        let size = NSSize(width: Self.contentWidth, height: Self.height)
        statusItem?.length = size.width + 8
        host?.contentSize = size
        host?.renderLayer.contentsScale = scale
    }

    // MARK: - Clock

    private func syncClock() {
        // Every bar animates — active ones scroll, the other two blink —
        // so the clock is needed exactly while the fleet isn't empty.
        let wanted = !bars.isEmpty
        if wanted == (timer != nil) { return }
        if wanted {
            let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = Self.frameInterval * 0.2
            // .common, not .default: the menu bar keeps animating while a
            // menu is open or a window is being resized.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            frame = 0
        }
    }

    private func tick() {
        frame &+= 1
        draw()
    }

    // MARK: - Render

    private func draw() {
        guard let host else { return }
        let size = NSSize(width: Self.contentWidth, height: Self.height)
        let scale = self.scale
        let pxW = Int(size.width * scale), pxH = Int(size.height * scale)
        guard pxW > 0, pxH > 0 else { return }
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let appearance = button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            render(size: size)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit fade between frames
        host.renderLayer.contents = image
        CATransaction.commit()
    }

    private func render(size: NSSize) {
        let period = Self.dashOn + Self.dashOff
        for i in 0..<Self.slots {
            let x = CGFloat(i) * (Self.barWidth + Self.barGap)
            guard i < bars.count else {
                // A free slot: faint, full height, still. It reads as the
                // room a session would take, not as a session.
                NSColor.labelColor.withAlphaComponent(Self.emptyAlpha).setFill()
                NSRect(x: x, y: 0, width: Self.barWidth, height: size.height).fill()
                continue
            }
            switch bars[i] {
            case .active:
                NSColor.labelColor.withAlphaComponent(0.85).setFill()
                let travelled = CGFloat(frame) * (slotSpeeds[i] ?? Self.speed) / CGFloat(Self.fps)
                // Stagger the slots so bars that light up together don't
                // start with their gaps in a row, and snap to the
                // half-point (one pixel) grid so an off-base rate doesn't
                // put a dash edge between pixels.
                let raw = (travelled + CGFloat(i) * period / 3)
                    .truncatingRemainder(dividingBy: period)
                let phase = (raw * 2).rounded() / 2
                // Start one period below the bottom edge so the dash
                // entering from underneath is drawn clipped, not missing.
                var y = phase - period
                while y < size.height {
                    let bottom = max(0, y), top = min(size.height, y + Self.dashOn)
                    if top > bottom {
                        NSRect(x: x, y: bottom, width: Self.barWidth, height: top - bottom).fill()
                    }
                    y += period
                }
            case .question, .permission:
                let isPermission = bars[i] == .permission
                let frames = isPermission ? Self.permissionBlinkFrames : Self.questionBlinkFrames
                let on = (frame / frames) % 2 == 0
                let color = isPermission ? NSColor.systemRed : Self.amber
                color.withAlphaComponent(on ? 1 : Self.dimmedAlpha).setFill()
                NSRect(x: x, y: 0, width: Self.barWidth, height: size.height).fill()
            }
        }
    }
}
