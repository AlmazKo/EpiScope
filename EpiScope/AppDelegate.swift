import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let monitor = SessionMonitor()
    private let indexer = SessionIndexer()
    private let searchIndex = SearchIndex()
    private lazy var mainWindow = MainWindowController(indexer: indexer, monitor: monitor, searchIndex: searchIndex, reports: reportsWindow)
    private let reportStore = ReportStore()
    private let analysisRunner = AnalysisRunner()
    private lazy var settingsWindow = SettingsWindowController()
    private lazy var reportsWindow = ReportsWindowController(
        indexer: indexer, searchIndex: searchIndex,
        store: reportStore, runner: analysisRunner)
    private let chart = MenuBarChart()
    // Live menu rows use the indexer's provider-normalised task description
    // as their primary label. Claude Desktop keeps the name shown in its own
    // sidebar; CLI Claude and Codex use their automatic descriptions.
    private var sessionDescriptions: [String: String] = [:]
    // TEMPORARY — see MenuBarChartDemo.swift, delete with it.
    private let chartDemo = MenuBarChartDemo()
    // The set of live session ids at the last reindex. A live-state flip
    // (thinking↔idle, kitty paint) fires every second for an active
    // session but rarely changes which sessions exist — only reindex when
    // the membership actually changes, not on every flip.
    private var lastLiveSessionIds: Set<String> = []
    // nil until the first poll completes — that way an already-pending
    // session present at launch doesn't fire the "new permission"
    // chime.
    private var lastWaitingCount: Int?

    // The dropdown gets a lightweight frame clock only while it is visible.
    // Icons animate at 10 fps; elapsed labels share that clock but update only
    // once per second. Rows are retained for the whole tracking session so an
    // update never moves the highlighted item underneath the pointer.
    private static let menuIconFPS = 10
    private static let menuIconFrameInterval: TimeInterval = 0.1
    private var isStatusMenuOpen = false
    private var menuAnimationTimer: Timer?
    private var menuAnimationFrame = 0
    private var fleetMenuItems: [String: NSMenuItem] = [:]
    private var fleetMenuStates: [String: FleetState] = [:]
    private var fleetIconCache: [FleetIconCacheKey: NSImage] = [:]


    // Shared content width for the status-bar dropdown: the limit gauges are
    // drawn to exactly this width (bars right-aligned to its right edge), and
    // session rows truncate their path to fit, so a long cwd can't blow the
    // menu out and everything lines up against one right edge.
    private static let menuContentWidth: CGFloat = 300
    // Native menu items add an image column and their own horizontal insets
    // around attributedTitle. Keep the text inside the remainder so a long AI
    // description cannot make a fleet row wider than the 300-point gauge rows.
    private static let fleetTextWidth = menuContentWidth - 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance only: a second EpiScope would race the first
        // on cc-states.json (two publishers). If one's already running,
        // bring it forward and quit this one.
        let me = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me.bundleIdentifier
                && $0.processIdentifier != me.processIdentifier
        }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        // Don't let AppKit auto-dim action-less items — the limit gauges
        // are display-only but must render at full strength.
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
        chart.attach(to: statusItem)
        chartDemo.start(chart: chart, statusItem: statusItem)   // TEMPORARY

        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            // SessionMonitor already tails Codex rollouts to detect unresolved
            // approvals for the table/menu. Hand that verdict to the terminal
            // tracker too, so the same transition can produce a notification;
            // don't make a second rollout scanner just for banners.
            let codexWaiting = Set(self.monitor.waiting.compactMap { session in
                session.entrypoint == "codex" ? session.sessionId : nil
            })
            TerminalTracker.shared.updateCodexWaitingSessionIds(codexWaiting)
            self.render()
        }
        monitor.onLiveStateChange = { [weak self] in
            // Finished (done) state lives in kittyStates, which changes here
            // rather than via onUpdate — refresh the icon so the yellow blink
            // tracks it.
            self?.render()
            NotificationCenter.default.post(name: .signalLiveStateChanged, object: nil)
            // Only reindex when the set of live sessions changed (one
            // appeared or died) — then the table needs a new/removed row.
            // A mere state flip on an existing session is already painted
            // by the targeted reload in liveStateChanged(); reindexing on
            // every flip rebuilt the whole table once a second for nothing.
            guard let self else { return }
            let liveIds = Set(self.monitor.liveSessions.keys)
            if liveIds != self.lastLiveSessionIds {
                self.lastLiveSessionIds = liveIds
                self.indexer.kickReindex()
            }
        }
        // Full-text search index: reconciles its FTS rows off the same entries
        // the table uses (onEntriesUpdated fires alongside onUpdate), and reports
        // cold-build progress to the search window via a notification. Hooks set
        // and db opened before indexer.start() so the initial publish lands.
        indexer.onEntriesUpdated = { [weak self] entries in
            self?.searchIndex.reconcile(entries: entries)
            // Feed the tracker each session's terminal label for Ghostty
            // binding, plus the description used as notification/menu context.
            // Claude Desktop's sidebar name is its canonical user-facing task
            // identity; CLI custom names remain binding-only metadata.
            var titles: [String: String] = [:]
            var descriptions: [String: String] = [:]
            for e in entries {
                if let label = e.title ?? e.name, !label.isEmpty {
                    titles[e.sessionId] = label
                }
                let description = e.isClaudeDesktop ? (e.name ?? e.title) : e.title
                if let description, !description.isEmpty {
                    descriptions[e.sessionId] = description
                }
            }
            self?.sessionDescriptions = descriptions
            TerminalTracker.shared.updateSessionMetadata(
                titles: titles, descriptions: descriptions)
        }
        searchIndex.onProgress = { done, total in
            NotificationCenter.default.post(
                name: .searchIndexProgress, object: nil,
                userInfo: ["done": done, "total": total])
        }
        searchIndex.open()

        monitor.start()
        SessionSourceStore.shared.start()
        indexer.start()
        // EpiScope is the tracker now: publishes cc-states.json (consumed
        // by kitty-painter.py, cc-open and SessionMonitor) and owns the
        // done / needs_permission notification banners.
        TerminalTracker.shared.start()
        // Notification tap: jump to the session's terminal/app when we know
        // where it runs; otherwise bring EpiScope forward and select the
        // session in the table.
        TerminalTracker.shared.onNotificationClick = { [weak self] sid in
            self?.goToSession(sid)
        }
        // Insights is embedded in the main window (fleet-level, à la deep
        // search); the ✦ toolbar item and the row's "Analyze Session…" drive it
        // internally. Tap on a "Daily insights ready" banner → that view.
        TerminalTracker.shared.onReportNotificationClick = { [weak self] in
            self?.mainWindow.show()
            self?.mainWindow.enterInsights()
        }
        // Daily insights: check every 30 min whether today's run is due. The
        // first check waits a minute, so the indexer has published entries.
        WorkScheduler.shared.register(.init(
            id: "insights-schedule", interval: 1800, target: .main, initialDelay: 60
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.maybeRunDailyInsights()
                self?.maybeRunWeeklyInsights()
            }
        })
        render()

        // Quietly install / migrate the Claude Code integration on every
        // launch: append any missing hooks and refresh our managed scripts
        // (so fixes ship without the user reinstalling). Gentle and
        // idempotent — never touches a foreign status line or removes
        // anything, and writes settings.json only when something's actually
        // missing (see ClaudeHooks.install). Off the main thread; result
        // (an error string at most) is intentionally ignored.
        DispatchQueue.global(qos: .utility).async {
            _ = ClaudeHooks.install()
        }

        // Keep the limit-gauge cache warm in the background so opening the
        // status-bar menu is pure-cache (no disk I/O on the main thread).
        LimitChart.refreshLimitsCache()
        WorkScheduler.shared.register(.init(
            id: "limits-cache", interval: 20, target: .main, initialDelay: 20
        ) {
            LimitChart.refreshLimitsCache()
        })

        LoginItem.ensureFirstRun()

        // EpiScope is a full-fledged macOS app now (no LSUIElement) —
        // open the main window on launch so the user lands on it
        // instead of having to hunt the status bar.
        mainWindow.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMenuAnimation()
        // Index saves are debounced — push the last snapshot out
        // before the process dies.
        indexer.flushIndexToDisk()
    }

    private func render() {
        // Chime when another live permission/question request appears. Opening
        // its terminal leaves the count unchanged, so it does not re-chime.
        let count = monitor.waiting.count
        if let prev = lastWaitingCount, count > prev {
            playChime()
        }
        lastWaitingCount = count

        guard !chartDemo.isRunning else { return }   // TEMPORARY
        chart.update(bars: currentBars())
    }

    private enum FleetState: Hashable {
        case request
        case error
        case finished
        case active

        var rank: Int {
            switch self {
            case .request: 0
            case .error: 1
            case .finished: 2
            case .active: 3
            }
        }

        var bar: MenuBarChart.Bar {
            switch self {
            case .request: .permission
            case .error, .finished: .question
            case .active: .active
            }
        }

        var symbolName: String? {
            switch self {
            case .request: "exclamationmark"
            case .error: "exclamationmark"
            case .finished: "checkmark"
            case .active: nil
            }
        }

        var iconBackgroundColor: NSColor {
            switch self {
            case .request: .systemRed
            case .error, .finished: .systemYellow
            case .active: .systemBlue
            }
        }

        var iconForegroundColor: NSColor {
            switch self {
            case .error, .finished: .black
            case .request, .active: .white
            }
        }
    }

    private struct FleetIconCacheKey: Hashable {
        let state: FleetState
        let phase: Int
    }

    private struct FleetSession {
        let session: SessionInfo
        let state: FleetState
    }

    // One fleet entry per session that is doing something or wants something.
    // Attention first — permission prompts, then sessions waiting on an
    // answer — so the two blinking colours sit at the left edge; the rest
    // keep a stable order (by session id) so a bar doesn't hop across the
    // chart every time the fleet is re-sampled.
    //
    // An idle session gets no bar at all: it is open, not running, and a bar
    // for it would say the machine is busier than it is. Busy is the same
    // verdict the table uses — the session file's own `busy`, or the
    // tracker's `thinking`.
    //
    // Permission requests remain urgent until Claude reports that the session
    // has actually left `waiting`. Finished and failed turns use the amber
    // reaction alarm and are acknowledged by opening them through EpiScope.
    private func currentFleet() -> [FleetSession] {
        let waitingIds = Set(monitor.waiting.map(\.sessionId))
        var fleet: [FleetSession] = []
        for (sid, info) in monitor.liveSessions {
            let state: FleetState?
            if waitingIds.contains(sid) {
                state = .request
            } else if monitor.kittyStates[sid] == "error" {
                state = .error
            } else if monitor.kittyStates[sid] == "done" {
                state = .finished
            } else if info.status == "busy" || monitor.kittyStates[sid] == "thinking" {
                state = .active
            } else {
                state = nil
            }
            if let state {
                fleet.append(FleetSession(session: info, state: state))
            }
        }
        return fleet.sorted {
            ($0.state.rank, $0.session.sessionId)
                < ($1.state.rank, $1.session.sessionId)
        }
    }

    private func currentBars() -> [MenuBarChart.Bar] {
        currentFleet().map { $0.state.bar }
    }

    private func playChime() { Chime.playCurrent() }

    // MARK: - Menu

    // Cocoa fires this right before the menu opens — perfect spot to
    // rebuild with fresh state without doing pointless work between
    // user interactions. The status bar menu, the main bar's Settings
    // menu and its submenus all share this delegate, dispatched by title.
    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "Settings":
            refreshViewMenu(menu)
        case "Columns":
            refreshColumnsMenu(menu)
        case "Chart Window":
            refreshChartWindowMenu(menu)
        case "Chart Bars":
            refreshChartBarsMenu(menu)
        default:
            rebuildMenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuOpen = true
        startMenuAnimation()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        isStatusMenuOpen = false
        stopMenuAnimation()
    }

    private func startMenuAnimation() {
        stopMenuAnimation()
        guard !fleetMenuItems.isEmpty else { return }
        menuAnimationFrame = 0
        refreshOpenMenuTimes()
        refreshOpenMenuIcons()

        let timer = Timer(timeInterval: Self.menuIconFrameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickOpenMenu() }
        }
        timer.tolerance = Self.menuIconFrameInterval * 0.2
        // Menu tracking runs a nested event loop; common mode keeps the clock
        // alive there without running it while the dropdown is closed.
        RunLoop.main.add(timer, forMode: .common)
        menuAnimationTimer = timer
    }

    private func stopMenuAnimation() {
        menuAnimationTimer?.invalidate()
        menuAnimationTimer = nil
        menuAnimationFrame = 0
    }

    private func tickOpenMenu() {
        menuAnimationFrame &+= 1
        refreshOpenMenuIcons()
        if menuAnimationFrame % Self.menuIconFPS == 0 {
            refreshOpenMenuTimes()
        }
    }

    private func refreshOpenMenuTimes() {
        for item in fleetMenuItems.values {
            guard let session = item.representedObject as? SessionInfo else { continue }
            let title = formattedTitle(for: session)
            if item.attributedTitle?.isEqual(to: title) != true {
                item.attributedTitle = title
            }
        }
    }

    private func refreshOpenMenuIcons() {
        for (sessionId, item) in fleetMenuItems {
            guard let state = fleetMenuStates[sessionId] else { continue }
            let image = fleetIcon(for: state, frame: menuAnimationFrame)
            if item.image !== image {
                item.image = image
            }
        }
    }

    private func refreshChartWindowMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = TokenChartView.windowDays
        for days in TokenChartView.windowDayChoices {
            let item = NSMenuItem(
                title: days == 1 ? "1 day" : "\(days) days",
                action: #selector(selectChartWindow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = days
            item.state = (days == current) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectChartWindow(_ sender: NSMenuItem) {
        guard let days = sender.representedObject as? Int,
              days != TokenChartView.windowDays else { return }
        TokenChartView.windowDays = days
        mainWindow.chartWindowChanged()
    }

    private func refreshChartBarsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // Bar sizes apply to the token chart; in Limits mode none is active.
        let limitOff = LimitChart.mode == .none
        let currentBars = TokenChartView.barSeconds
        for choice in TokenChartView.barChoices {
            let item = NSMenuItem(
                title: choice.title,
                action: #selector(selectChartBars(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.seconds
            item.state = (limitOff && choice.seconds == currentBars) ? .on : .off
            menu.addItem(item)
        }

        // Manual caps for the Limits gauges (blank = auto-estimate).
        menu.addItem(.separator())
        let cap5h = NSMenuItem(title: "Set 5h limit cap…",
                               action: #selector(setLimitCap(_:)), keyEquivalent: "")
        cap5h.target = self
        cap5h.representedObject = "5h"
        menu.addItem(cap5h)
        let capWk = NSMenuItem(title: "Set weekly limit cap…",
                               action: #selector(setLimitCap(_:)), keyEquivalent: "")
        capWk.target = self
        capWk.representedObject = "weekly"
        menu.addItem(capWk)
    }

    @objc private func selectChartBars(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        if LimitChart.mode == .none && seconds == TokenChartView.barSeconds { return }
        LimitChart.mode = .none
        TokenChartView.barSeconds = seconds
        // Same recompute path as a window change — the point cache is
        // keyed by file, bucketing happens at compute time.
        mainWindow.reloadChart()
    }

    @objc private func setLimitCap(_ sender: NSMenuItem) {
        let isWeekly = (sender.representedObject as? String) == "weekly"
        let current = isWeekly ? LimitChart.capWeeklyOverride : LimitChart.cap5hOverride
        let alert = NSAlert()
        alert.messageText = isWeekly ? "Weekly limit cap" : "5-hour limit cap"
        alert.informativeText =
            "Token cap for the fill gauge. Leave blank to auto-estimate from "
            + "the tallest window observed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. 5000000  (blank = auto)"
        if current > 0 { field.stringValue = String(current) }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = max(0, Int64(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0)
        if isWeekly { LimitChart.capWeeklyOverride = value }
        else { LimitChart.cap5hOverride = value }
        mainWindow.reloadChart()
    }

    private func refreshViewMenu(_ menu: NSMenu) {
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "view.showTemporary":
                item.state = UserDefaults.standard.bool(
                    forKey: Self.showTemporaryKey
                ) ? .on : .off
            case "view.chartWindowOnly":
                item.state = UserDefaults.standard.bool(
                    forKey: Self.chartWindowOnlyKey
                ) ? .on : .off
            case "view.groupByDir":
                item.state = mainWindow.isGroupByDirEnabled ? .on : .off
            case "view.limitGauges":
                item.state = limitGaugesEnabled ? .on : .off
            case "view.launchAtLogin":
                item.state = LoginItem.isEnabled ? .on : .off
            default:
                break
            }
        }
    }

    @objc private func toggleGroupByDirectory() {
        mainWindow.toggleGroupByDir()
    }

    // One-line hints shown under each column name in the picker.
    private static let columnHints: [String: String] = [
        "col.sessionColor": "Per-session colour, matches the chart",
        "col.permWait": "Time spent waiting on permission prompts",
        "col.model": "Model and reasoning effort",
        "col.status": "Live state — waiting / busy / finished",
        "col.path": "Project directory",
        "col.name": "Custom session name",
        "col.title": "First user prompt",
        "col.startedAt": "When the session began",
        "col.userMessages": "Number of user messages",
        "col.turns": "Model responses (agentic steps), not human turns",
        "col.branch": "Git branch",
        "col.input": "Input + cache-creation tokens",
        "col.changes": "Lines added / removed by edits",
        "col.cacheRead": "Cache-read tokens",
        "col.output": "Output tokens",
        "col.cost": "Estimated USD cost",
        "col.activity": "Most recent activity",
    ]

    private func refreshColumnsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for c in mainWindow.columnsForMenu() {
            let item = NSMenuItem(
                title: c.title,
                action: #selector(toggleColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = c.rawId
            item.state = c.isHidden ? .off : .on
            if let hint = Self.columnHints[c.rawId] {
                let title = NSMutableAttributedString(
                    string: c.title,
                    attributes: [.font: NSFont.menuFont(ofSize: 0)])
                title.append(NSAttributedString(
                    string: "\n" + hint,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                item.attributedTitle = title
            }
            menu.addItem(item)
        }
    }

    static func formatResetShort(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        guard s > 0 else { return "now" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // A section header styled after the native Control Center menus (Wi-Fi
    // etc.): mixed-case, semibold, a fairly intense grey — not the small, faint
    // NSMenu sectionHeader. Drawn as a custom view so it isn't dimmed.
    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuHeaderView(title: title, width: Self.menuContentWidth)
        return item
    }

    final class MenuHeaderView: NSView {
        private let title: String
        private let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        private let leftInset: CGFloat = 14

        override var isFlipped: Bool { true }

        init(title: String, width: CGFloat) {
            self.title = title
            super.init(frame: NSRect(x: 0, y: 0, width: width, height: 25))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            let attr: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let lineH = ceil(font.ascender - font.descender)
            // Sit toward the bottom so there's breathing room above the header.
            let y = max(0, bounds.height - lineH - 3)
            NSAttributedString(string: title, attributes: attr).draw(at: NSPoint(x: leftInset, y: y))
        }
    }

    private func addLimitGauges(to menu: NSMenu) {
        // Only vendors with real, non-zero usage get a section. No data (the
        // user doesn't use that tool) or both windows at 0 → hide it entirely
        // rather than show empty/zeroed bars.
        let vendors: [(name: String, lim: LimitChart.RealLimits, estimate: Bool)] =
            [("Claude", LimitChart.cachedClaudeLimits(), LimitChart.cachedClaudeIsEstimate()),
             ("Codex", LimitChart.cachedCodexLimits(), false)]
            .compactMap { (name, lim, est) -> (String, LimitChart.RealLimits, Bool)? in
                guard let lim, (lim.fiveHour ?? 0) > 0 || (lim.sevenDay ?? 0) > 0 else { return nil }
                return (name, lim, est)
            }
        guard !vendors.isEmpty else { return }

        // Fraction of the window's clock already elapsed: the window ends at
        // reset, so elapsed = windowLength − timeUntilReset.
        func timePct(_ reset: Date?, window: Double) -> Double? {
            // A reset already in the past means the window rolled over but the
            // status line hasn't refreshed it — we can't place "now" in the
            // current window, so skip the pace zone instead of showing it full.
            guard let reset, reset.timeIntervalSinceNow > 0 else { return nil }
            let elapsed = window - reset.timeIntervalSinceNow
            return max(0, min(100, elapsed / window * 100))
        }
        func rows(_ lim: LimitChart.RealLimits) -> [LimitGaugeSectionView.Row] {
            var result: [LimitGaugeSectionView.Row] = []
            if let pct = lim.fiveHour {
                result.append(.init(window: "5h", pct: pct,
                                    timePct: timePct(lim.fiveHourReset, window: 5 * 3600)))
            }
            if let pct = lim.sevenDay {
                result.append(.init(window: "Week", pct: pct,
                                    timePct: timePct(lim.sevenDayReset, window: 7 * 24 * 3600)))
            }
            return result
        }
        for (i, v) in vendors.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            // Mark token-estimate sections (no status-line data) like the chart.
            menu.addItem(headerItem(v.estimate ? "\(v.name) Limits · estimate" : "\(v.name) Limits"))
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.view = LimitGaugeSectionView(rows: rows(v.lim), width: Self.menuContentWidth)
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    // One vendor's gauge rows (the vendor name is a native section header added
    // separately by addLimitGauges). Each row: window label on the left, then a
    // three-tone bar — dark = limit used, grey = window time elapsed beyond
    // that (your headroom against the clock), light = remaining — and the
    // percent right-aligned. No grey zone means usage has caught up with the
    // clock, i.e. you're spending faster than time passes. Drawn (not
    // attributedTitle) so AppKit neither greys it out nor highlights it.
    final class LimitGaugeSectionView: NSView {
        struct Row { let window: String; let pct: Double?; let timePct: Double? }

        private let rows: [Row]

        private let rowFont = NSFont.systemFont(ofSize: 13)
        private let leftInset: CGFloat = 14
        private let rightPad: CGFloat = 14
        private let labelColW: CGFloat = 40   // window label column ("5h" / "Week")
        private let barH: CGFloat = 7
        private let pctW: CGFloat = 34
        private let topPad: CGFloat = 3
        private let rowH: CGFloat = 20

        override var isFlipped: Bool { true }

        init(rows: [Row], width: CGFloat) {
            self.rows = rows
            super.init(frame: .zero)
            frame = NSRect(x: 0, y: 0,
                           width: width,
                           height: topPad * 2 + CGFloat(rows.count) * rowH)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func frac(_ p: Double?) -> CGFloat { CGFloat(min(100, max(0, p ?? 0))) / 100 }

        override func draw(_ dirtyRect: NSRect) {
            let labelAttr: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: NSColor.labelColor]
            let dimAttr: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: NSColor.tertiaryLabelColor]
            let radius = barH / 2

            let lineH = ceil(rowFont.ascender - rowFont.descender)
            let rightEdge = bounds.width - rightPad
            let barLeft = leftInset + labelColW + 10
            let barRight = rightEdge - pctW - 8
            let barW = max(20, barRight - barLeft)

            for (i, r) in rows.enumerated() {
                let rowTop = topPad + CGFloat(i) * rowH
                let textY = rowTop + (rowH - lineH) / 2
                NSAttributedString(string: r.window, attributes: labelAttr).draw(at: NSPoint(x: leftInset, y: textY))
                let capCenterY = textY + rowFont.ascender - rowFont.capHeight / 2
                drawGauge(row: r, barLeft: barLeft, barW: barW, centerY: capCenterY, radius: radius)

                let pctStr = r.pct.map { "\(Int($0.rounded()))%" } ?? "?"
                let pa = NSAttributedString(string: pctStr, attributes: r.pct == nil ? dimAttr : labelAttr)
                pa.draw(at: NSPoint(x: rightEdge - ceil(pa.size().width), y: textY))
            }
        }

        private func drawGauge(row r: Row, barLeft: CGFloat, barW: CGFloat, centerY: CGFloat, radius: CGFloat) {
            func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
            }
            let top = centerY - barH / 2
            NSColor.quaternaryLabelColor.setFill(); pill(barLeft, top, barW, barH).fill()   // remaining
            if r.pct != nil, let t = r.timePct, t > 0 {                                       // time-elapsed zone
                NSColor.tertiaryLabelColor.setFill(); pill(barLeft, top, barW * frac(t), barH).fill()
            }
            if let pct = r.pct, pct > 0 {                                                     // limit used
                let u = frac(pct)
                NSColor.labelColor.setFill(); pill(barLeft, top, max(barH, barW * u), barH).fill()
                // Over-forecast: usage beyond the planned (time-elapsed) pace,
                // painted red so it's obvious by how much you're ahead. Only
                // drawn when over pace.
                if let t = r.timePct, u > frac(t) {
                    let x0 = barLeft + barW * frac(t)
                    let w = barW * (u - frac(t))
                    if w >= 2 {
                        // Soft "hazard" look rather than a brutal solid red: a
                        // faint red wash under diagonal semi-transparent stripes.
                        let box = NSRect(x: x0, y: top, width: w, height: barH)
                        NSGraphicsContext.saveGraphicsState()
                        pill(x0, top, w, barH).addClip()
                        NSColor.systemRed.withAlphaComponent(0.16).setFill()
                        box.fill()
                        NSColor.systemRed.withAlphaComponent(0.55).setStroke()
                        let stripes = NSBezierPath()
                        stripes.lineWidth = 2
                        var sx = box.minX - barH
                        while sx < box.maxX {
                            stripes.move(to: CGPoint(x: sx, y: box.minY))
                            stripes.line(to: CGPoint(x: sx + barH, y: box.maxY))
                            sx += 4
                        }
                        stripes.stroke()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
        }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        fleetMenuItems.removeAll(keepingCapacity: true)
        fleetMenuStates.removeAll(keepingCapacity: true)

        if limitGaugesEnabled { addLimitGauges(to: menu) }

        // Use the exact same fleet verdict as the fixed menu-bar slots. The
        // chart cuts at five; the dropdown deliberately lists the whole fleet.
        let fleet = currentFleet()
        let attention = fleet.filter { $0.state != .active }
        let active = fleet.filter { $0.state == .active }

        if fleet.isEmpty {
            let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            if !attention.isEmpty {
                menu.addItem(headerItem("Needs attention"))
                for entry in attention {
                    let item = makeItem(for: entry.session, state: entry.state)
                    registerFleetItem(item, session: entry.session, state: entry.state)
                    menu.addItem(item)
                }
            }
            if !active.isEmpty {
                menu.addItem(headerItem("Active"))
                for entry in active {
                    let item = makeItem(for: entry.session, state: entry.state)
                    registerFleetItem(item, session: entry.session, state: entry.state)
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(.separator())

        let showWindow = NSMenuItem(
            title: "Show all sessions…",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindow.target = self
        menu.addItem(showWindow)

        let searchItem = NSMenuItem(
            title: "Search sessions…",
            action: #selector(showSearchWindow),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)

        // AppKit normally asks for content before menuWillOpen, but starting
        // here too makes the clock independent of delegate callback order.
        if menu === statusMenu, isStatusMenuOpen, menuAnimationTimer == nil {
            startMenuAnimation()
        }
    }

    private func registerFleetItem(_ item: NSMenuItem,
                                   session: SessionInfo,
                                   state: FleetState) {
        fleetMenuItems[session.sessionId] = item
        fleetMenuStates[session.sessionId] = state
    }

    private func makeItem(for session: SessionInfo, state: FleetState) -> NSMenuItem {
        let item = NSMenuItem(title: session.folderName,
                              action: #selector(selectSession(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.attributedTitle = formattedTitle(for: session)
        item.image = fleetIcon(for: state, frame: menuAnimationFrame)
        return item
    }

    private func fleetIcon(for state: FleetState, frame: Int) -> NSImage? {
        let (phase, opacity) = iconAnimation(state: state, frame: frame)
        let key = FleetIconCacheKey(state: state, phase: phase)
        if let cached = fleetIconCache[key] { return cached }

        let symbol: NSImage?
        if state == .active {
            symbol = nil
        } else {
            guard let symbolName = state.symbolName else { return nil }
            let configuration = NSImage.SymbolConfiguration(
                pointSize: 10,
                weight: .semibold
            ).applying(.init(paletteColors: [state.iconForegroundColor]))
            guard let configured = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration) else { return nil }
            symbol = configured
        }

        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(opacity)
            defer { context?.restoreGState() }

            state.iconBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()

            if state == .active {
                Self.drawSegmentedLoader(in: rect, phase: phase)
            } else if let symbol {
                let symbolRect = NSRect(
                    x: rect.midX - symbol.size.width / 2,
                    y: rect.midY - symbol.size.height / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                symbol.draw(in: symbolRect)
            }
            return true
        }
        // Keep semantic state colours in the menu instead of letting AppKit
        // turn the whole image into a label-coloured template.
        image.isTemplate = false
        fleetIconCache[key] = image
        return image
    }

    private static func drawSegmentedLoader(in rect: NSRect, phase: Int) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let activeSegment = phase / 2
        let activeOpacity: CGFloat = phase.isMultiple(of: 2) ? 0.58 : 1

        for segment in 0..<6 {
            let path = NSBezierPath()
            let startAngle = 69 + CGFloat(segment) * 60
            path.appendArc(
                withCenter: center,
                radius: 6.5,
                startAngle: startAngle,
                endAngle: startAngle + 42
            )
            path.lineWidth = 2.6
            path.lineCapStyle = .butt

            let opacity: CGFloat = segment == activeSegment ? activeOpacity : 0.16
            NSColor.white.withAlphaComponent(opacity).setStroke()
            path.stroke()
        }
    }

    private func iconAnimation(state: FleetState, frame: Int) -> (phase: Int, opacity: CGFloat) {
        switch state {
        case .active:
            // Twelve cached frames illuminate the six donut sections in turn.
            // Nothing moves geometrically: only the brightness advances on
            // every clock tick. Each section gets a medium and a bright frame.
            return (frame % 12, 1)
        case .request:
            // Full cycle 1 Hz, matching the red menu-bar permission bar.
            let phase = (frame / (Self.menuIconFPS / 2)) % 2
            return (phase, phase == 0 ? 1 : 0.4)
        case .error, .finished:
            // Full cycle 0.5 Hz, matching the amber reaction bar.
            let phase = (frame / Self.menuIconFPS) % 2
            return (phase, phase == 0 ? 1 : 0.4)
        }
    }

    private func formattedTitle(for session: SessionInfo) -> NSAttributedString {
        let mainFont = NSFont.menuFont(ofSize: 0)
        let rawDescription = sessionDescriptions[session.sessionId]
            ?? session.name
            ?? session.folderName
        let oneLineDescription = rawDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let description = Self.truncatedTail(
            oneLineDescription, font: mainFont, maxWidth: Self.fleetTextWidth)
        let result = NSMutableAttributedString(
            string: description,
            attributes: [.font: mainFont]
        )

        // Status is already unambiguous in the coloured icon. Keep the second
        // line for location and time since the underlying session status last
        // changed; updatedAt is the provider fallback when no dedicated status
        // timestamp exists (notably Codex and SDK-driven sessions).
        let subFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let suffix = session.statusChangedAtDate.map {
            " · \(Self.formatElapsed(since: $0)) ago"
        } ?? ""
        let suffixW = (suffix as NSString).size(withAttributes: [.font: subFont]).width
        let budget = Self.fleetTextWidth - suffixW
        let directory = Self.truncatedTail(
            session.folderName, font: subFont, maxWidth: max(60, budget))
        result.append(NSAttributedString(
            string: "\n\(directory)\(suffix)",
            attributes: [
                .font: subFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    // Keep the start of an AI description or directory name; unlike a path,
    // its leading words carry the useful identity.
    private static func truncatedTail(_ s: String, font: NSFont, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxWidth { return s }
        var chars = Array(s)
        while chars.count > 1 {
            chars.removeLast()
            let candidate = String(chars) + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth {
                return candidate
            }
        }
        return "…"
    }

    private static func formatElapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        let m = s / 60, rs = s % 60
        if m < 60 { return rs == 0 ? "\(m)m" : "\(m)m \(rs)s" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.sessionId, forType: .string)
        goToSession(session.sessionId)
    }

    // Land the user on a session picked from a notification banner or the
    // status-bar menu. When EpiScope knows the hosting terminal, cc-open
    // focuses the exact window/tab. Otherwise the session is detached (no
    // window to focus) — acknowledge it (silences the menu-bar blink) and
    // reveal it in the table, where the user decides what to do and the
    // pending permission just sits. A detached session must NOT go through
    // cc-open, whose no-window fallback spawns a stray kitty at the cwd.
    private func goToSession(_ sid: String) {
        if monitor.terminalKinds[sid] != nil {
            TerminalIntegration.openSession(sessionId: sid)
            NSApp.hide(nil)
        } else {
            TerminalTracker.shared.acknowledge(sessionId: sid)
            mainWindow.revealSession(sessionId: sid)
        }
    }

    @objc private func toggleLoginItem() {
        LoginItem.toggle()
    }

    @objc private func showMainWindow() {
        mainWindow.show()
    }

    @objc private func showSearchWindow() {
        mainWindow.show()
        mainWindow.enterSearchMode()
    }

    @objc private func showReportsWindow() {
        mainWindow.show()
        mainWindow.enterInsights()
    }

    // MARK: - Daily insights schedule

    private static let lastDailyInsightsKey = "lastDailyInsightsDay"
    // Hidden pref — `defaults write almazko.EpiScope dailyInsightsHour 8`.
    private var dailyInsightsHour: Int {
        let v = UserDefaults.standard.integer(forKey: "dailyInsightsHour")
        return v == 0 ? 9 : v
    }

    // One run per calendar day, first tick past the target hour. The day
    // is marked *before* the run: a failed run shouldn't retry (and
    // re-bill) every 30 minutes — the toolbar button covers a redo.
    private func maybeRunDailyInsights() {
        guard dailyInsightsEnabled else { return }
        guard Calendar.current.component(.hour, from: Date()) >= dailyInsightsHour
        else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastDailyInsightsKey) != today,
              !reportsWindow.isAnalysisRunning,
              AnalysisModelChoice.named(ReportsWindowController.defaultModel)
                  .engine.locate() != nil
        else { return }
        // Mark the day only once a run actually started. The old order marked
        // first, so either refusal — a run already in flight, or nothing worth
        // reporting yet — burned the day silently.
        if reportsWindow.runDailyInsights() {
            defaults.set(today, forKey: Self.lastDailyInsightsKey)
        }
    }

    private static let lastWeeklyInsightsKey = "lastWeeklyInsightsWeek"

    // Monday morning: a separate weekly overview (past 7 days), in addition to
    // that day's daily one. Once per ISO week, first tick past the target hour;
    // the week isn't marked until it actually starts, so if the daily run is
    // still going it retries on the next tick.
    private func maybeRunWeeklyInsights() {
        guard dailyInsightsEnabled else { return }
        let cal = Calendar.current
        guard cal.component(.weekday, from: Date()) == 2 else { return }  // Monday (Sun=1)
        guard cal.component(.hour, from: Date()) >= dailyInsightsHour else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-'W'ww"
        let week = df.string(from: Date())
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastWeeklyInsightsKey) != week,
              !reportsWindow.isAnalysisRunning,
              AnalysisModelChoice.named(ReportsWindowController.defaultModel)
                  .engine.locate() != nil
        else { return }
        // Monday fires both runs in the same tick, and the daily one wins the
        // race: `runner.isRunning` is still false during its prep phase, so the
        // weekly passed this guard, marked the week done and was then refused
        // by the reports window. That lost the weekly report every Monday.
        if reportsWindow.runWeeklyInsights() {
            defaults.set(week, forKey: Self.lastWeeklyInsightsKey)
        }
    }

    // MARK: - About panel

    // MARK: - Dialog formatting

    // Renders a backtick-marked string into an attributed body: prose in
    // the system font, `code` spans (paths, filenames) monospaced with a
    // subtle highlight. Bullet lines (•) get a hanging indent.
    private static func attributedDialog(_ markup: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 7
        let bullet = NSMutableParagraphStyle()
        bullet.lineSpacing = 3
        bullet.paragraphSpacing = 4
        bullet.headIndent = 16
        bullet.firstLineHeadIndent = 0

        // Faint, theme-adaptive code highlight — a heavy box looks
        // wrong in light mode and inverts oddly in dark.
        let codeBG = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.12)
                : NSColor(white: 0, alpha: 0.06)
        }
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        let code: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.controlAccentColor,
            .backgroundColor: codeBG,
        ]

        let result = NSMutableAttributedString()
        for (i, line) in markup.components(separatedBy: "\n").enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = line.hasPrefix("•") ? bullet : para
            var isCode = false
            for seg in line.components(separatedBy: "`") {
                if !seg.isEmpty {
                    var attrs = isCode ? code : body
                    attrs[.paragraphStyle] = style
                    result.append(NSAttributedString(string: seg, attributes: attrs))
                }
                isCode.toggle()
            }
        }
        return result
    }

    // A roomier alert: the body lives in a wide wrapping accessory view
    // (NSAlert's own text is cramped and narrow), with code highlighting.
    // `footnote` is appended as small tertiary fine print (trademarks).
    private func styledAlert(title: String, markup: String,
                             footnote: String? = nil, width: CGFloat = 460) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        let full = NSMutableAttributedString(attributedString: Self.attributedDialog(markup))
        if let footnote {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.paragraphSpacingBefore = 12
            full.append(NSAttributedString(string: "\n" + footnote, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: para,
            ]))
        }
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = full
        // Non-selectable: a selectable label drops its attributed runs
        // (fonts / code highlight) to the field's plain style the moment
        // it's clicked into the field editor.
        label.isSelectable = false
        label.isEditable = false
        label.allowsEditingTextAttributes = false
        label.preferredMaxLayoutWidth = width
        let h = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: 0, y: 0, width: width, height: ceil(h))
        alert.accessoryView = label
        // Opaque, solid background — no desktop bleed-through.
        alert.window.isOpaque = true
        alert.window.backgroundColor = .windowBackgroundColor
        return alert
    }

    private var aboutWindow: NSWindow?
    private static let aboutSlogan = "Mission control for your AI coding sessions."

    @objc private func showAboutPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = aboutWindow { w.makeKeyAndOrderFront(nil); return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let W: CGFloat = 540, H: CGFloat = 300, headerH: CGFloat = 150
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "About EpiScope"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // Full-width gradient header band.
        let header = AboutHeaderView(frame: NSRect(x: 0, y: H - headerH, width: W, height: headerH))
        root.addSubview(header)

        // Big hero image — a bear mascot when one's bundled ("AboutMascot"),
        // otherwise the app icon.
        let hero = NSImageView(frame: NSRect(x: 32, y: H - headerH + (headerH - 110) / 2,
                                             width: 110, height: 110))
        hero.image = NSImage(named: "AboutMascot") ?? NSApp.applicationIconImage
        hero.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(hero)

        @discardableResult
        func label(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = font; t.textColor = color; t.frame = frame
            root.addSubview(t)
            return t
        }
        label("EpiScope", .systemFont(ofSize: 34, weight: .bold), .white,
              NSRect(x: 168, y: H - 78, width: W - 190, height: 42))
        label("Version \(version)", .systemFont(ofSize: 12), NSColor.white.withAlphaComponent(0.85),
              NSRect(x: 170, y: H - 96, width: W - 190, height: 16))
        label(Self.aboutSlogan, .systemFont(ofSize: 14, weight: .medium),
              NSColor.white.withAlphaComponent(0.92),
              NSRect(x: 170, y: H - 128, width: W - 190, height: 20))

        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = Self.attributedDialog("""
            EpiScope watches Claude Code and OpenAI Codex sessions on this Mac — \
            live permission prompts in the menu bar, plus token usage, costs, \
            transcripts and a per-session detail view.

            Built by Alexander Suslov
            """)
        body.frame = NSRect(x: 32, y: 52, width: W - 64, height: 94)
        root.addSubview(body)

        let close = NSButton(title: "Close", target: self, action: #selector(closeAbout))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: W - 96, y: 16, width: 80, height: 30)
        root.addSubview(close)

        win.contentView = root
        win.center()
        aboutWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func closeAbout() { aboutWindow?.close() }

    // Full-width gradient band behind the About header.
    final class AboutHeaderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [
                NSColor(srgbRed: 0.15, green: 0.16, blue: 0.30, alpha: 1),
                NSColor(srgbRed: 0.36, green: 0.20, blue: 0.50, alpha: 1),
            ])?.draw(in: bounds, angle: -55)
        }
    }

    // Dock click after the window was closed → re-show it. Once the
    // process is in .regular mode (because the user opened the window
    // at least once), the Dock icon stays around and this is what
    // makes it useful.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            mainWindow.show()
        }
        return true
    }

    // MARK: - Main menu (top-of-screen menu bar)

    private static let showTemporaryKey = "showTemporarySessions"
    // Mirrors MainWindowController.chartWindowOnlyKey — the toggle lives here,
    // the filtering lives there.
    private static let chartWindowOnlyKey = "limitTableToChartWindow"

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // App menu (the bold "EpiScope" leftmost entry). Cocoa expects
        // the first top-level item — Apple's HIG: About, Hide, Quit.
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "EpiScope")
        let aboutItem = NSMenuItem(
            title: "About EpiScope",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide EpiScope",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit EpiScope",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu

        // Edit menu — without it, the standard editing shortcuts
        // (Cmd-X/C/V/A, Undo/Redo) never reach the first responder, so
        // paste into the search fields silently does nothing. Standard
        // selectors route to whatever text field is focused.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(
            title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        // View menu — Show temporary toggle + Columns submenu live here
        // rather than in the status bar, since they affect the main
        // window and that's where the user is when they reach for them.
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "Settings")
        viewMenu.delegate = self
        let showTemp = NSMenuItem(
            title: "Show Temporary Sessions",
            action: #selector(toggleShowTemporary),
            keyEquivalent: ""
        )
        showTemp.target = self
        showTemp.identifier = NSUserInterfaceItemIdentifier("view.showTemporary")
        viewMenu.addItem(showTemp)

        let groupByDir = NSMenuItem(
            title: "Group by Directory",
            action: #selector(toggleGroupByDirectory),
            keyEquivalent: ""
        )
        groupByDir.target = self
        groupByDir.identifier = NSUserInterfaceItemIdentifier("view.groupByDir")
        viewMenu.addItem(groupByDir)

        // Off by default — the limit gauges in the status-bar dropdown are
        // opt-in, since not everyone wants them taking up the menu.
        let limitGauges = NSMenuItem(
            title: "Show Limit Usage in Status Bar",
            action: #selector(toggleLimitGauges),
            keyEquivalent: ""
        )
        limitGauges.target = self
        limitGauges.identifier = NSUserInterfaceItemIdentifier("view.limitGauges")
        viewMenu.addItem(limitGauges)

        let chartWindowItem = NSMenuItem(title: "Chart Window", action: nil, keyEquivalent: "")
        let chartWindowMenu = NSMenu(title: "Chart Window")
        chartWindowMenu.delegate = self
        chartWindowItem.submenu = chartWindowMenu
        viewMenu.addItem(chartWindowItem)

        // Sits under Chart Window because it is that setting's reach: the same
        // span, applied to the table instead of only to the bars.
        let chartWindowOnly = NSMenuItem(
            title: "Chart Window Only",
            action: #selector(toggleChartWindowOnly),
            keyEquivalent: ""
        )
        chartWindowOnly.target = self
        chartWindowOnly.identifier = NSUserInterfaceItemIdentifier("view.chartWindowOnly")
        chartWindowOnly.toolTip = "Show only sessions last active inside the chart window"
        viewMenu.addItem(chartWindowOnly)

        let chartBarsItem = NSMenuItem(title: "Chart Bars", action: nil, keyEquivalent: "")
        let chartBarsMenu = NSMenu(title: "Chart Bars")
        chartBarsMenu.delegate = self
        chartBarsItem.submenu = chartBarsMenu
        viewMenu.addItem(chartBarsItem)

        let columnsItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        let columnsMenu = NSMenu(title: "Columns")
        columnsMenu.delegate = self
        columnsItem.submenu = columnsMenu
        viewMenu.addItem(columnsItem)

        // App-level settings (used to live in the status bar menu —
        // Settings is their home now; the status bar stays sessions-only).
        viewMenu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.identifier = NSUserInterfaceItemIdentifier("view.launchAtLogin")
        viewMenu.addItem(loginItem)

        if debugMode {
            let recompute = NSMenuItem(
                title: "Run Recalculation (debug)",
                action: #selector(runRecalculation),
                keyEquivalent: ""
            )
            recompute.target = self
            viewMenu.addItem(recompute)
        }

        viewItem.submenu = viewMenu

        // Window menu — gives the standard Minimise / Zoom / Bring All
        // To Front items NSApp can fill in automatically.
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(.separator())
        let showSessions = NSMenuItem(
            title: "Sessions",
            action: #selector(showMainWindow),
            keyEquivalent: "0"
        )
        showSessions.target = self
        windowMenu.addItem(showSessions)
        let showSearch = NSMenuItem(
            title: "Search Sessions",
            action: #selector(showSearchWindow),
            keyEquivalent: "f"
        )
        showSearch.target = self
        windowMenu.addItem(showSearch)
        let showReports = NSMenuItem(
            title: "Reports",
            action: #selector(showReportsWindow),
            keyEquivalent: "1"
        )
        showReports.target = self
        windowMenu.addItem(showReports)
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc private func toggleChartWindowOnly() {
        let key = Self.chartWindowOnlyKey
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .signalChartWindowOnlyChanged, object: nil)
    }

    @objc private func toggleShowTemporary() {
        let key = Self.showTemporaryKey
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .signalShowTemporaryChanged, object: nil)
        // Indexer skips temp sessions during shallow walk based on the
        // same setting — re-kick it so newly-eligible sessions show up
        // immediately when the toggle goes back on.
        indexer.kickReindex()
    }

    // A dock-less run has to become a regular app first, or the window opens
    // behind everything with no way to reach it.
    @objc private func showSettings() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        settingsWindow.show()
    }

    // On by default; the toggle persists an explicit choice. The status-bar
    // menu rebuilds on open, so flipping the pref is enough.
    private static let limitGaugesKey = "menuLimitGauges"
    private var limitGaugesEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.limitGaugesKey) as? Bool ?? true
    }

    @objc private func toggleLimitGauges() {
        UserDefaults.standard.set(!limitGaugesEnabled, forKey: Self.limitGaugesKey)
    }

    // Daily Insights runs automatically once a day. Its two controls (on/off
    // and the analysis model) live in Settings → Insights; this side only reads
    // the pref to decide whether a scheduled run happens.
    static let dailyInsightsEnabledKey = "dailyInsightsEnabled"
    private var dailyInsightsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dailyInsightsEnabledKey) as? Bool ?? true
    }

    // Debug affordance (hidden unless `defaults write almazko.EpiScope debugMode
    // -bool YES`): force an insights run now, bypassing the once-a-day guard,
    // so the whole pipeline can be exercised without waiting for the schedule.
    private var debugMode: Bool { UserDefaults.standard.bool(forKey: "debugMode") }
    @objc private func runRecalculation() {
        mainWindow.show()
        mainWindow.enterInsights()
        reportsWindow.runDailyInsights()
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        mainWindow.toggleColumn(rawIdentifier: raw)
    }
}
