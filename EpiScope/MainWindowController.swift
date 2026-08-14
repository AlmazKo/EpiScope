import AppKit

extension Notification.Name {
    // Fired by AppDelegate when SessionMonitor's per-session status
    // map changes. MainWindowController repaints visible rows.
    static let signalLiveStateChanged = Notification.Name("episcope.liveStateChanged")
    // Fired by AppDelegate when the user toggles Kitty integration in
    // the status menu. MainWindowController re-applies / clears row tints.
    // Fired by AppDelegate when the user toggles Show Temporary in the
    // Settings submenu. MainWindowController reapplies the filter.
    static let signalShowTemporaryChanged = Notification.Name("episcope.showTemporaryChanged")
    // Same, for the toggle that ties the table to the chart window.
    static let signalChartWindowOnlyChanged = Notification.Name("episcope.chartWindowOnlyChanged")
    // Fired by ReportStore.save() whenever an analysis report is written (a
    // background daily/weekly insight, or a user-run retro/question).
    // MainWindowController refreshes the unread badge on the Insights item.
    static let insightsReportsChanged = Notification.Name("episcope.insightsReportsChanged")
    // Fired by ReportsWindowController when a run starts or ends, so the
    // toolbar's ✦ can pulse for as long as the analysis is in flight.
    static let insightsRunStateChanged = Notification.Name("episcope.insightsRunStateChanged")
}

// Single-window list of every Claude session the indexer has seen.
// View-based NSOutlineView with a top-mounted NSSearchField. Sorted
// by Last Activity (descending) by default; clicking a column header
// re-sorts. Double-click on a row opens the cwd in Finder and copies
// the sessionId, matching the menu-bar behaviour.
//
// Two display modes: flat (every session at root) and grouped
// (directories with >1 session collapse under an expandable header).
// Expansion state is preserved across reloads keyed by cwd.

@MainActor
// NSMenuItemValidation is declared here rather than left implicit: without the
// conformance validateMenuItem is not @objc, AppKit never finds it, and every
// row action stays enabled on a row it does not apply to.
final class MainWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let indexer: SessionIndexer
    private let monitor: SessionMonitor
    private let searchIndex: SearchIndex
    private var allEntries: [SessionIndexEntry] = []
    private var filteredEntries: [SessionIndexEntry] = []
    private var searchTerm: String = ""
    // Embedded full-text search view (card feed), shown in-window as a third
    // mode — like the messages/transcript view, not a separate window.
    private let searchVC: SearchViewController
    private let reportsWC: ReportsWindowController
    private enum WindowMode { case list, details, search, insights }
    private var windowMode: WindowMode = .list
    // Where "back" returns from details: the list, search feed or Insights,
    // depending on where the session was opened.
    private var detailsReturnMode: WindowMode = .list
    // Claude has no per-session effort in the transcript — only the
    // global effortLevel in settings.json. Refreshed on each reindex.
    private var claudeEffort: String?
    // Transcript-search state — populated by highlightTranscriptMatches
    // and advanced one step on every Enter while in details mode.
    private var transcriptMatches: [NSRange] = []
    // Pending fade-out of the whole-message wash applied when jumping from search.
    private var messageWashFade: DispatchWorkItem?
    private var transcriptCurrentMatch: Int = -1

    private let outlineView = CenteredOutlineView()
    private let chartView = TokenChartView()
    private let sessionChartView = SessionUsageChartView()
    // Details gives the chart slot more room: the per-session view stacks the
    // lifecycle strip under the curves, and 110pt leaves the curves squashed.
    // Everything in that slot is pinned to chartView, so one constant moves
    // the divider and the table with it.
    private static let listChartHeight: CGFloat = 110
    private static let detailsChartHeight: CGFloat = 168
    private var chartHeight = NSLayoutConstraint()
    // Totals for what the table currently shows, under the rows they add up.
    private let totalsRow = TotalsRowView()
    private var totalsHeight = NSLayoutConstraint()
    private let limitChartView = LimitChartView()
    // Ticks the limit gauges' reset countdown while a limit mode is on.
    private var limitTickTimer: Timer? { willSet { limitTickTimer?.invalidate() } }
    private let chartModeControl = NSSegmentedControl(
        labels: ["Tokens", "Costs", "Rows", "Limits"], trackingMode: .selectOne,
        target: nil, action: nil
    )
    // Real NSToolbar (unified) — one per mode, swapped on entering /
    // leaving details. Items use image + action (no custom button
    // views), so macOS renders them with the native treatment (capsule
    // groups / Liquid Glass on macOS 26). Selection-dependent actions
    // enable/disable via validateToolbarItem instead of hiding, the way
    // Activity Monitor does.
    private lazy var listToolbar = makeToolbar(id: "episcope.toolbar.list", centered: [.chartMode])
    private lazy var detailsToolbar = makeToolbar(id: "episcope.toolbar.details", centered: [])
    private lazy var searchToolbar = makeToolbar(id: "episcope.toolbar.search", centered: [])
    private lazy var insightsToolbar = makeToolbar(id: "episcope.toolbar.insights", centered: [])
    // The Insights toolbar item is view-based so it can carry an unread badge:
    // a dot shown when a report was created since the user last opened Insights.
    private let insightsButton = NSButton()
    private lazy var insightsIcon = PearlescentToolbarIconView(image: Self.toolbarSymbol(
        "sparkles", accessibilityDescription: "Insights"))
    private let insightsBadge: NSView = {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = true
        return dot
    }()
    private static let insightsLastSeenKey = "insightsLastSeen"
    // Pulse while an analysis runs (see refreshInsightsRunPulse).
    private var insightsPulseTimer: Timer?
    private var insightsPulseOn = true
    private static let insightsPulseAlpha: CGFloat = 0.3
    // Each mode owns its search field: scopes search different things
    // and queries must not leak across (placeholders are fixed too).
    private let listSearchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private let detailsSearchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private let deepSearchItem = NSSearchToolbarItem(itemIdentifier: .deepSearchField)
    // The copy items (one per toolbar) flip to a checkmark for a beat
    // after copying — toolbar labels are hidden in icon mode, so the
    // feedback has to live in the image.
    private var copyItems: [NSToolbarItem] = []
    // One instance lives in the list toolbar and one in details. Their image
    // follows the selected session's hosting application (Ghostty, IDEA, etc.)
    // while both keep the same exact-session action.
    private var openSessionItems: [NSToolbarItem] = []
    private var copyResetWork: DispatchWorkItem?
    // The reindex toolbar item is a view that swaps between a refresh
    // button and a spinner while the indexer is still scanning.
    private let reindexButton = NSButton()
    private let reindexSpinner = NSProgressIndicator()
    // TextKit 2 enables view-backed attachments: wide Markdown tables can
    // scroll horizontally while the surrounding conversation still wraps.
    private let transcriptView = NSTextView(usingTextLayoutManager: true)
    private let transcriptScroll = NSScrollView()
    private let divider = NSBox()
    // Shown over the table when it has no rows. An overlay rather than a row,
    // so an empty table costs no layout and the header stays put.
    private let emptyLabel = NSTextField(labelWithString: "")
    // Undoes every narrowing at once. Also an overlay, and only on screen while
    // there is something to undo — the table's normal state gains nothing.
    private let clearFiltersButton = NSButton(title: "", target: nil, action: nil)
    private var outsideClickMonitor: Any?
    // Non-nil while the window is in transcript-detail mode for that
    // session. setMode() flips view visibility based on this.
    private var detailEntry: SessionIndexEntry?
    // Set by AppDelegate: opens the Reports window's New Analysis sheet
    // seeded with the given session (keeps this controller decoupled
    // from the reports window).
    // Insights is a fleet-level mode embedded in this window (à la deep search),
    // never tied to a selected session — see enterInsights().

    // Time range brushed on the fleet chart, if any. It narrows the table to
    // the sessions that billed tokens in that window — deliberately not
    // persisted: it is a question you ask of the chart in front of you, and a
    // filter that outlived a relaunch would look like a missing session list.
    private var chartSelection: TokenChartView.Selection?

    private static let groupByDirKey = "groupByDirectory"
    private var groupByDir: Bool {
        get { UserDefaults.standard.bool(forKey: Self.groupByDirKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.groupByDirKey) }
    }

    // Tree node — NSOutlineView identifies items by pointer, so the
    // tree uses class instances rather than enum values. `kind` is a
    // var so a refresh that doesn't change the tree shape can update
    // entry data in place, keeping node identity (and with it the
    // outline's selection / expansion / scroll position) intact.
    final class OutlineNode {
        enum Kind {
            case group(cwd: String, children: [OutlineNode])
            case session(SessionIndexEntry)
        }
        var kind: Kind
        init(_ kind: Kind) { self.kind = kind }

        var children: [OutlineNode] {
            if case let .group(_, kids) = kind { return kids }
            return []
        }
        var isExpandable: Bool {
            if case .group = kind { return true }
            return false
        }
        var groupCwd: String? {
            if case let .group(cwd, _) = kind { return cwd }
            return nil
        }
        var session: SessionIndexEntry? {
            if case let .session(e) = kind { return e }
            return nil
        }
    }

    private var rootNodes: [OutlineNode] = []
    // sessionId -> last live composite actually painted into its row, so
    // liveStateChanged only reloads rows whose badge truly changed.
    private var lastRenderedLive: [String: String] = [:]
    // Computed once per window-open on the background queue and held
    // until windowWillClose clears it. Nil means "not yet computed".
    private var chartComputed = false
    // Set of cwds whose group nodes the user has explicitly collapsed.
    // Everything not in this set stays expanded after reloads. Default
    // is "expanded" because the whole point of grouping is to see the
    // sessions immediately the first time around.
    private var collapsedCwds: Set<String> = []
    // True while we're programmatically expanding/collapsing rows
    // (so the delegate notifications don't mutate collapsedCwds).
    private var bulkUpdate = false

    private static let showTempKey = "showTemporarySessions"
    private var showTemporary: Bool {
        get { UserDefaults.standard.bool(forKey: Self.showTempKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.showTempKey) }
    }

    // Off by default: the table is the whole history, and the chart window is a
    // reading of the recent part of it. Turning this on makes them one view.
    private static let chartWindowOnlyKey = "limitTableToChartWindow"
    private var chartWindowOnly: Bool {
        UserDefaults.standard.bool(forKey: Self.chartWindowOnlyKey)
    }

    private enum ColumnID {
        static let colorDot = NSUserInterfaceItemIdentifier("col.colorDot")
        static let permWait = NSUserInterfaceItemIdentifier("col.permWait")
        static let sessionColor = NSUserInterfaceItemIdentifier("col.sessionColor")
        // Raw string kept as "col.kitty" for saved column-state compat.
        static let terminal = NSUserInterfaceItemIdentifier("col.kitty")
        static let status = NSUserInterfaceItemIdentifier("col.status")
        static let path = NSUserInterfaceItemIdentifier("col.path")
        static let name = NSUserInterfaceItemIdentifier("col.name")
        static let title = NSUserInterfaceItemIdentifier("col.title")
        static let model = NSUserInterfaceItemIdentifier("col.model")
        static let startedAt = NSUserInterfaceItemIdentifier("col.startedAt")
        static let userMessages = NSUserInterfaceItemIdentifier("col.userMessages")
        static let turns = NSUserInterfaceItemIdentifier("col.turns")
        static let branch = NSUserInterfaceItemIdentifier("col.branch")
        static let inputTokens = NSUserInterfaceItemIdentifier("col.input")
        static let changes = NSUserInterfaceItemIdentifier("col.changes")
        static let cacheReadTokens = NSUserInterfaceItemIdentifier("col.cacheRead")
        static let outputTokens = NSUserInterfaceItemIdentifier("col.output")
        static let cost = NSUserInterfaceItemIdentifier("col.cost")
        static let activity = NSUserInterfaceItemIdentifier("col.activity")
    }

    init(indexer: SessionIndexer, monitor: SessionMonitor, searchIndex: SearchIndex,
         reports: ReportsWindowController) {
        self.indexer = indexer
        self.monitor = monitor
        self.searchIndex = searchIndex
        self.searchVC = SearchViewController(indexer: indexer, searchIndex: searchIndex)
        self.reportsWC = reports

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EpiScope"
        window.minSize = NSSize(width: 480, height: 240)
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        // No tabbing → AppKit drops the auto-injected "Show Tab Bar" /
        // "Merge All Windows" items from the View menu.
        window.tabbingMode = .disallowed
        // Drop the hairline the unified toolbar otherwise draws between
        // itself and the content (the chart sits directly below it).
        window.titlebarSeparatorStyle = .none

        super.init(window: window)
        window.delegate = self
        setupUI()
        reportsWC.onOpenSession = { [weak self] sessionId in
            self?.openSessionLikeTableRow(sessionId: sessionId)
        }

        indexer.onUpdate = { [weak self] in self?.refreshFromIndex() }
        indexer.onProgress = { [weak self] in self?.refreshStatusLabel() }
        refreshFromIndex()

        // Repaint rows in place when the live status of a session
        // changes (busy → idle, etc.) without rebuilding the tree —
        // much cheaper than reloadData on every poll.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveStateChanged),
            name: .signalLiveStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowTemporaryChanged),
            name: .signalShowTemporaryChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChartWindowOnlyChanged),
            name: .signalChartWindowOnlyChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshInsightsBadge),
            name: .insightsReportsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshInsightsRunPulse),
            name: .insightsRunStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionSourcesChanged),
            name: .sessionSourcesChanged,
            object: nil
        )
        // Seed "last seen" on first run so pre-existing reports don't badge;
        // only insights created from here on count as unread.
        if UserDefaults.standard.object(forKey: Self.insightsLastSeenKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.insightsLastSeenKey)
        }
        refreshInsightsBadge()

        // Window-local left-mouse-down monitor: any click that lands
        // outside the outline's scroll view (chart area, divider,
        // toolbar gap, etc.) clears the row selection — same intent
        // as Esc, just discoverable via the mouse.
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleWindowClick(event) }
            return event
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    private func handleWindowClick(_ event: NSEvent) {
        // Only events targeted at our window matter; menu bar and
        // system tray clicks fly past.
        guard event.window === window else { return }
        guard outlineView.selectedRow != -1 else { return }
        guard let contentView = window?.contentView else { return }
        // Toolbar / title-bar clicks live outside contentView (unified
        // toolbar sits in the title-bar view hierarchy). Those buttons —
        // Copy, Messages — act on the current selection, so leaving it
        // alone here is what lets their action see a selected row.
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(pointInContent) else { return }
        guard let scroll = outlineView.enclosingScrollView else { return }
        // Inside the table (incl. its scrollbar) → leave the selection
        // alone; AppKit's normal click handling takes over.
        let frameInWindow = scroll.convert(scroll.bounds, to: nil)
        if frameInWindow.contains(event.locationInWindow) { return }
        // Outside the table but still in the content area → skip if the
        // click landed on a control whose action depends on the selection.
        var hit = contentView.hitTest(pointInContent)
        while let view = hit {
            if view is NSControl { return }
            hit = view.superview
        }
        outlineView.deselectAll(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func show() {
        // Promote to a regular app the first time the window opens so
        // we get a proper Dock icon, Mission Control entry, App menu,
        // etc. We stay .regular for the rest of the process lifetime —
        // toggling back to .accessory makes the status item flake out,
        // and keeping the Dock icon around is what the user expects
        // once they've explicitly opened the window.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if window?.frame.origin == .zero {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Pull fresh data immediately and restart the background
        // sweep (it pauses while the window is closed) — cached
        // entries stay visible while it runs.
        refreshFromIndex()
        indexer.resume()
        applyChartMode()
        // A run may have started while the window was closed.
        refreshInsightsRunPulse()
    }

    private func computeChartIfNeeded() {
        guard !chartComputed else { return }
        chartComputed = true
        TokenChartView.computeBuckets(
            externalEntries: indexer.entries.filter(\.isExternalSource)
        ) { [weak self] buckets, windowEnd in
            self?.chartView.setBuckets(buckets, windowEnd: windowEnd)
        }
        // Overlay the rate-limit window starts (5h + weekly) as markers.
        LimitChart.windowMarkers { [weak self] s5h, weekly in
            self?.chartView.session5hStarts = s5h
            self?.chartView.weeklyStarts = weekly
        }
    }

    // Picks what the aggregate chart shows for the current mode and
    // drives its compute. Details mode steps aside for the per-session
    // chart. In list mode either the token chart (Tokens/Costs/Rows) or,
    // for "Limits", the gauge + capacity-track view (LimitChartView).
    private func applyChartMode() {
        syncModeControlSelection()
        if detailEntry != nil {
            chartView.isHidden = true
            limitChartView.isHidden = true
            limitTickTimer = nil
            return
        }
        if LimitChart.mode == .none {
            limitChartView.isHidden = true
            limitTickTimer = nil
            chartView.isHidden = false
            computeChartIfNeeded()
        } else {
            // The brush lives on the token chart. Leaving it filtering the
            // table from behind the Limits gauges would read as sessions
            // having gone missing.
            chartView.clearSelection()
            chartView.isHidden = true
            limitChartView.isHidden = false
            limitChartView.loading = true
            LimitChart.compute { [weak self] data in
                self?.limitChartView.loading = false
                self?.limitChartView.data = data
            }
            startLimitTicker()
        }
    }

    // Reflect the active chart selection in the segmented control:
    // Tokens / Costs / Rows for the token chart, Limits for the 5h view.
    private func syncModeControlSelection() {
        if LimitChart.mode == .session5h {
            chartModeControl.selectedSegment = 3
        } else {
            switch chartView.valueMode {
            case .tokens: chartModeControl.selectedSegment = 0
            case .cost:   chartModeControl.selectedSegment = 1
            case .lines:  chartModeControl.selectedSegment = 2
            }
        }
    }

    private func startLimitTicker() {
        guard limitTickTimer == nil else { return }
        // The countdown is shown in minutes, so 30 s cadence is plenty.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.limitChartView.needsDisplay = true }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        limitTickTimer = t
    }

    // Settings (window / bar size / limit mode / cap) changed — drop the
    // token cache and re-render whatever mode is now active.
    func reloadChart() {
        TokenChartView.flushCache()
        chartComputed = false
        chartView.reset()
        applyChartMode()
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the cached chart so the next window-open recomputes.
        chartComputed = false
        limitTickTimer = nil
        // Nothing to pulse at while the window is gone; show() picks it up
        // again if the run is still going.
        insightsPulseTimer?.invalidate()
        insightsPulseTimer = nil
        // Nobody is looking — stop the 2-second sweep until the
        // window comes back. show() resumes it.
        indexer.pause()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        indexer.pause()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        indexer.resume()
        refreshFromIndex()
    }

    // MARK: - Layout

    private func setupUI() {
        guard let content = window?.contentView else { return }

        // Chart selection (Tokens / $ / ±LOC / Limits) — the centered
        // toolbar item, Activity Monitor-style. Lives only in the list
        // toolbar; details mode has no aggregate chart to switch. The
        // selected segment is synced in applyChartMode().
        chartModeControl.target = self
        chartModeControl.action = #selector(chartModeChanged)

        chartView.onSelectionChange = { [weak self] selection in
            guard let self else { return }
            self.chartSelection = selection
            self.applyFilter(forceReorder: true)
            self.refreshStatusLabel()
        }
        // A click on the chart means "show me everything again", so it drops the
        // row selection along with the range. The chart is the one place both
        // narrowings are visible at once — the brushed span and the highlighted
        // segment — which makes it the honest place to undo them, and it costs
        // no button. Esc and a click below the last row still do it too.
        chartView.onBackgroundClick = { [weak self] in
            self?.outlineView.deselectAll(nil)
        }
        // Names for the chart's series. Grouped by directory the key already is
        // a cwd; otherwise it is a session id, which only the index can turn
        // into something a person recognises.
        chartView.seriesLabel = { [weak self] key in
            guard let self else { return key }
            if let entry = allEntries.first(where: { $0.sessionId == key }) {
                let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { return entry.folderName }
                // Only the AI-written title is clipped. The project is what
                // identifies the row, and it is short — spending the budget on
                // a sentence would leave the name it belongs to cut off.
                let limit = 30
                let clipped = title.count <= limit
                    ? title
                    : String(title.prefix(limit - 1))
                        .trimmingCharacters(in: .whitespaces) + "…"
                return "\(entry.folderName) · \(clipped)"
            }
            // A cwd (grouping mode) or a session the index has since dropped.
            return key.hasPrefix("/")
                ? URL(fileURLWithPath: key).lastPathComponent
                : key
        }

        for (item, placeholder) in [
            (listSearchItem, "Filter by title, project or session id"),
            (detailsSearchItem, "Search in transcript"),
            (deepSearchItem, "Search all sessions"),
        ] {
            let field = item.searchField
            field.placeholderString = placeholder
            field.delegate = self
            // Enter (or Cmd-G) → advance to the next transcript match.
            field.target = self
            field.action = #selector(searchFieldDidSubmit)
            // Without this, the action fires on every focus loss; we only
            // want it on Enter so it can act as "find next".
            field.cell?.sendsActionOnEndEditing = false
            item.preferredWidthForSearchField = 260
        }

        window?.toolbarStyle = .unified
        window?.toolbar = listToolbar

        chartView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chartView)

        // Per-session chart overlays the aggregate chart in details mode.
        sessionChartView.translatesAutoresizingMaskIntoConstraints = false
        sessionChartView.isHidden = true
        content.addSubview(sessionChartView)

        // Rate-limit view overlays the aggregate chart's slot in list
        // mode when a limit window mode is selected.
        limitChartView.translatesAutoresizingMaskIntoConstraints = false
        limitChartView.isHidden = true
        content.addSubview(limitChartView)

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        content.addSubview(divider)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        content.addSubview(scroll)

        // Transcript pane — same slot as the outline scroll, swapped on
        // mode change. Compact text view: small font, tight spacing.
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.isHidden = true
        transcriptScroll.documentView = transcriptView
        transcriptView.isEditable = false
        transcriptView.isRichText = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 20, height: 14)
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        // Two of the messages carry a second line telling the operator how to
        // get the rows back; a label is single-line until told otherwise.
        emptyLabel.usesSingleLineMode = false
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true
        content.addSubview(emptyLabel)

        clearFiltersButton.translatesAutoresizingMaskIntoConstraints = false
        clearFiltersButton.bezelStyle = .rounded
        clearFiltersButton.controlSize = .small
        clearFiltersButton.font = .systemFont(ofSize: 11)
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearAllFilters)
        clearFiltersButton.isHidden = true
        content.addSubview(clearFiltersButton)

        content.addSubview(transcriptScroll)

        totalsRow.translatesAutoresizingMaskIntoConstraints = false
        totalsRow.table = outlineView
        content.addSubview(totalsRow)

        configureOutline()
        restoreColumnVisibility()
        scroll.documentView = outlineView
        totalsRow.observe(scrollView: scroll)
        // Right-click the header to pick columns. The header is where a user
        // looks for this first; Settings → Columns stays as the discoverable
        // path and both drive the same toggle, so their ticks cannot disagree.
        outlineView.headerView?.menu = columnsMenu

        chartHeight = chartView.heightAnchor.constraint(equalToConstant: Self.listChartHeight)
        // Collapsed to nothing outside the list, and while the table is empty:
        // a strip of zeroes under no rows is noise.
        totalsHeight = totalsRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            chartView.topAnchor.constraint(equalTo: content.topAnchor),
            chartView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chartView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chartHeight,

            sessionChartView.topAnchor.constraint(equalTo: chartView.topAnchor),
            sessionChartView.leadingAnchor.constraint(equalTo: chartView.leadingAnchor),
            sessionChartView.trailingAnchor.constraint(equalTo: chartView.trailingAnchor),
            sessionChartView.bottomAnchor.constraint(equalTo: chartView.bottomAnchor),

            limitChartView.topAnchor.constraint(equalTo: chartView.topAnchor),
            limitChartView.leadingAnchor.constraint(equalTo: chartView.leadingAnchor),
            limitChartView.trailingAnchor.constraint(equalTo: chartView.trailingAnchor),
            limitChartView.bottomAnchor.constraint(equalTo: chartView.bottomAnchor),

            divider.topAnchor.constraint(equalTo: chartView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: totalsRow.topAnchor),

            totalsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            totalsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            totalsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            totalsHeight,

            // Centred on the rows area, below the header the table keeps drawing.
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 96),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -24),

            // Bottom centre: the columns that carry text sit left and right of
            // it, so a pill here covers the least. Floating over the rows
            // rather than above them keeps the table's geometry fixed whether
            // a filter is on or off.
            clearFiltersButton.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            clearFiltersButton.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),

            transcriptScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])

        // Embedded search feed — fills the whole content, shown only in search
        // mode (it covers the chart + table). Its own field sits at the top.
        let searchView = searchVC.view
        searchView.translatesAutoresizingMaskIntoConstraints = false
        searchView.isHidden = true
        content.addSubview(searchView)
        NSLayoutConstraint.activate([
            searchView.topAnchor.constraint(equalTo: content.topAnchor),
            searchView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Embedded Insights (fleet reports) — same full-content treatment as the
        // search feed, shown only in insights mode.
        let reportsView = reportsWC.embeddableView()
        reportsView.translatesAutoresizingMaskIntoConstraints = false
        reportsView.isHidden = true
        content.addSubview(reportsView)
        NSLayoutConstraint.activate([
            reportsView.topAnchor.constraint(equalTo: content.topAnchor),
            reportsView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            reportsView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            reportsView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        searchVC.onOpenResult = { [weak self] sessionId, query, locator in
            self?.showMessages(sessionId: sessionId, highlight: query, scrollTo: locator)
        }
    }

    private func configureOutline() {
        outlineView.dataSource = self
        outlineView.delegate = self
        // Zebra is painted by AdaptiveRowView as rounded inset capsules
        // (matching the selection shape), so the system's full-width
        // flat stripes are turned off.
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.gridStyleMask = []
        outlineView.rowSizeStyle = .custom
        // .inset is the modern table look (rounded selection, breathing
        // room at the edges) — what Activity Monitor ships on current
        // macOS. The hand-painted zebra still spans the full row.
        outlineView.style = .inset
        outlineView.allowsMultipleSelection = false
        // So clicking on empty space below the rows clears the chart
        // highlight back to the all-sessions view.
        outlineView.allowsEmptySelection = true
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.target = self
        outlineView.menu = makeRowContextMenu()
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = false
        outlineView.rowHeight = 30
        // We size each column individually below — Title is the only
        // one allowed to flex (resizingMask = .autoresizingMask). The
        // sequential autoresizing style pushes leftover space onto
        // whichever flexible columns are visible.
        outlineView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle

        // Default order: 1 Color, 2 Vendor icon, 3 Model, 4 Status,
        // 5 Path, 6 Title, 7 Input, 8 Last Activity. Everything else
        // (Name / Started / User msgs / Branch / Cache / Output / Cost)
        // ships hidden; users can re-enable them from Settings → Columns.

        let sessionColor = NSTableColumn(identifier: ColumnID.sessionColor)
        sessionColor.title = "Color"
        sessionColor.width = 14
        sessionColor.minWidth = 14
        sessionColor.maxWidth = 14
        outlineView.addTableColumn(sessionColor)

        let colorDot = NSTableColumn(identifier: ColumnID.colorDot)
        colorDot.title = "AI"
        colorDot.width = 28
        colorDot.minWidth = 28
        colorDot.maxWidth = 28
        outlineView.addTableColumn(colorDot)

        let terminal = NSTableColumn(identifier: ColumnID.terminal)
        terminal.title = "App"
        terminal.width = 34
        terminal.minWidth = 34
        terminal.maxWidth = 34
        outlineView.addTableColumn(terminal)

        let model = NSTableColumn(identifier: ColumnID.model)
        model.title = "Model"
        model.width = 140
        model.minWidth = 80
        model.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.model.rawValue, ascending: true)
        outlineView.addTableColumn(model)

        // Live-status badge: Waiting (red bg) / Busy (animated dots)
        // / Error / Idle / "—". Empty when the session is not currently running.
        let status = NSTableColumn(identifier: ColumnID.status)
        status.title = "Status"
        status.width = 84
        status.minWidth = 60
        outlineView.addTableColumn(status)

        // Cumulative time the session has sat parked on permission
        // prompts (SessionMonitor's wait clocks). Ticks live while a
        // session is waiting.
        let permWait = NSTableColumn(identifier: ColumnID.permWait)
        permWait.title = "Perm Wait"
        permWait.width = 76
        permWait.minWidth = 56
        permWait.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.permWait.rawValue, ascending: false)
        permWait.isHidden = true
        outlineView.addTableColumn(permWait)

        let path = NSTableColumn(identifier: ColumnID.path)
        path.title = "Path"
        path.width = 250
        path.minWidth = 140
        path.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.path.rawValue, ascending: true)
        outlineView.addTableColumn(path)
        outlineView.outlineTableColumn = path  // disclosure arrows + group indentation live here

        let title = NSTableColumn(identifier: ColumnID.title)
        title.title = "Title"
        title.width = 250
        title.minWidth = 160
        title.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.title.rawValue, ascending: true)
        // Title is the elastic column: it absorbs the toolbar's
        // leftover space whenever the window grows, while every
        // other column keeps its natural width.
        title.resizingMask = [.autoresizingMask, .userResizingMask]
        outlineView.addTableColumn(title)

        let input = NSTableColumn(identifier: ColumnID.inputTokens)
        input.title = "Input"
        input.width = 80
        input.minWidth = 60
        input.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.inputTokens.rawValue, ascending: false)
        outlineView.addTableColumn(input)

        // Lines of code the session's edits touched: "+123 −45",
        // green/red. Sorts by total churn.
        let changes = NSTableColumn(identifier: ColumnID.changes)
        changes.title = "Changes"
        changes.width = 110
        changes.minWidth = 80
        changes.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.changes.rawValue, ascending: false)
        outlineView.addTableColumn(changes)

        // Hidden-by-default columns follow. Users can flip them on
        // from Settings → Columns; the picker preserves rendering
        // order based on the addTableColumn sequence.

        let name = NSTableColumn(identifier: ColumnID.name)
        name.title = "Name"
        name.width = 160
        name.minWidth = 80
        name.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)
        name.isHidden = true
        outlineView.addTableColumn(name)

        let startedAt = NSTableColumn(identifier: ColumnID.startedAt)
        startedAt.title = "Started"
        startedAt.width = 120
        startedAt.minWidth = 80
        startedAt.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.startedAt.rawValue, ascending: false)
        startedAt.isHidden = true
        outlineView.addTableColumn(startedAt)

        let userMessages = NSTableColumn(identifier: ColumnID.userMessages)
        userMessages.title = "User msgs"
        userMessages.width = 70
        userMessages.minWidth = 50
        userMessages.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.userMessages.rawValue, ascending: false)
        userMessages.isHidden = true
        outlineView.addTableColumn(userMessages)

        // Model turns (agentic steps) — assistant responses, which a
        // tool-looping session racks up far faster than user messages.
        let turns = NSTableColumn(identifier: ColumnID.turns)
        turns.title = "Turns"
        turns.width = 60
        turns.minWidth = 50
        turns.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.turns.rawValue, ascending: false)
        turns.isHidden = true
        outlineView.addTableColumn(turns)

        let branch = NSTableColumn(identifier: ColumnID.branch)
        branch.title = "Branch"
        branch.width = 120
        branch.minWidth = 80
        branch.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.branch.rawValue, ascending: true)
        branch.isHidden = true
        outlineView.addTableColumn(branch)

        let cacheRead = NSTableColumn(identifier: ColumnID.cacheReadTokens)
        cacheRead.title = "Cache"
        cacheRead.width = 80
        cacheRead.minWidth = 60
        cacheRead.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.cacheReadTokens.rawValue, ascending: false)
        cacheRead.isHidden = true
        outlineView.addTableColumn(cacheRead)

        let output = NSTableColumn(identifier: ColumnID.outputTokens)
        output.title = "Output"
        output.width = 80
        output.minWidth = 60
        output.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.outputTokens.rawValue, ascending: false)
        output.isHidden = true
        outlineView.addTableColumn(output)

        let cost = NSTableColumn(identifier: ColumnID.cost)
        cost.title = "Cost"
        cost.width = 75
        cost.minWidth = 60
        cost.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.cost.rawValue, ascending: false)
        cost.isHidden = true
        outlineView.addTableColumn(cost)

        let activity = NSTableColumn(identifier: ColumnID.activity)
        activity.title = "Last Activity"
        activity.width = 130
        activity.minWidth = 100
        activity.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.activity.rawValue, ascending: false)
        outlineView.addTableColumn(activity)

        outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.activity.rawValue, ascending: false)]
        applyGroupingColumns(groupByDir)
    }

    // MARK: - Data

    private func refreshFromIndex() {
        // The table isn't on screen — skip the whole filter / sort /
        // tree pipeline. show() and windowDidDeminiaturize refresh
        // explicitly when the window comes back.
        guard window?.isVisible == true else { return }
        // Drop temporary sessions before they reach the table so they
        // neither show up in the counter nor flood the rest of the
        // pipeline. The indexer itself is also told to skip them (so
        // they don't contribute to the loading indicator either).
        let raw = indexer.entries
        var kept = showTemporary ? raw : raw.filter { !$0.isTemporary }
        // Same footing as Show Temporary: a setting, applied before the table
        // counts anything, rather than a narrowing the operator undoes here.
        if chartWindowOnly {
            let start = Date().addingTimeInterval(-Double(TokenChartView.windowDays) * 24 * 3600)
            kept = kept.filter { $0.lastActivity >= start }
        }
        allEntries = kept
        claudeEffort = Self.readClaudeEffort()
        applyFilter()
    }

    // The global Claude reasoning effort from ~/.claude/settings.json
    // (there's no per-session value in the transcripts).
    private static func readClaudeEffort() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let level = obj["effortLevel"] as? String, !level.isEmpty
        else { return nil }
        return level
    }

    private func applyFilter(forceReorder: Bool = false) {
        let term = searchTerm.lowercased()
        let brushed = chartSelection?.sessionIds
        filteredEntries = allEntries.filter { e in
            if let brushed, !brushed.contains(e.sessionId) { return false }
            if term.isEmpty { return true }
            return e.relativePath.lowercased().contains(term)
                || (e.title?.lowercased().contains(term) ?? false)
                || e.sessionId.lowercased().contains(term)
                || e.cwd.lowercased().contains(term)
        }
        sortFilteredEntries()
        let newRoots = makeTree(from: filteredEntries)

        // A user sort-header click (forceReorder) always takes the full reload,
        // so the freshly-sorted order is actually applied to the rows.
        if !forceReorder, Self.sameTreeMembership(newRoots, rootNodes) {
            // Same sessions / groups present — only their data may have
            // changed (a session accumulating tokens). Update the matching
            // existing nodes in place (by session id) and repaint only the
            // changed rows; selection, expansion and scroll are untouched.
            // The row ORDER is deliberately left as-is: re-applying the sort on
            // every tick would reshuffle rows and force a full reloadData.
            // Order re-sorts on the next add/remove, manual reindex or sort.
            adoptEntriesById(from: newRoots)
        } else {
            // NSOutlineView resets selection on reloadData. Remember
            // the selected sessionId so the background indexer's
            // progressive refreshes don't keep wiping the user's
            // selection mid-click.
            let previouslySelected = selectedSession()?.sessionId
            rootNodes = newRoots
            outlineView.reloadData()
            restoreExpansionState()
            restoreSelection(sessionId: previouslySelected)
        }

        refreshStatusLabel()
        refreshEmptyState()
        refreshTotals()
    }

    // Sums of what the table is showing — the filtered set, not the index, so a
    // dragged range or a search term is answered with its own total rather than
    // the fleet's. Only columns whose figures add up get one: a sum of models or
    // of last-activity times would be a number that means nothing.
    private func refreshTotals() {
        let visible = windowMode == .list && !filteredEntries.isEmpty
        totalsHeight.constant = visible ? TotalsRowView.height : 0
        totalsRow.isHidden = !visible
        guard visible else { return }

        var input: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0
        var added: Int64 = 0, removed: Int64 = 0
        var cost = 0.0
        var turns = 0, userMessages = 0
        var waited: TimeInterval = 0
        for e in filteredEntries {
            input += e.inputTokens + e.cacheCreationTokens
            cacheRead += e.cacheReadTokens
            output += e.outputTokens
            added += e.linesAdded
            removed += e.linesRemoved
            cost += e.costUSD
            turns += e.turns
            userMessages += e.userMessageCount
            waited += monitor.permissionWait(for: e.sessionId)
        }

        let count = filteredEntries.count
        // The label goes in the first wide column still on screen; with Path
        // hidden it would otherwise be a strip of figures nobody labelled.
        let labelColumn = [ColumnID.path, ColumnID.title, ColumnID.name, ColumnID.model]
            .first { id in
                outlineView.tableColumns.contains { $0.identifier == id && !$0.isHidden }
            } ?? ColumnID.path
        var values: [NSUserInterfaceItemIdentifier: String] = [
            labelColumn: "Total · \(count) session\(count == 1 ? "" : "s")",
            ColumnID.inputTokens: Self.formatTokens(input),
            ColumnID.cacheReadTokens: Self.formatTokens(cacheRead),
            ColumnID.outputTokens: Self.formatTokens(output),
            ColumnID.cost: Self.formatCost(cost),
            ColumnID.turns: turns > 0 ? "\(turns)" : "",
            ColumnID.userMessages: userMessages > 0 ? "\(userMessages)" : "",
        ]
        if added > 0 || removed > 0 {
            values[ColumnID.changes] = "+\(added) −\(removed)"
        }
        if waited >= 1 { values[ColumnID.permWait] = Self.formatWait(waited) }

        totalsRow.setValues(values, alignments: [
            labelColumn: .left,
            ColumnID.inputTokens: .right,
            ColumnID.cacheReadTokens: .right,
            ColumnID.outputTokens: .right,
            ColumnID.cost: .right,
            ColumnID.turns: .right,
            ColumnID.userMessages: .right,
            ColumnID.changes: .right,
            ColumnID.permWait: .right,
        ])
    }

    // What an empty table means, in its own words. Naming the narrowing that
    // emptied it is the point: "no sessions" and "no sessions in the range you
    // dragged" call for different moves, and with the rows gone the range is
    // the only thing still on screen to undo.
    // Narrowings the operator applied by hand, and can therefore be asked to
    // undo. Deliberately not the Show Temporary setting: that one is not a
    // filter someone set on this screen and expects to drop again.
    private var hasActiveFilters: Bool {
        chartSelection != nil
            || !searchTerm.trimmingCharacters(in: .whitespaces).isEmpty
            || outlineView.selectedRow >= 0
    }

    private func refreshFilterButton() {
        clearFiltersButton.isHidden = !hasActiveFilters
        // No count: the title bar subtitle already carries "N of M", and a
        // number that changes under the pointer makes the button look like it
        // does something different each time.
        clearFiltersButton.title = "Show all"
    }

    @objc private func clearAllFilters() {
        chartView.clearSelection()      // fires onSelectionChange, which refilters
        chartSelection = nil
        if !searchTerm.isEmpty {
            listSearchItem.searchField.stringValue = ""
            searchTerm = ""
        }
        outlineView.deselectAll(nil)
        applyFilter(forceReorder: true)
        refreshStatusLabel()
    }

    private func refreshEmptyState() {
        refreshFilterButton()
        guard filteredEntries.isEmpty else {
            emptyLabel.isHidden = true
            return
        }
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        let ranged = chartSelection != nil
        let text: String
        switch (allEntries.isEmpty, ranged, term.isEmpty) {
        case (true, _, _):
            let days = TokenChartView.windowDays
            if indexer.pendingDeepScan > 0 {
                text = "Reading sessions…"
            } else if chartWindowOnly, !indexer.entries.isEmpty {
                // The index is not empty — the window is. Name it, since the
                // sessions are there and nothing on this screen says why they
                // are not.
                text = "No sessions in the last \(days == 1 ? "day" : "\(days) days")"
                    + " — Settings → Chart Window Only."
            } else {
                text = "No sessions yet. Start one in Claude Code or Codex and it shows up here."
            }
        case (false, true, false):
            text = "Nothing matching “\(term)” in the selected range."
        case (false, true, true):
            text = "No sessions ran in the selected range."
        case (false, false, false):
            text = "Nothing matching “\(term)”."
        case (false, false, true):
            // Every session is filtered out by something that is not on this
            // screen at all, so the setting has to be named.
            text = showTemporary
                ? "No sessions to show."
                : "No sessions to show. Temporary ones are hidden — Settings → Show Temporary."
        }
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    @objc private func sessionSourcesChanged() {
        refreshFromIndex()
        updateOpenSessionToolbarItems()
        outlineView.reloadData()
    }

    // True when both trees hold the same sessions and the same groups —
    // regardless of order. Order is intentionally ignored so live data
    // updates (which can change the activity sort) still take the cheap
    // in-place adopt path instead of a full reloadData.
    private static func sameTreeMembership(_ a: [OutlineNode], _ b: [OutlineNode]) -> Bool {
        guard a.count == b.count else { return false }
        func topKeys(_ roots: [OutlineNode]) -> Set<String> {
            Set(roots.map { $0.groupCwd.map { "g:" + $0 } ?? "s:" + ($0.session?.sessionId ?? "") })
        }
        guard topKeys(a) == topKeys(b) else { return false }
        // Each group must hold the same child sessions (order-independent).
        func childSets(_ roots: [OutlineNode]) -> [String: Set<String>] {
            var m: [String: Set<String>] = [:]
            for n in roots where n.groupCwd != nil {
                m[n.groupCwd!] = Set(n.children.compactMap { $0.session?.sessionId })
            }
            return m
        }
        return childSets(a) == childSets(b)
    }

    // Membership verified identical by the caller. Copies fresh entry data
    // into the existing nodes matched by session id (NOT by position, so the
    // visible order is preserved) and reloads only the rows that changed.
    private func adoptEntriesById(from newRoots: [OutlineNode]) {
        var fresh: [String: SessionIndexEntry] = [:]
        func collect(_ nodes: [OutlineNode]) {
            for n in nodes {
                if let e = n.session { fresh[e.sessionId] = e }
                collect(n.children)
            }
        }
        collect(newRoots)

        var dirtyNodes: [OutlineNode] = []
        for node in rootNodes {
            if case .group = node.kind {
                var childChanged = false
                for kid in node.children {
                    guard let old = kid.session, let new = fresh[old.sessionId],
                          old != new else { continue }
                    kid.kind = .session(new)
                    dirtyNodes.append(kid)
                    childChanged = true
                }
                // The group row aggregates its children, so repaint it too.
                if childChanged { dirtyNodes.append(node) }
            } else if let old = node.session, let new = fresh[old.sessionId], old != new {
                node.kind = .session(new)
                dirtyNodes.append(node)
            }
        }
        guard !dirtyNodes.isEmpty else { return }
        var rows = IndexSet()
        for node in dirtyNodes {
            let row = outlineView.row(forItem: node)
            // -1 → row not materialised (collapsed group child); the
            // delegate renders fresh data whenever it appears.
            if row >= 0 { rows.insert(row) }
        }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integersIn: 0..<outlineView.tableColumns.count)
        )
    }

    // Walks the rebuilt tree to find the node whose session id matches
    // and re-selects it. Expands the parent group first when grouped.
    private func restoreSelection(sessionId: String?) {
        guard let sessionId else { return }
        for node in rootNodes {
            if let s = node.session, s.sessionId == sessionId {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row),
                                                 byExtendingSelection: false)
                }
                return
            }
            for child in node.children {
                if let s = child.session, s.sessionId == sessionId {
                    bulkUpdate = true
                    outlineView.expandItem(node)
                    bulkUpdate = false
                    let row = outlineView.row(forItem: child)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row),
                                                     byExtendingSelection: false)
                    }
                    return
                }
            }
        }
    }

    // Bring the window forward, show the (unfiltered) session list, and select +
    // scroll to a session — used when a notification is tapped but we don't know
    // where the agent's terminal is.
    func revealSession(sessionId: String) {
        // Leave a fleet-level surface before bringing the window forward.
        // Otherwise show() refreshes the title/data while still in Insights or
        // Search and the subsequently revealed list inherits that stale mode
        // state (most visibly the "Insights" subtitle).
        if windowMode != .list {
            windowMode = .list
            applyMode()
            refreshStatusLabel()
        }
        show()
        // A revealed session must be visible even under an active quick filter,
        // so clear it here (applyMode no longer wipes it on every list entry).
        if !searchTerm.isEmpty {
            listSearchItem.searchField.stringValue = ""
            searchTerm = ""
            applyFilter()
        }
        refreshStatusLabel()
        if selectAndScroll(sessionId: sessionId) { return }
        // No selectable row — e.g. a detached / headless session filtered out
        // of the table (hidden temporary, or a thin transcript). A notification
        // tap must never dead-end, so drill straight into the transcript: the
        // click always lands on the session even when it has no terminal to
        // focus and no live row to highlight.
        if let entry = allEntries.first(where: { $0.sessionId == sessionId })
            ?? indexer.entries.first(where: { $0.sessionId == sessionId }) {
            enterDetailsMode(for: entry)
        }
    }

    @discardableResult
    private func selectAndScroll(sessionId: String) -> Bool {
        func select(_ node: OutlineNode) {
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            window?.makeFirstResponder(outlineView)
        }
        for node in rootNodes {
            if node.session?.sessionId == sessionId { select(node); return true }
            for child in node.children where child.session?.sessionId == sessionId {
                bulkUpdate = true
                outlineView.expandItem(node)
                bulkUpdate = false
                select(child)
                return true
            }
        }
        return false
    }

    // Reindex toolbar item view: a refresh button with a spinner
    // stacked on top, swapped by updateLoadingIndicator().
    private func makeReindexView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        reindexButton.frame = container.bounds
        reindexButton.autoresizingMask = [.width, .height]
        reindexButton.bezelStyle = .texturedRounded
        reindexButton.isBordered = true
        reindexButton.image = Self.toolbarSymbol(
            "arrow.clockwise", accessibilityDescription: "Reindex sessions")
        reindexButton.imagePosition = .imageOnly
        reindexButton.target = self
        reindexButton.action = #selector(reindexNow)
        container.addSubview(reindexButton)

        reindexSpinner.frame = NSRect(x: (30 - 16) / 2, y: (30 - 16) / 2, width: 16, height: 16)
        reindexSpinner.style = .spinning
        reindexSpinner.controlSize = .small
        reindexSpinner.isDisplayedWhenStopped = false
        reindexSpinner.isHidden = true
        container.addSubview(reindexSpinner)
        return container
    }

    // Insights toolbar item view: a bordered button with an unread-badge dot
    // pinned to its top-right corner (mirrors makeReindexView's pattern).
    private func makeInsightsItemView() -> NSView {
        // Keep the custom view square. A wider frame makes the native textured
        // hover background a pill, unlike adjacent toolbar action buttons.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        insightsButton.frame = container.bounds
        insightsButton.autoresizingMask = [.width, .height]
        insightsButton.bezelStyle = .texturedRounded
        insightsButton.isBordered = true
        insightsButton.imagePosition = .imageOnly
        // The native button owns hover/press interaction; the non-interactive
        // overlay supplies the animated pearlescent glyph.
        insightsButton.image = nil
        insightsButton.toolTip = "Insights"
        insightsButton.setAccessibilityLabel("Insights")
        insightsButton.target = self
        insightsButton.action = #selector(showInsights)
        container.addSubview(insightsButton)

        insightsIcon.frame = NSRect(x: 5, y: 5, width: 20, height: 20)
        insightsIcon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.addSubview(insightsIcon)

        let s: CGFloat = 8
        insightsBadge.frame = NSRect(x: container.bounds.width - s - 3,
                                     y: container.bounds.height - s - 2, width: s, height: s)
        insightsBadge.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(insightsBadge)
        // The toolbar rebuilds this item on every mode switch, so a run that is
        // already in flight has to re-arm the pulse on the fresh button.
        refreshInsightsRunPulse()
        return container
    }

    private var insightsLastSeen: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.insightsLastSeenKey)) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.insightsLastSeenKey) }
    }

    // Show the badge when a completed report is newer than the last time the
    // user opened Insights. While Insights is on screen everything counts as
    // seen, so the badge clears and stays clear.
    @objc private func refreshInsightsBadge() {
        if windowMode == .insights {
            insightsLastSeen = Date()
            insightsBadge.isHidden = true
            return
        }
        let newest = reportsWC.newestCompletedReportDate() ?? .distantPast
        insightsBadge.isHidden = newest <= insightsLastSeen
    }

    // An analysis takes minutes and its only other sign is a row in a list the
    // user probably isn't looking at, so the ✦ pulses for as long as the run is
    // in flight. Slower than the menu bar's permission blink on purpose: this
    // is progress, not an alarm.
    @objc private func refreshInsightsRunPulse() {
        let running = reportsWC.isAnalysisRunning
        guard running else {
            insightsPulseTimer?.invalidate()
            insightsPulseTimer = nil
            insightsButton.animator().alphaValue = 1
            insightsIcon.animator().alphaValue = 1
            return
        }
        guard insightsPulseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.insightsPulseOn.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    self.insightsButton.animator().alphaValue =
                        self.insightsPulseOn ? 1 : Self.insightsPulseAlpha
                    self.insightsIcon.animator().alphaValue =
                        self.insightsPulseOn ? 1 : Self.insightsPulseAlpha
                }
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        insightsPulseTimer = timer
    }

    // While the indexer is still deep-scanning, the refresh button is
    // replaced by a live spinner; it returns once the scan finishes.
    private func updateLoadingIndicator() {
        let loading = indexer.pendingDeepScan > 0
        if loading {
            reindexButton.isHidden = true
            reindexSpinner.isHidden = false
            reindexSpinner.startAnimation(nil)
        } else {
            reindexSpinner.stopAnimation(nil)
            reindexSpinner.isHidden = true
            reindexButton.isHidden = false
        }
    }

    private func refreshStatusLabel() {
        updateLoadingIndicator()
        // Insights is fleet-level — it owns the title bar, no session count.
        if windowMode == .insights {
            window?.title = "EpiScope"
            window?.subtitle = "Insights"
            return
        }
        // While the user is reading a single session in details mode,
        // the window title is the session title — don't trample it.
        guard detailEntry == nil else { return }

        // Count goes in the title bar subtitle, under the app name —
        // the Activity Monitor arrangement.
        let total = allEntries.count
        let shown = filteredEntries.count
        let pending = indexer.pendingDeepScan
        let loaded = max(0, indexer.totalDeepScan - pending)
        var text = (shown == total)
            ? "\(total) session\(total == 1 ? "" : "s")"
            : "\(shown) of \(total)"
        if pending > 0 {
            text += "  ·  Loading \(loaded) / \(indexer.totalDeepScan)"
        }
        window?.title = "EpiScope"
        window?.subtitle = text
    }

    private func makeTree(from entries: [SessionIndexEntry]) -> [OutlineNode] {
        if !groupByDir {
            return entries.map { OutlineNode(.session($0)) }
        }
        // Group entries by cwd, preserving the filtered/sorted order
        // within each group. Order between groups follows the current
        // sort: a group is anchored on the index of its first entry
        // in filteredEntries, so an "activity desc" sort yields
        // groups ordered by most-recent-first.
        var groups: [String: [SessionIndexEntry]] = [:]
        var firstIndex: [String: Int] = [:]
        for (idx, e) in entries.enumerated() {
            groups[e.cwd, default: []].append(e)
            if firstIndex[e.cwd] == nil { firstIndex[e.cwd] = idx }
        }
        let cwdsOrdered = groups.keys.sorted { (firstIndex[$0] ?? 0) < (firstIndex[$1] ?? 0) }
        var roots: [OutlineNode] = []
        for cwd in cwdsOrdered {
            let grouped = groups[cwd] ?? []
            if grouped.count > 1 {
                let children = grouped.map { OutlineNode(.session($0)) }
                roots.append(OutlineNode(.group(cwd: cwd, children: children)))
            } else if let only = grouped.first {
                roots.append(OutlineNode(.session(only)))
            }
        }
        return roots
    }

    private func restoreExpansionState() {
        bulkUpdate = true
        defer { bulkUpdate = false }
        for node in rootNodes {
            if case let .group(cwd, _) = node.kind {
                if collapsedCwds.contains(cwd) {
                    outlineView.collapseItem(node)
                } else {
                    outlineView.expandItem(node)
                }
            }
        }
    }

    @objc func handleShowTemporaryChanged() {
        applyFilter()
        // The chart honors the same setting now, so re-render it too.
        if window?.isVisible == true { reloadChart() }
    }

    // Public so AppDelegate's Settings menu can flip it.
    @objc func toggleGroupByDir() {
        groupByDir.toggle()
        updateGroupToolbarItems()
        applyGroupingColumns(groupByDir)
        applyFilter()
        // The chart aggregates per directory vs per session — recompute.
        if window?.isVisible == true { reloadChart() }
    }

    // Grouping pivots the table to directories: the Path column becomes a
    // left-most "Directory" column (where the group headers live), and slides
    // back to its place when grouping is off.
    private func applyGroupingColumns(_ grouping: Bool) {
        guard let path = outlineView.tableColumn(withIdentifier: ColumnID.path),
              let cur = outlineView.tableColumns.firstIndex(of: path) else { return }
        path.title = grouping ? "Directory" : "Path"
        // Index 3 = right after the colour / provider / terminal icon columns.
        let target = grouping ? 3 : 6
        if cur != target, target < outlineView.tableColumns.count {
            outlineView.moveColumn(cur, toColumn: target)
        }
        // The session label now lives in the outline column, so the separate
        // Title column would just duplicate it — hide it while grouping.
        outlineView.tableColumn(withIdentifier: ColumnID.title)?.isHidden = grouping
    }

    // Insert / remove the collapse + expand items live as grouping is
    // toggled (toolbarDefaultItemIdentifiers sets the launch state).
    private func updateGroupToolbarItems() {
        let present = listToolbar.items.contains { $0.itemIdentifier == .collapseAll }
        if groupByDir, !present,
           let idx = listToolbar.items.firstIndex(where: { $0.itemIdentifier == .openTerminal }) {
            listToolbar.insertItem(withItemIdentifier: .collapseAll, at: idx + 1)
            listToolbar.insertItem(withItemIdentifier: .expandAll, at: idx + 2)
        } else if !groupByDir, present {
            if let i = listToolbar.items.firstIndex(where: { $0.itemIdentifier == .expandAll }) {
                listToolbar.removeItem(at: i)
            }
            if let i = listToolbar.items.firstIndex(where: { $0.itemIdentifier == .collapseAll }) {
                listToolbar.removeItem(at: i)
            }
        }
    }

    var isGroupByDirEnabled: Bool { groupByDir }

    @objc private func collapseAll() {
        bulkUpdate = true
        defer { bulkUpdate = false }
        for node in rootNodes {
            if case let .group(cwd, _) = node.kind {
                outlineView.collapseItem(node)
                collapsedCwds.insert(cwd)
            }
        }
    }

    @objc private func expandAll() {
        bulkUpdate = true
        defer { bulkUpdate = false }
        for node in rootNodes {
            if case let .group(cwd, _) = node.kind {
                outlineView.expandItem(node)
                collapsedCwds.remove(cwd)
            }
        }
    }

    // Exposed for AppDelegate so the Settings → Columns submenu can
    // build itself from whatever columns the outline view holds right
    // now. Returns rows like (identifier raw value, header title, isHidden).
    // Rebuilt on every open (menuNeedsUpdate) rather than kept in sync: the
    // same columns can be toggled from Settings, and a stale tick here would be
    // a lie about what the table is showing.
    private lazy var columnsMenu: NSMenu = {
        let menu = NSMenu(title: "Columns")
        menu.delegate = self
        return menu
    }()

    private func rebuildColumnsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for col in columnsForMenu() {
            let item = NSMenuItem(title: col.title,
                                  action: #selector(toggleColumnFromHeader(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = col.rawId
            item.state = col.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    @objc private func toggleColumnFromHeader(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        toggleColumn(rawIdentifier: raw)
    }

    func columnsForMenu() -> [(rawId: String, title: String, isHidden: Bool)] {
        outlineView.tableColumns.compactMap { col in
            let title = col.headerCell.stringValue
            guard !title.isEmpty else { return nil }
            // The outline column carries the disclosure triangles and the group
            // indentation. Hiding it leaves grouped rows with no way to expand,
            // which reads as a broken table rather than a hidden column.
            guard col !== outlineView.outlineTableColumn else { return nil }
            return (col.identifier.rawValue, title, col.isHidden)
        }
    }

    func toggleColumn(rawIdentifier raw: String) {
        guard let col = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        col.isHidden.toggle()
        UserDefaults.standard.set(col.isHidden, forKey: Self.columnHiddenKey(raw))
    }

    private static func columnHiddenKey(_ rawIdentifier: String) -> String {
        "col.hidden.\(rawIdentifier)"
    }

    // Restore column visibility from UserDefaults. Defaults to whatever
    // each column was configured with in code (e.g. branch starts
    // hidden if the user previously hid it).
    private func restoreColumnVisibility() {
        for col in outlineView.tableColumns {
            // The outline column is no longer offered in either menu, so a
            // stored "hidden" from before that could never be undone.
            guard col !== outlineView.outlineTableColumn else { continue }
            let key = Self.columnHiddenKey(col.identifier.rawValue)
            if UserDefaults.standard.object(forKey: key) != nil {
                col.isHidden = UserDefaults.standard.bool(forKey: key)
            }
        }
    }

    // Settings → Chart Window changed: drop the per-file point cache
    // (its cursors already discarded data older than the previous
    // window) and recompute against the new range.
    func chartWindowChanged() {
        guard window?.isVisible == true else { return }
        // With the table tied to the window, changing the window changes which
        // sessions exist as far as the table is concerned.
        if chartWindowOnly { refreshFromIndex() }
        reloadChart()
    }

    @objc func handleChartWindowOnlyChanged() {
        guard window?.isVisible == true else { return }
        refreshFromIndex()
        refreshStatusLabel()
    }

    @objc private func chartModeChanged() {
        let wasLimit = LimitChart.mode != .none
        switch chartModeControl.selectedSegment {
        case 3:
            // Limits — cumulative token chart (token-only metric).
            LimitChart.mode = .session5h
            chartView.valueMode = .tokens
        case 1:  LimitChart.mode = .none; chartView.valueMode = .cost
        case 2:  LimitChart.mode = .none; chartView.valueMode = .lines
        default: LimitChart.mode = .none; chartView.valueMode = .tokens
        }
        // Crossing into/out of Limits swaps cumulative vs per-bucket
        // data, so the chart must recompute, not reuse the cache.
        if (LimitChart.mode != .none) != wasLimit { chartComputed = false }
        applyChartMode()
    }

    @objc private func reindexNow() {
        indexer.fullReindex()
        // Drop the cached chart buckets so the next render walks the
        // jsonls fresh — same path the window takes on first open.
        reloadChart()
    }

    // The keys the header prototypes carry. A separate type from ColumnID on
    // purpose — three of them deliberately differ from their column's id
    // (col.input/inputTokens, col.cacheRead/cacheReadTokens,
    // col.output/outputTokens) — and switched exhaustively below, so a new
    // sortable column fails to compile instead of quietly sorting by activity.
    // Four used to: Model, Name and Started moved the arrow and reordered
    // nothing, which is the worst kind of wrong because it looks like it worked.
    private enum SortKey: String {
        case model, permWait, path, title, inputTokens, changes
        case name, startedAt, userMessages, turns, branch
        case cacheReadTokens, outputTokens, cost, activity
    }

    private func sortFilteredEntries() {
        guard let sort = outlineView.sortDescriptors.first,
              let key = sort.key.flatMap(SortKey.init(rawValue:)) else { return }
        let asc = sort.ascending
        switch key {
        case .path:
            filteredEntries.sort { cmp($0.relativePath, $1.relativePath, ascending: asc) }
        case .title:
            filteredEntries.sort { cmp($0.displayTitle, $1.displayTitle, ascending: asc) }
        case .userMessages:
            filteredEntries.sort { asc ? ($0.userMessageCount < $1.userMessageCount) : ($0.userMessageCount > $1.userMessageCount) }
        case .turns:
            filteredEntries.sort { asc ? ($0.turns < $1.turns) : ($0.turns > $1.turns) }
        case .branch:
            filteredEntries.sort { cmp($0.lastGitBranch ?? "", $1.lastGitBranch ?? "", ascending: asc) }
        case .inputTokens:
            filteredEntries.sort { asc ? ($0.inputTokens < $1.inputTokens) : ($0.inputTokens > $1.inputTokens) }
        case .changes:
            filteredEntries.sort {
                let a = $0.linesAdded + $0.linesRemoved
                let b = $1.linesAdded + $1.linesRemoved
                return asc ? (a < b) : (a > b)
            }
        case .cacheReadTokens:
            filteredEntries.sort { asc ? ($0.cacheReadTokens < $1.cacheReadTokens) : ($0.cacheReadTokens > $1.cacheReadTokens) }
        case .outputTokens:
            filteredEntries.sort { asc ? ($0.outputTokens < $1.outputTokens) : ($0.outputTokens > $1.outputTokens) }
        case .cost:
            filteredEntries.sort { asc ? ($0.costUSD < $1.costUSD) : ($0.costUSD > $1.costUSD) }
        case .permWait:
            filteredEntries.sort {
                let a = monitor.permissionWait(for: $0.sessionId)
                let b = monitor.permissionWait(for: $1.sessionId)
                return asc ? (a < b) : (a > b)
            }
        case .model:
            // Sort by what the column shows, not the raw id: prettyModelName
            // strips the vendor prefix, so raw ids would group every Claude row
            // ahead of every Codex one while the visible text looked shuffled.
            filteredEntries.sort {
                cmp($0.model.map(Self.prettyModelName) ?? "",
                    $1.model.map(Self.prettyModelName) ?? "", ascending: asc)
            }
        case .name:
            filteredEntries.sort { cmp($0.name ?? "", $1.name ?? "", ascending: asc) }
        case .startedAt:
            // Codex and desktop stubs carry no start until their deep scan
            // lands; they sink to the bottom of the default newest-first order.
            filteredEntries.sort {
                let a = $0.startedAt ?? .distantPast
                let b = $1.startedAt ?? .distantPast
                return asc ? (a < b) : (a > b)
            }
        case .activity:
            filteredEntries.sort { asc ? ($0.lastActivity < $1.lastActivity) : ($0.lastActivity > $1.lastActivity) }
        }
    }

    private func cmp(_ a: String, _ b: String, ascending: Bool) -> Bool {
        let r = a.localizedCaseInsensitiveCompare(b)
        return ascending ? (r == .orderedAscending) : (r == .orderedDescending)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        if field === detailsSearchItem.searchField {
            // Details mode → highlight matches in the transcript and
            // scroll to the first one. The session list filter is
            // unaffected.
            highlightTranscriptMatches(for: field.stringValue)
        } else if field === listSearchItem.searchField {
            // Quick filter — table only (title / project / id). Full-text
            // content search lives in the deep-search mode.
            searchTerm = field.stringValue
            applyFilter()
        } else if field === deepSearchItem.searchField {
            // Deep (card) search — the embedded feed renders matching sessions.
            searchVC.runQuery(field.stringValue)
        }
    }

    // Deep-search toolbar button → open the card feed, seeded with whatever's
    // currently typed in the quick filter.
    @objc private func openDeepSearch() {
        enterSearchMode(initialQuery: searchTerm)
    }

    private static let transcriptMatchColor = NSColor.systemYellow.withAlphaComponent(0.35)
    private static let transcriptCurrentMatchColor = NSColor.systemOrange.withAlphaComponent(0.85)
    // Faint wash over the whole message a search result jumped to.
    private static let transcriptMessageColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12)

    private func highlightTranscriptMatches(for query: String, scrollToFirstMatch: Bool = true) {
        guard let storage = transcriptView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        transcriptMatches.removeAll()
        transcriptCurrentMatch = -1

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            return
        }
        let plain = storage.string as NSString
        var search = NSRange(location: 0, length: plain.length)
        while search.location < plain.length {
            let found = plain.range(of: trimmed, options: .caseInsensitive, range: search)
            guard found.location != NSNotFound else { break }
            transcriptMatches.append(found)
            storage.addAttribute(.backgroundColor, value: Self.transcriptMatchColor, range: found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: plain.length - next)
        }
        if scrollToFirstMatch, !transcriptMatches.isEmpty {
            selectMatch(at: 0)
        }
    }

    @objc private func searchFieldDidSubmit() {
        guard detailEntry != nil, !transcriptMatches.isEmpty else { return }
        let next = (transcriptCurrentMatch + 1) % transcriptMatches.count
        selectMatch(at: next)
    }

    private func selectMatch(at index: Int) {
        guard transcriptMatches.indices.contains(index),
              let storage = transcriptView.textStorage else { return }
        // Restore the previous "current" match to the regular hit colour
        // before promoting the new one.
        if transcriptMatches.indices.contains(transcriptCurrentMatch) {
            storage.addAttribute(
                .backgroundColor, value: Self.transcriptMatchColor,
                range: transcriptMatches[transcriptCurrentMatch]
            )
        }
        transcriptCurrentMatch = index
        let hit = transcriptMatches[index]
        storage.addAttribute(
            .backgroundColor, value: Self.transcriptCurrentMatchColor, range: hit
        )
        transcriptView.scrollRangeToVisible(hit)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? OutlineNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? OutlineNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? OutlineNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Force the full reload path: a sort change keeps the same membership,
        // so the in-place update (which preserves row order) would otherwise
        // swallow the reorder.
        applyFilter(forceReorder: true)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Both sessions and directory groups are selectable (a group shows its
        // aggregated totals and highlights its directory in the chart).
        return item is OutlineNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Highlight the selection in the aggregate chart; everything else goes
        // semi-transparent. In grouping mode the chart is keyed by directory,
        // so highlight by the selected row's cwd (group header or child).
        chartView.highlightedSessionId = chartHighlightKey()
        updateResumeButtonVisibility()
        // Selecting a row narrows nothing in the table, so applyFilter never
        // runs — but the button offers to drop the selection too, so it has to
        // learn about it here.
        refreshFilterButton()
    }

    private func chartHighlightKey() -> String? {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return nil }
        if groupByDir {
            if case let .group(cwd, _) = node.kind { return cwd }
            return node.session?.cwd
        }
        return node.session?.sessionId
    }

    // Copy / Messages enablement depends on the selection — push the
    // toolbar through validateToolbarItem whenever it changes.
    private func updateResumeButtonVisibility() {
        updateOpenSessionToolbarItems()
        window?.toolbar?.validateVisibleItems()
    }

    private func updateOpenSessionToolbarItems() {
        let entry = actionSession()
        let image = entry.flatMap(toolbarHostIcon(for:)) ?? Self.toolbarMissingHostIcon
        for item in openSessionItems {
            item.image = image
        }
    }

    // Keep the empty state on the same square canvas as real application
    // icons. A raw `terminal` symbol has rectangular intrinsic metrics, which
    // makes the toolbar glyph appear to jump when the selection changes.
    private static let toolbarMissingHostIcon: NSImage? = {
        toolbarSymbol("questionmark.square",
                      accessibilityDescription: "No session app")
            ?? toolbarSymbol("square", accessibilityDescription: "No session app")
    }()

    private static let toolbarIconSize = NSSize(width: 20, height: 20)
    private static let toolbarIconContentSide: CGFloat = 18
    private static let toolbarSymbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 16, weight: .regular)

    // Every toolbar image gets the same square footprint. The source is fitted
    // proportionally rather than stretched, so wide symbols (terminal, text
    // search) and narrow symbols (back, trash) stay optically stable.
    private static func squareToolbarImage(from source: NSImage) -> NSImage {
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return source }
        let side = toolbarIconContentSide
        let scale = min(side / sourceSize.width, side / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale,
                              height: sourceSize.height * scale)
        let drawRect = NSRect(x: (toolbarIconSize.width - drawSize.width) / 2,
                              y: (toolbarIconSize.height - drawSize.height) / 2,
                              width: drawSize.width, height: drawSize.height)
        let image = NSImage(size: toolbarIconSize, flipped: false) { _ in
            source.draw(in: drawRect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
        image.isTemplate = source.isTemplate
        return image
    }

    private static func toolbarSymbol(
        _ name: String, accessibilityDescription: String
    ) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name,
                                 accessibilityDescription: accessibilityDescription),
              let configured = base.withSymbolConfiguration(toolbarSymbolConfiguration)
        else { return nil }
        configured.isTemplate = true
        return squareToolbarImage(from: configured)
    }

    // Use the same host resolution as the App table column, but copy the image
    // before giving it the larger toolbar size so the 16-point cell icon cache
    // remains untouched.
    private func toolbarHostIcon(for entry: SessionIndexEntry) -> NSImage? {
        let source: NSImage?
        if entry.isExternalSource
            && SessionSourceStore.shared.isOffline(sourceID: entry.sourceID) {
            source = Self.offlineSourceIcon
        } else if isDesktopSession(entry) {
            source = Self.claudeDesktopIcon
        } else if let term = monitor.terminalKinds[entry.sessionId] {
            source = Self.terminalIcon(
                for: term, bundleId: monitor.hostBundleIds[entry.sessionId])
        } else {
            source = nil
        }
        guard let source else { return nil }
        return Self.squareToolbarImage(from: source)
    }

    @objc private func openMessages() {
        guard let entry = selectedSession() else { return }
        enterDetailsMode(for: entry)
    }

    // Bring the selected session's home forward — same single entry point
    // as the row double-click. cc-open resolves a terminal from cc-states.json
    // or follows Claude App's exact-session deep link.
    @objc private func openSelectedTerminal() {
        guard let entry = actionSession(), !entry.isExternalSource else { return }
        openSessionHome(entry)
    }

    // Marks a session as belonging to the Claude desktop app, whether the
    // index captured it (entrypoint / provider) or it's a live Code session.
    private func isDesktopSession(_ entry: SessionIndexEntry) -> Bool {
        entry.isClaudeDesktop || monitor.liveSessions[entry.sessionId]?.entrypoint == "claude-desktop"
    }

    private func claudeDesktopRouteId(_ entry: SessionIndexEntry) -> String? {
        guard !entry.isExternalSource, isDesktopSession(entry) else { return nil }
        // local_<uuid> is only EpiScope/Claude's storage key and is not a
        // routable bridge id. Wait for deepScan to publish cliSessionId rather
        // than knowingly opening Claude's session list during the short stub
        // phase. Live Code sessions use their normal session id directly.
        if entry.provider == .claudeDesktop { return entry.appSessionId }
        return entry.appSessionId ?? entry.sessionId
    }

    private func openSessionHome(_ entry: SessionIndexEntry) {
        TerminalIntegration.openSession(
            sessionId: entry.sessionId,
            claudeDesktopSessionId: claudeDesktopRouteId(entry))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !bulkUpdate,
              let node = notification.userInfo?["NSObject"] as? OutlineNode,
              let cwd = node.groupCwd else { return }
        collapsedCwds.remove(cwd)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !bulkUpdate,
              let node = notification.userInfo?["NSObject"] as? OutlineNode,
              let cwd = node.groupCwd else { return }
        collapsedCwds.insert(cwd)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier, let node = item as? OutlineNode else { return nil }
        switch node.kind {
        case let .group(cwd, children):
            // Group rows: only render content in the outline column;
            // other columns stay blank so the disclosure arrow + label
            // sit cleanly without competing text.
            if id == ColumnID.path {
                let groupId = NSUserInterfaceItemIdentifier("col.group")
                let cell = (outlineView.makeView(withIdentifier: groupId, owner: self) as? NSTextField) ?? makeTextCell(id: groupId)
                cell.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                cell.alignment = .left
                cell.stringValue = "\(displayPath(forCwd: cwd))   (\(children.count))"
                return cell
            }
            // The colour now belongs to the directory: its swatch sits on the
            // group header (child rows drop theirs).
            if id == ColumnID.sessionColor {
                let swatchId = NSUserInterfaceItemIdentifier("col.sessionColorView")
                let view = (outlineView.makeView(withIdentifier: swatchId, owner: self) as? SessionColorSwatchView)
                    ?? SessionColorSwatchView(identifier: swatchId)
                view.color = TokenChartView.color(for: cwd)
                return view
            }
            // Aggregated totals across the directory's sessions (bold, so the
            // header reads as a roll-up of the rows beneath it).
            let kids = children.compactMap { $0.session }
            func groupNum(_ s: String) -> NSTextField {
                let gid = NSUserInterfaceItemIdentifier("col.groupNum")
                let cell = (outlineView.makeView(withIdentifier: gid, owner: self) as? NSTextField) ?? makeTextCell(id: gid)
                cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                cell.alignment = .right
                cell.textColor = .labelColor
                cell.stringValue = s
                return cell
            }
            switch id {
            case ColumnID.inputTokens:
                return groupNum(Self.formatTokens(kids.reduce(0) { $0 + $1.inputTokens + $1.cacheCreationTokens }))
            case ColumnID.cacheReadTokens:
                return groupNum(Self.formatTokens(kids.reduce(0) { $0 + $1.cacheReadTokens }))
            case ColumnID.outputTokens:
                return groupNum(Self.formatTokens(kids.reduce(0) { $0 + $1.outputTokens }))
            case ColumnID.cost:
                return groupNum(Self.formatCost(kids.reduce(0.0) { $0 + $1.costUSD }))
            case ColumnID.turns:
                let t = kids.reduce(0) { $0 + $1.turns }
                return groupNum(t > 0 ? "\(t)" : "—")
            case ColumnID.userMessages:
                let u = kids.reduce(0) { $0 + $1.userMessageCount }
                return groupNum(u > 0 ? "\(u)" : "—")
            case ColumnID.permWait:
                let w = kids.reduce(0.0) { $0 + monitor.permissionWait(for: $1.sessionId) }
                return groupNum(w < 1 ? "—" : Self.formatWait(w))
            case ColumnID.changes:
                let added = kids.reduce(Int64(0)) { $0 + $1.linesAdded }
                let removed = kids.reduce(Int64(0)) { $0 + $1.linesRemoved }
                // Same cell type as session rows so it flips to the default
                // colour (white) when the group is the selected, focused row.
                let changesId = NSUserInterfaceItemIdentifier("col.changesField")
                let field = (outlineView.makeView(withIdentifier: changesId, owner: self) as? ChangesTextField)
                    ?? {
                        let f = ChangesTextField()
                        f.identifier = changesId
                        return f
                    }()
                field.setChanges(added: added, removed: removed)
                return field
            default:
                break
            }
            if id == ColumnID.activity {
                // Show the group's most-recent activity so collapsed
                // groups still convey freshness at a glance.
                let groupActId = NSUserInterfaceItemIdentifier("col.groupActivity")
                let cell = (outlineView.makeView(withIdentifier: groupActId, owner: self) as? NSTextField) ?? makeTextCell(id: groupActId)
                cell.alignment = .left
                cell.textColor = .secondaryLabelColor
                cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                let mostRecent = children.compactMap { $0.session?.lastActivity }.max() ?? .distantPast
                cell.stringValue = Self.relativeTime(mostRecent)
                return cell
            }
            return nil
        case let .session(entry):
            return sessionCell(for: entry, node: node, columnId: id)
        }
    }

    private func displayPath(forCwd cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        if cwd == home { return "~" }
        return cwd
    }

    private func sessionCell(for entry: SessionIndexEntry, node: OutlineNode, columnId id: NSUserInterfaceItemIdentifier) -> NSView? {
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? makeTextCell(id: id)
        cell.alignment = .left
        cell.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.textColor = .labelColor

        switch id {
        case ColumnID.colorDot:
            let viewId = NSUserInterfaceItemIdentifier("col.colorDotView")
            let view = (outlineView.makeView(withIdentifier: viewId, owner: self) as? ColorDotView)
                ?? ColorDotView(identifier: viewId)
            view.configure(
                color: TokenChartView.color(for: entry.sessionId),
                provider: entry.provider,
                isLoading: entry.lastParsedSize < entry.fileSize
            )
            return view
        case ColumnID.sessionColor:
            // In grouping mode the colour lives on the directory's group
            // header, so individual sessions show no swatch.
            if groupByDir { return nil }
            let swatchId = NSUserInterfaceItemIdentifier("col.sessionColorView")
            let view = (outlineView.makeView(withIdentifier: swatchId, owner: self) as? SessionColorSwatchView)
                ?? SessionColorSwatchView(identifier: swatchId)
            view.color = TokenChartView.color(for: entry.sessionId)
            return view
        case ColumnID.terminal:
            // Tiny image cell: the hosting application's icon for sessions
            // currently alive (host data comes from the tracker's snapshot).
            // Empty otherwise.
            let imgId = NSUserInterfaceItemIdentifier("col.terminalImg")
            let view = (outlineView.makeView(withIdentifier: imgId, owner: self) as? NSImageView)
                ?? makeTerminalImageView(id: imgId)
            // Recycled views carry over tint / tooltip — reset to the default
            // before each branch decides whether to override them.
            view.contentTintColor = nil
            view.toolTip = nil
            if entry.isExternalSource
                && SessionSourceStore.shared.isOffline(sourceID: entry.sourceID) {
                view.image = Self.offlineSourceIcon
                view.toolTip = "Cached session · source unavailable"
            } else if isNonInteractive(entry) {
                // Launched with -p / driven over the SDK (entrypoint "sdk-cli"):
                // never had an interactive terminal. A "-p" badge in place of a
                // terminal icon, for live and past runs alike.
                view.image = Self.nonInteractiveBadge
                view.contentTintColor = .secondaryLabelColor
                view.toolTip = "Non-interactive session (-p / SDK)"
            } else if isDesktopSession(entry) {
                // Claude desktop has no terminal — show the app's icon.
                view.image = Self.claudeDesktopIcon
            } else if let term = monitor.terminalKinds[entry.sessionId] {
                // The tracker publishes all live Claude and Codex processes,
                // while `liveSessions` contains only the subset relevant to
                // status monitoring. Host icons must not depend on that subset.
                let sid = entry.sessionId
                view.image = Self.terminalIcon(
                    for: term, bundleId: monitor.hostBundleIds[sid])
            } else if monitor.liveSessions[entry.sessionId] != nil {
                let sid = entry.sessionId
                if Self.needsAttention(session: monitor.liveSessions[sid],
                                       trackerState: monitor.kittyStates[sid]) {
                    // Alive, needs the user, and hosted by no known terminal —
                    // a detached / headless task. Only flag it in an attention
                    // state (a fresh session whose terminal the tracker hasn't
                    // located yet is busy/thinking, not waiting — no false flash).
                    view.image = Self.detachedIcon
                    view.contentTintColor = .systemOrange
                    view.toolTip = "Detached — no terminal to focus"
                } else {
                    // Not yet located — neutral glyph, same as before.
                    view.image = Self.terminalIcon(for: nil, bundleId: nil)
                }
            } else {
                view.image = nil
            }
            return view
        case ColumnID.status:
            let viewId = NSUserInterfaceItemIdentifier("col.statusBadge")
            let badge = (outlineView.makeView(withIdentifier: viewId, owner: self) as? StatusBadgeView)
                ?? StatusBadgeView(identifier: viewId)
            let trackerState = monitor.kittyStates[entry.sessionId]
            if trackerState == "error" || trackerState == "error_attended" {
                // Attention is carried by the menu-bar alarm; the table keeps
                // the Error badge itself neutral before and after acknowledgment.
                badge.configure(text: "Error",
                                color: .labelColor,
                                background: nil)
            } else if let live = monitor.liveSessions[entry.sessionId] {
                if live.isWaiting {
                    badge.configure(text: "Waiting",
                                    color: .white,
                                    background: NSColor.systemRed.withAlphaComponent(0.9))
                } else if live.status == "busy" {
                    badge.configure(text: Self.busyText(monitor.busyDuration(for: entry.sessionId)),
                                    color: .white,
                                    background: nil,
                                    pearlescent: true)
                } else {
                    // Alive but the sessions/*.json status is idle/absent —
                    // Claude desktop never writes one, SDK-CLI omits it, and a
                    // user-opened `/btw` dialog is deliberately transparent.
                    // Fall back to the tracker's computed state (from the
                    // hooks), which covers thinking / needs_permission / done.
                    switch trackerState {
                    case "needs_permission":
                        badge.configure(text: "Waiting",
                                        color: .white,
                                        background: NSColor.systemRed.withAlphaComponent(0.9))
                    case "thinking":
                        badge.configure(text: Self.busyText(monitor.busyDuration(for: entry.sessionId)),
                                        color: .white,
                                        background: nil,
                                        pearlescent: true)
                    case "done":
                        badge.configure(text: "Finished",
                                        color: .black,
                                        background: NSColor.systemYellow.withAlphaComponent(0.85))
                    default:
                        badge.configure(text: "Idle",
                                        color: .labelColor,
                                        background: nil)
                    }
                }
            } else if entry.provider == .claudeDesktop,
                      Date().timeIntervalSince(entry.lastActivity) < 360 {
                // Claude desktop has no live hooks; treat a record written in
                // the last few minutes as the agent actively working.
                badge.configure(text: "Active",
                                color: .white,
                                background: NSColor.systemGreen.withAlphaComponent(0.85))
            } else {
                badge.configure(text: "—",
                                color: .secondaryLabelColor,
                                background: nil)
            }
            return badge
        case ColumnID.path:
            // Grouped: the directory is the group header, so the outline
            // column shows the session's own label here (no dead space). Flat:
            // the per-session path. The redundant Title column is hidden while
            // grouping (see applyGroupingColumns).
            let dim = hasNoTerminal(entry)
            if groupByDir {
                let raw = (entry.name ?? entry.title ?? "")
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                cell.stringValue = raw.isEmpty ? "—" : raw
                cell.textColor = raw.isEmpty || dim ? .secondaryLabelColor : .labelColor
            } else {
                cell.stringValue = entry.relativePath
                cell.textColor = dim ? .secondaryLabelColor : .labelColor
            }
        case ColumnID.name:
            let nm = (entry.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cell.stringValue = nm.isEmpty ? "—" : nm
            cell.textColor = nm.isEmpty || hasNoTerminal(entry)
                ? .secondaryLabelColor : .labelColor
        case ColumnID.title:
            let raw = entry.title ?? ""
            // Collapse all interior whitespace (incl. newlines, tabs)
            // into single spaces so a multi-line user prompt renders
            // as one tidy line in the column.
            let oneLine = raw
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            cell.stringValue = oneLine.isEmpty ? "—" : oneLine
            cell.textColor = hasNoTerminal(entry) ? .secondaryLabelColor : .labelColor
        case ColumnID.model:
            let pretty = entry.model.map(Self.prettyModelName) ?? "—"
            // Effort: Codex records it per-session (turn_context); Claude
            // keeps only the global effortLevel in settings.json, so we
            // fall back to that for Claude rows.
            let perSession = entry.effort.flatMap { $0.isEmpty ? nil : $0 }
            let eff = perSession ?? (entry.provider == .claude ? claudeEffort : nil)
            cell.stringValue = eff.map { "\(pretty) \($0)" } ?? pretty
            cell.textColor = .labelColor
        case ColumnID.startedAt:
            if let d = entry.startedAt {
                cell.stringValue = Self.relativeTime(d)
            } else {
                cell.stringValue = "—"
            }
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.userMessages:
            cell.stringValue = entry.userMessageCount > 0 ? "\(entry.userMessageCount)" : "—"
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.turns:
            cell.stringValue = entry.turns > 0 ? "\(entry.turns)" : "—"
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.branch:
            let b = entry.lastGitBranch ?? ""
            cell.stringValue = b.isEmpty ? "—" : b
            cell.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            cell.textColor = .secondaryLabelColor
        case ColumnID.permWait:
            let waited = monitor.permissionWait(for: entry.sessionId)
            if waited < 1 {
                cell.stringValue = "—"
                cell.textColor = .secondaryLabelColor
            } else {
                cell.stringValue = Self.formatWait(waited)
            }
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.inputTokens:
            cell.stringValue = Self.formatTokens(entry.inputTokens + entry.cacheCreationTokens)
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.changes:
            // Own cell type so it can flip the +/- counts to the default
            // colour when its row becomes the selected, focused one.
            let changesId = NSUserInterfaceItemIdentifier("col.changesField")
            let field = (outlineView.makeView(withIdentifier: changesId, owner: self) as? ChangesTextField)
                ?? {
                    let f = ChangesTextField()
                    f.identifier = changesId
                    return f
                }()
            field.setChanges(added: entry.linesAdded, removed: entry.linesRemoved)
            return field
        case ColumnID.cacheReadTokens:
            cell.stringValue = Self.formatTokens(entry.cacheReadTokens)
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.outputTokens:
            cell.stringValue = Self.formatTokens(entry.outputTokens)
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.cost:
            cell.stringValue = Self.formatCost(entry.costUSD)
            cell.alignment = .right
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case ColumnID.activity:
            cell.stringValue = Self.relativeTime(entry.lastActivity)
            cell.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        default:
            cell.stringValue = ""
        }
        return cell
    }

    private func makeTextCell(id: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = CenteredTextField()
        field.identifier = id
        field.lineBreakMode = .byTruncatingTail
        // Force single-line layout — without this, a string containing
        // a \n (Codex titles are often multi-line user prompts) renders
        // with a 2-line bounding box, which throws off the centering
        // math in CenteredTextFieldCell and bloats the row.
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private static let kittyImage: NSImage? = {
        let i = NSImage(named: "KittyIcon")
        i?.size = NSSize(width: 16, height: 16)
        return i
    }()

    // The Claude desktop app's own icon, for sessions hosted there.
    private static let claudeDesktopIcon: NSImage? = {
        let i = appIcon(bundleId: "com.anthropic.claudefordesktop")
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Claude desktop")
        i?.size = NSSize(width: 16, height: 16)
        return i
    }()

    // A live session EpiScope can't attribute to any terminal — a detached /
    // headless background task (e.g. a forked bg session adopted by Claude's
    // daemon). Distinct from the generic-terminal fallback so the fleet view
    // tells the truth: there is no window to focus, and a notification tap
    // lands in EpiScope rather than pretending to jump to a terminal.
    private static let detachedIcon: NSImage? = {
        let i = NSImage(systemSymbolName: "questionmark.square.dashed",
                        accessibilityDescription: "Detached — no terminal")
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Detached")
        i?.isTemplate = true
        i?.size = NSSize(width: 16, height: 16)
        return i
    }()

    // Cached sessions remain usable when an external source disappears. Keep
    // their replacement App icon on the exact same square canvas as real app
    // icons so rows do not jump when the mount reconnects.
    private static let offlineSourceIcon: NSImage? = {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
        guard let base = NSImage(
            systemSymbolName: "externaldrive.badge.xmark",
            accessibilityDescription: "Cached session — source unavailable")?
            .withSymbolConfiguration(symbolConfig) else { return nil }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: 3.5, yRadius: 3.5).fill()
            base.draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        image.size = size
        return image
    }()

    // A detached session is worth flagging only once it actually needs the
    // user — parked on a permission prompt (waiting / needs_permission),
    // finished (done), or failed (error). A session whose terminal the tracker
    // simply hasn't located yet is busy/thinking, so it never trips this.
    private static func needsAttention(session: SessionInfo?, trackerState: String?) -> Bool {
        if session?.isWaiting == true { return true }
        return trackerState == "needs_permission" || trackerState == "done"
            || trackerState == "error"
    }

    // "-p" — the terminal-column badge for a non-interactive session. Drawn to
    // its own tight bounds so the image view centres it in the cell; template
    // so it tints (adapts to light/dark and the selected-row highlight).
    private static let nonInteractiveBadge: NSImage = {
        let text = "-p" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let ts = text.size(withAttributes: attrs)
        let img = NSImage(size: NSSize(width: ceil(ts.width), height: ceil(ts.height)))
        img.lockFocus()
        text.draw(at: .zero, withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    // True when the session was launched non-interactively (`claude -p` /
    // SDK-CLI over stdio → entrypoint "sdk-cli"). Read from the index (which
    // parses it from the transcript, so past runs count too) or the live
    // session file (for one that just started, before it's indexed).
    private func isNonInteractive(_ entry: SessionIndexEntry) -> Bool {
        entry.entrypoint == "sdk-cli"
            || monitor.liveSessions[entry.sessionId]?.isSdkCli == true
    }

    // A non -p, non-desktop session EpiScope has no reachable terminal for —
    // orphaned / detached, or simply a past session. Its row text is dimmed:
    // there's no terminal to jump to. (-p and Claude-desktop sessions get their
    // own treatment, so they stay at full strength.)
    private func hasNoTerminal(_ entry: SessionIndexEntry) -> Bool {
        !isNonInteractive(entry)
            && !isDesktopSession(entry)
            && monitor.terminalKinds[entry.sessionId] == nil
    }

    // Icon for the application hosting a session. A bundle id from process
    // ancestry wins; dedicated terminal kinds remain as fallbacks for exact
    // adapters that do not need to walk the process tree.
    private static var terminalIconCache: [String: NSImage?] = [:]

    private static func terminalIcon(for term: String?, bundleId: String?) -> NSImage? {
        let key = bundleId ?? term ?? "generic"
        if let cached = terminalIconCache[key] { return cached }
        let icon: NSImage?
        if let bundleId, let appImage = appIcon(bundleId: bundleId) {
            icon = appImage
        } else {
            switch term {
            case "kitty":
                icon = kittyImage
            case "iterm2":
                icon = appIcon(bundleId: "com.googlecode.iterm2")
            case "terminal":
                icon = appIcon(bundleId: "com.apple.Terminal")
            case "ghostty":
                icon = appIcon(bundleId: "com.mitchellh.ghostty")
            case "agterm":
                icon = appIcon(bundleId: "com.umputun.agterm")
            case "xterm":
                // xterm has no app bundle of its own — XQuartz hosts it.
                icon = appIcon(bundleId: "org.xquartz.X11")
                    ?? NSImage(systemSymbolName: "xmark.square", accessibilityDescription: "xterm")
            case "jetbrains":
                // Legacy snapshots did not publish an exact bundle id.
                icon = NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier?.hasPrefix("com.jetbrains") == true }?.icon
                    ?? NSImage(systemSymbolName: "hammer", accessibilityDescription: "JetBrains IDE")
            default:
                icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "terminal")
            }
        }
        icon?.size = NSSize(width: 16, height: 16)
        terminalIconCache[key] = icon
        return icon
    }

    private static func appIcon(bundleId: String) -> NSImage? {
        if let icon = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId })?.icon {
            return icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func makeTerminalImageView(id: NSUserInterfaceItemIdentifier) -> NSImageView {
        let view = NSImageView()
        view.identifier = id
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        return view
    }

    private static func shortSessionId(_ id: String) -> String {
        guard id.count > 9 else { return id }
        return "\(id.prefix(4))…\(id.suffix(4))"
    }

    private static let millionsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let dollarsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private static func formatTokens(_ n: Int64) -> String {
        if n == 0 { return "—" }
        let millions = NSNumber(value: Double(n) / 1_000_000)
        let str = millionsFormatter.string(from: millions) ?? "\(millions)"
        return "\(str)M"
    }

    // "+123 / −45" with git-style colouring, right-aligned to match
    // the numeric columns. One point smaller than the other numeric
    // columns so the coloured pair reads as secondary detail. A zero
    // side is omitted entirely (divider included) — "+123" / "−45"
    // alone when the session only added or only removed.
    // `neutral` renders the +/- counts in the row's default text colour
    // instead of green/red — used for the selected, focused row, where the
    // dark-aqua highlight turns labelColor white so the counts read cleanly
    // on the accent capsule like every other column.
    static func changesString(added: Int64, removed: Int64, neutral: Bool = false) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        func part(_ text: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: para,
            ])
        }
        if added == 0 && removed == 0 {
            return part("—", .secondaryLabelColor)
        }
        let addColor = neutral ? NSColor.labelColor : Theme.diffAdded
        let remColor = neutral ? NSColor.labelColor : Theme.diffRemoved
        let s = NSMutableAttributedString()
        if added > 0 {
            s.append(part("+\(added)", addColor))
        }
        if removed > 0 {
            if s.length > 0 { s.append(part(" / ", .secondaryLabelColor)) }
            s.append(part("−\(removed)", remColor))
        }
        return s
    }

    private static let groupFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static func usageTooltip(for e: SessionIndexEntry) -> String {
        func fmt(_ n: Int64) -> String { groupFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }
        let model = e.model ?? "unknown"
        let cost = formatCost(e.costUSD)
        return """
        Model: \(model)
        Input:       \(fmt(e.inputTokens))
        Cache write: \(fmt(e.cacheCreationTokens))
        Cache read:  \(fmt(e.cacheReadTokens))
        Output:      \(fmt(e.outputTokens))
        Cost:        \(cost)
        """
    }

    private static func formatCost(_ usd: Double) -> String {
        if usd == 0 { return "—" }
        if usd < 1 { return "$0" }
        let str = dollarsFormatter.string(from: NSNumber(value: usd)) ?? "\(Int(usd))"
        return "$\(str)"
    }

    // MARK: - Selection helpers

    private func selectedSession() -> SessionIndexEntry? {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? OutlineNode else { return nil }
        return node.session
    }

    private func clickedSession() -> SessionIndexEntry? {
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? OutlineNode else { return nil }
        return node.session
    }

    // The session a session-action targets, wherever it's invoked from: the
    // right-clicked row (context menu), the session on screen (details toolbar),
    // or the selected row (list toolbar).
    private func actionSession() -> SessionIndexEntry? {
        clickedSession() ?? detailEntry ?? selectedSession()
    }

    // Right-click row menu. Items act on the clicked row (clickedSession);
    // validateMenuItem disables them on group headers / empty space.
    // Shown only for a session that has lost its parent (no terminal EpiScope
    // can focus) — see menuNeedsUpdate. Copies a shell command that reopens it.
    private lazy var resumeMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Copy Resume Command",
                              action: #selector(copyResumeCommand), keyEquivalent: "")
        item.target = self
        return item
    }()

    // Destructive — its own separated group; hidden for sessions EpiScope
    // can't safely delete (Claude desktop, app-managed). See menuNeedsUpdate.
    private let deleteSeparator = NSMenuItem.separator()
    private lazy var deleteMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Delete Session…",
                              action: #selector(deleteClickedSession), keyEquivalent: "")
        item.target = self
        return item
    }()

    // Ends the session's process the way `/exit` does from inside it. Shown
    // only while it is running — see menuNeedsUpdate.
    private lazy var stopMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Stop Session",
                              action: #selector(stopClickedSession), keyEquivalent: "")
        item.target = self
        return item
    }()

    private func makeRowContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let reveal = NSMenuItem(title: "Reveal Transcript in Finder",
                                action: #selector(revealTranscriptInFinder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let analyze = NSMenuItem(title: "Analyze Session…",
                                 action: #selector(analyzeClickedSession), keyEquivalent: "")
        analyze.target = self
        menu.addItem(analyze)
        menu.addItem(resumeMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(deleteSeparator)
        menu.addItem(deleteMenuItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Two menus share this delegate; the row one's logic reads the clicked
        // session, which a header click does not have.
        if menu === columnsMenu {
            rebuildColumnsMenu(menu)
            return
        }
        // Copy Resume Command and Delete apply to any CLI-owned Claude / Codex
        // session (not the app-managed Claude desktop store).
        let cli = clickedSession().map(isCliSession) ?? false
        resumeMenuItem.isHidden = !cli
        deleteMenuItem.isHidden = !cli
        deleteSeparator.isHidden = !cli
        // Stop rides with the other session actions and greys out instead of
        // vanishing: a row that cannot be stopped — finished, or a Code tab the
        // app owns — should say the action exists and does not apply, not leave
        // the menu a different shape each time it opens. validateMenuItem
        // decides enablement.
        stopMenuItem.isHidden = !cli
    }

    // Stoppable: a session of ours that is running right now, under a pid we
    // are allowed to signal. An external source's session runs on another
    // machine. A Claude Desktop one is excluded even where it has a process of
    // its own — a Code tab does — because ending it closes a tab in the app
    // rather than performing the /exit that was typed into it.
    private func canStop(_ entry: SessionIndexEntry) -> Bool {
        guard !entry.isExternalSource, !isDesktopSession(entry),
              entry.provider.stoppableProcess != nil,
              let live = monitor.liveSessions[entry.sessionId]
        else { return false }
        return live.pid > 1
    }

    // A Claude / Codex CLI session: one EpiScope can resume from a shell and
    // whose transcript it owns (so can move to the Trash).
    //
    // A Claude Desktop *Code tab* qualifies: it is ordinary Claude Code, and its
    // transcript sits in ~/.claude/projects, exactly where `claude --resume`
    // looks. Only the local-agent-mode store is out — it is the app's own, and
    // the CLI cannot address a session it never wrote.
    private func isCliSession(_ entry: SessionIndexEntry) -> Bool {
        !entry.isExternalSource
            && (entry.provider == .claude || entry.provider == .codex)
    }

    // `cd '<cwd>' && claude --resume <id>` (codex: `codex resume <id>`),
    // ready to paste into a terminal to reopen the session where it lived.
    @objc private func copyResumeCommand() {
        guard let entry = actionSession() else { return }
        // The id is a transcript filename, so quote it like the path: this
        // string is built to be pasted into a shell, and a session whose file
        // was named by someone else must not carry a second command into it.
        let sid = Self.shellQuote(entry.sessionId)
        let launch = entry.provider == .codex
            ? "codex resume \(sid)"
            : "claude --resume \(sid)"
        let cmd = "cd \(Self.shellQuote(entry.cwd)) && \(launch)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }

    // POSIX single-quote a path so spaces / special chars survive the paste.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Stop a session — the shutdown `/exit` performs, asked for from the table.
    // An idle session goes straight through: that is the /exit the operator
    // would have typed. One mid-turn or holding a permission prompt is
    // confirmed first, because the answer being written ends with it.
    @objc private func stopClickedSession() {
        guard let entry = actionSession(), canStop(entry),
              let live = monitor.liveSessions[entry.sessionId] else { return }
        let working = live.isWaiting || monitor.busyDuration(for: entry.sessionId) != nil
        guard working else {
            performStop(entry, pid: live.pid)
            return
        }
        let name = entry.name ?? entry.title ?? entry.folderName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop “\(name)”?"
        alert.informativeText = live.isWaiting
            ? "\(entry.relativePath)\n\nIt is waiting for you; the request it is holding ends with it."
            : "\(entry.relativePath)\n\nIt is working right now; the turn in progress ends with it."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.performStop(entry, pid: live.pid)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    private func performStop(_ entry: SessionIndexEntry, pid: Int) {
        switch SessionControl.stop(pid: pid, provider: entry.provider) {
        case .stopped:
            // The monitor polls liveness every second, so the row leaves the
            // live set on its own — nothing to refresh here.
            break
        case .notRunning, .failed:
            NSSound.beep()
        }
    }

    // Delete a session: confirm, then move its transcript to the Trash
    // (recoverable) and reindex so the row drops.
    //
    // Deleting a running session stops it first — there is no version of this
    // that leaves the process alive. The CLI does not hold the transcript open,
    // so a session that keeps running recreates the file at the same path on its
    // next message: "delete" would land as a truncation nobody asked for.
    @objc private func deleteClickedSession() {
        guard let entry = actionSession(), isCliSession(entry),
              let url = SessionIndexer.transcriptURL(for: entry) else { return }
        let name = entry.name ?? entry.title ?? entry.folderName
        let stoppablePid = canStop(entry) ? monitor.liveSessions[entry.sessionId]?.pid : nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        var info = "\(entry.relativePath)\n\nIts transcript will be moved to the Trash."
        if stoppablePid != nil {
            info += "\n\nThis session is running and will be stopped first."
        } else if monitor.liveSessions[entry.sessionId] != nil {
            // Live and not ours to stop — a Claude Desktop Code tab. It writes
            // an ordinary CLI transcript, so it recreates the file on its next
            // message; say what the delete actually leaves behind.
            info += "\n\nThis session runs in the Claude app, which EpiScope cannot "
                + "stop. Deleting now removes only what it has written so far."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            if let pid = stoppablePid {
                self.stopThenDelete(entry, url: url, pid: pid)
            } else {
                self.performDelete(entry, url: url)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    // The delete waits for the process to actually be gone: a shutting-down CLI
    // still writes its last records, and trashing the file under it would leave
    // those records in a recreated transcript.
    private func stopThenDelete(_ entry: SessionIndexEntry, url: URL, pid: Int) {
        guard SessionControl.stop(pid: pid, provider: entry.provider) == .stopped else {
            // Already gone, or the pid is not this session's process after all —
            // either way there is nothing running to wait for.
            performDelete(entry, url: url)
            return
        }
        SessionControl.waitForExit(pid: pid, timeout: 5) { [weak self] exited in
            guard let self else { return }
            guard exited else {
                self.reportStopFailed(name: entry.name ?? entry.title ?? entry.folderName)
                return
            }
            self.performDelete(entry, url: url)
        }
    }

    // Nothing was deleted, so say so rather than beeping: the operator asked for
    // two things and got neither.
    private func reportStopFailed(name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” did not stop"
        alert.informativeText = "Its transcript was left in place. Stop the session "
            + "from its terminal, then delete it."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func performDelete(_ entry: SessionIndexEntry, url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            return
        }
        // Leave a details view of the now-deleted session.
        if detailEntry?.sessionId == entry.sessionId { goBack() }
        indexer.fullReindex()
    }

    @objc private func analyzeClickedSession() {
        guard let entry = actionSession() else { return }
        enterInsights(retro: entry)
    }

    @objc private func showInsights() { enterInsights() }

    // Fleet Insights, embedded in this window. An optional per-session retro
    // just kicks off that session's report inside the same fleet view.
    func enterInsights(retro entry: SessionIndexEntry? = nil) {
        reportsWC.refresh()
        // Entered from a session's details ("Analyze Session…"), the details
        // state has to go: Back from here lands on the list, and a stale
        // detailEntry would keep the title bar (and session-scoped actions)
        // pointing at the session that was on screen.
        detailEntry = nil
        windowMode = .insights
        applyMode()
        refreshStatusLabel()
        refreshInsightsBadge()   // now in insights mode → marks seen, clears badge
        if let entry { reportsWC.runRetro(entry) }
    }

    @objc private func revealTranscriptInFinder() {
        guard let entry = actionSession(),
              let url = SessionIndexer.transcriptURL(for: entry),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(revealTranscriptInFinder)
            || item.action == #selector(analyzeClickedSession) {
            return clickedSession() != nil
        }
        if item.action == #selector(copyResumeCommand)
            || item.action == #selector(deleteClickedSession) {
            return clickedSession().map(isCliSession) ?? false
        }
        if item.action == #selector(stopClickedSession) {
            return clickedSession().map(canStop) ?? false
        }
        return true
    }

    @objc private func copySelectedSessionId() {
        guard let entry = actionSession() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.sessionId, forType: .string)
        copyResetWork?.cancel()
        for item in copyItems {
            item.image = Self.toolbarSymbol("checkmark", accessibilityDescription: "Copied")
        }
        let work = DispatchWorkItem { [weak self] in
            for item in self?.copyItems ?? [] {
                item.image = Self.toolbarSymbol(
                    "doc.on.doc", accessibilityDescription: "Copy session ID")
            }
        }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // Back button — context-aware: details returns to wherever it was opened
    // from (the list, search feed or Insights); fleet modes return to the list.
    @objc private func goBack() {
        switch windowMode {
        case .details:
            detailEntry = nil
            windowMode = detailsReturnMode
            applyMode()
            // Restores the "EpiScope" title + count subtitle (detailEntry nil).
            refreshStatusLabel()
            transcriptView.textStorage?.setAttributedString(NSAttributedString())
            // Don't keep the session's parsed timeline alive after leaving.
            sessionChartView.timeline = SessionTimeline()
            if windowMode == .search { focusDeepSearch() }
        case .search:
            windowMode = .list
            applyMode()
            refreshStatusLabel()
        case .insights:
            windowMode = .list
            applyMode()
            refreshStatusLabel()
        case .list:
            break
        }
    }

    // Enter the in-window full-text search feed, optionally seeded with a query
    // (carried from the quick filter or a menu shortcut).
    func enterSearchMode(initialQuery: String = "") {
        windowMode = .search
        applyMode()
        deepSearchItem.searchField.stringValue = initialQuery
        searchVC.runQuery(initialQuery)
        focusDeepSearch()
    }

    private func focusDeepSearch() {
        // Defer past the toolbar swap so the search item is installed, then put
        // the cursor in the field (beginSearchInteraction expands a collapsed
        // item; makeFirstResponder is what actually focuses it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.deepSearchItem.beginSearchInteraction()
            self.window?.makeFirstResponder(self.deepSearchItem.searchField)
        }
    }

    private func enterDetailsMode(for entry: SessionIndexEntry, highlight: String? = nil, scrollTo: String? = nil) {
        detailsReturnMode = (windowMode == .search || windowMode == .insights)
            ? windowMode : .list
        detailEntry = entry
        // Title bar keeps the directory; the session title goes in the
        // subtitle below it (mirrors the list-mode title/subtitle split).
        let sessionTitle = entry.name ?? entry.title ?? entry.folderName
        window?.title = entry.relativePath
        window?.subtitle = sessionTitle
        windowMode = .details
        applyMode()
        // Async — the jsonl can be many MB; don't freeze the UI on click.
        let target = entry
        // The recorded permission waits are main-actor state in the monitor,
        // so read them here and hand them to the builder off-thread.
        let waits = monitor.permissionSegments(for: entry.sessionId)
        transcriptView.textStorage?.setAttributedString(NSAttributedString(
            string: "Loading…",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        ))
        DispatchQueue.global(qos: .userInitiated).async {
            let (events, truncated) = SessionIndexer.loadTranscript(for: target)
            let timeline = SessionTimeline.build(for: target, permissionWaits: waits)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detailEntry?.sessionId == target.sessionId else { return }
                self.sessionChartView.timeline = timeline
                let (attr, ranges) = Self.compactTranscript(events, truncated: truncated)
                self.transcriptView.textStorage?.setAttributedString(attr)
                self.focusTranscript(events: events, ranges: ranges,
                                     highlight: highlight, scrollTo: scrollTo)
            }
        }
    }

    // After a transcript loads (opened from a search result): highlight the
    // query, then scroll to and focus the specific message it was opened from,
    // matched to its transcript event by the message's raw-text prefix.
    private func focusTranscript(events: [SessionIndexer.TranscriptEvent],
                                 ranges: [NSRange], highlight: String?, scrollTo: String?) {
        if let highlight, !highlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detailsSearchItem.searchField.stringValue = highlight
            // Highlight every occurrence; only auto-scroll to the first when we
            // don't have a specific message to scroll to.
            highlightTranscriptMatches(for: highlight, scrollToFirstMatch: scrollTo == nil)
        }
        guard let scrollTo, !scrollTo.isEmpty else { return }
        let visibleEvents = events.filter { $0.kind != .usage }
        guard let ei = visibleEvents.firstIndex(where: { $0.text.hasPrefix(scrollTo) }),
              ei < ranges.count else {
            // Message not in the loaded (tail-capped) transcript — fall back to
            // the first query match if there is one.
            if !transcriptMatches.isEmpty { selectMatch(at: 0) }
            return
        }
        let msgRange = ranges[ei]
        // Faintly wash the whole message so it stands out, then keep the query
        // highlights on top of the wash.
        if let storage = transcriptView.textStorage {
            storage.addAttribute(.backgroundColor, value: Self.transcriptMessageColor, range: msgRange)
            for m in transcriptMatches where NSLocationInRange(m.location, msgRange) {
                storage.addAttribute(.backgroundColor, value: Self.transcriptMatchColor, range: m)
            }
        }
        // Focus the query occurrence inside this message (orange current match);
        // otherwise just reveal the message itself.
        if let idx = transcriptMatches.firstIndex(where: { NSLocationInRange($0.location, msgRange) }) {
            selectMatch(at: idx)
        } else {
            transcriptView.scrollRangeToVisible(msgRange)
            transcriptView.setSelectedRange(NSRange(location: msgRange.location, length: 0))
        }
        scheduleMessageWashFade(over: msgRange)
    }

    // The whole-message wash is a transient cue — fade it after a few seconds,
    // restoring the (persistent) query-match highlights it sat over.
    private func scheduleMessageWashFade(over msgRange: NSRange) {
        messageWashFade?.cancel()
        let session = detailEntry?.sessionId
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.detailEntry?.sessionId == session,
                  let storage = self.transcriptView.textStorage,
                  NSMaxRange(msgRange) <= storage.length else { return }
            storage.removeAttribute(.backgroundColor, range: msgRange)
            for m in self.transcriptMatches where NSLocationInRange(m.location, msgRange) {
                let isCurrent = self.transcriptMatches.indices.contains(self.transcriptCurrentMatch)
                    && self.transcriptMatches[self.transcriptCurrentMatch] == m
                storage.addAttribute(
                    .backgroundColor,
                    value: isCurrent ? Self.transcriptCurrentMatchColor : Self.transcriptMatchColor,
                    range: m)
            }
        }
        messageWashFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // Open the Messages (transcript) screen for a session by id, optionally
    // scrolling to the specific message a search result was opened from. Brings
    // the main window forward.
    func showMessages(sessionId: String, highlight query: String, scrollTo locator: String? = nil) {
        guard let entry = indexer.entries.first(where: { $0.sessionId == sessionId }) else { return }
        show()
        enterDetailsMode(for: entry, highlight: query, scrollTo: locator)
    }

    // Configures toolbar + view visibility for the current windowMode. Three
    // modes share the content area — list (table), details (transcript) and
    // search (card feed) — each swapping the whole toolbar.
    private func applyMode() {
        let isList = windowMode == .list
        let isDetails = windowMode == .details
        let isSearch = windowMode == .search
        let isInsights = windowMode == .insights

        window?.toolbar = isDetails ? detailsToolbar
            : isSearch ? searchToolbar
            : isInsights ? insightsToolbar
            : listToolbar
        updateResumeButtonVisibility()
        chartHeight.constant = isDetails ? Self.detailsChartHeight : Self.listChartHeight

        // The transcript-scoped field only matters in details (re-seeded there
        // when a search result is opened). The list's quick filter is kept
        // across navigation (into a session / insights / search and back) —
        // just re-applied — instead of being wiped on every return to the list.
        detailsSearchItem.searchField.stringValue = ""
        if isList {
            deepSearchItem.searchField.stringValue = ""
            applyFilter()
        }

        outlineView.enclosingScrollView?.isHidden = !isList
        // The placeholder belongs to the table, so it leaves with it — it is a
        // sibling of the scroll view, not a subview, and would otherwise hang
        // over the transcript or the search feed.
        if !isList {
            emptyLabel.isHidden = true
            clearFiltersButton.isHidden = true
        }
        refreshTotals()
        transcriptScroll.isHidden = !isDetails
        sessionChartView.isHidden = !isDetails
        divider.isHidden = isSearch || isInsights
        searchVC.view.isHidden = !isSearch
        reportsWC.embeddableView().isHidden = !isInsights

        if isSearch || isInsights {
            // The feed / reports cover the whole content; stop the chart working.
            chartView.isHidden = true
            limitChartView.isHidden = true
            limitTickTimer = nil
        } else {
            applyChartMode()
        }
    }

    // Compact transcript: a single mono body so code blocks, paths,
    // and prose line up visually. One header line per turn ("U" / "A"
    // + short timestamp) tinted by role.
    private static func compactTranscript(
        _ events: [SessionIndexer.TranscriptEvent],
        truncated: Bool = false
    ) -> (text: NSAttributedString, ranges: [NSRange]) {
        let visibleEvents = events.filter { $0.kind != .usage }
        let bodyFontSize: CGFloat = NSFont.systemFontSize          // 13pt
        let headerFontSize: CGFloat = NSFont.smallSystemFontSize   // 11pt
        let body = NSMutableAttributedString()
        if truncated {
            body.append(NSAttributedString(
                string: "Showing recent messages of a large session — earlier history omitted.\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: headerFontSize),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
        }
        if visibleEvents.isEmpty {
            body.append(NSAttributedString(string: "No user-visible messages.", attributes: [
                .font: NSFont.systemFont(ofSize: bodyFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            return (body, [])
        }
        // Each turn reads as its own block, but lines / paragraphs
        // inside it sit tight so a long answer doesn't sprawl.
        let headerPara = NSMutableParagraphStyle()
        headerPara.paragraphSpacingBefore = 12
        headerPara.paragraphSpacing = 2
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.paragraphSpacing = 1
        bodyPara.lineSpacing = 0

        var ranges: [NSRange] = []
        ranges.reserveCapacity(visibleEvents.count)
        for event in visibleEvents {
            let blockStart = body.length
            let isUser = event.kind == .user
            let stamp = event.timestamp.map(timeStampFormatter.string(from:)) ?? ""
            body.append(NSAttributedString(string: isUser ? "USER" : "ASSISTANT", attributes: [
                .font: NSFont.systemFont(ofSize: headerFontSize, weight: .semibold),
                .foregroundColor: isUser ? NSColor.systemBlue : NSColor.systemPurple,
                .paragraphStyle: headerPara,
            ]))
            if !stamp.isEmpty {
                body.append(NSAttributedString(string: " \(stamp)", attributes: [
                    .font: NSFont.systemFont(ofSize: headerFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: headerPara,
                ]))
            }
            body.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: headerFontSize),
                .paragraphStyle: headerPara,
            ]))
            let bodyFont = NSFont.systemFont(ofSize: bodyFontSize)
            body.append(MarkdownRenderer.render(
                event.text,
                baseFont: bodyFont,
                color: .labelColor,
                paragraphStyle: bodyPara,
                scrollableTables: true
            ))
            body.append(NSAttributedString(string: "\n", attributes: [
                .font: bodyFont,
                .paragraphStyle: bodyPara,
            ]))
            // This event's block (header + rendered body) — a search result can
            // scroll straight to its message.
            ranges.append(NSRange(location: blockStart, length: body.length - blockStart))
        }
        return (body, ranges)
    }

    private static let timeStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return f
    }()

    @objc private func rowDoubleClicked() {
        guard let entry = clickedSession() else { return }
        openSessionLikeTableRow(entry)
    }

    private func openSessionLikeTableRow(sessionId: String) {
        guard let entry = indexer.entries.first(where: { $0.sessionId == sessionId }) else {
            NSSound.beep()
            return
        }
        openSessionLikeTableRow(entry)
    }

    // One user action for a table double-click and a trusted Insights link.
    // Keeping the decision here prevents report rendering from growing its own
    // subtly different terminal / Claude Desktop routing rules.
    private func openSessionLikeTableRow(_ entry: SessionIndexEntry) {
        if entry.isExternalSource {
            enterDetailsMode(for: entry)
            return
        }
        // Claude App has an exact-session URL even when a historical session
        // has no live cc-states entry. Other providers still need a tracked
        // host; detached sessions drill into their transcript.
        if claudeDesktopRouteId(entry) != nil
            || monitor.terminalKinds[entry.sessionId] != nil {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(entry.sessionId, forType: .string)
            openSessionHome(entry)
        } else {
            enterDetailsMode(for: entry)
        }
    }

    // MARK: - Terminal integration

    @objc private func liveStateChanged() {
        syncWaitTicker()
        syncBusyTicker()
        // "Go to terminal" enables only for a live selection, which can
        // flip as sessions start / die.
        window?.toolbar?.validateVisibleItems()
        // The terminal icon, status badge and perm-wait columns depend on
        // live state. Repaint only the visible rows whose live state actually
        // changed since the last repaint — not every visible row. A live-state
        // event fires whenever *any* session transitions, but usually only one
        // row's badge differs, and reloading a row recreates its cell views.
        var dirtyCols = IndexSet()
        for id in [ColumnID.terminal, ColumnID.status, ColumnID.permWait,
                   ColumnID.path, ColumnID.name, ColumnID.title] {
            if let col = outlineView.tableColumn(withIdentifier: id),
               !col.isHidden,
               let colIdx = outlineView.tableColumns.firstIndex(of: col) {
                dirtyCols.insert(colIdx)
            }
        }
        guard !dirtyCols.isEmpty else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        let waitingIds = Set(monitor.waiting.map(\.sessionId))
        var changedRows = IndexSet()
        for row in visible.location..<(visible.location + visible.length) {
            guard let node = outlineView.item(atRow: row) as? OutlineNode,
                  let sid = node.session?.sessionId else { continue }
            let composite = liveComposite(sid, waitingIds: waitingIds)
            if lastRenderedLive[sid] != composite {
                lastRenderedLive[sid] = composite
                changedRows.insert(row)
            }
        }
        guard !changedRows.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: changedRows, columnIndexes: dirtyCols)
    }

    // The live-state inputs that drive the terminal / status / perm-wait
    // cells for a session. Used to detect which rows actually need a repaint.
    private func liveComposite(_ sid: String, waitingIds: Set<String>) -> String {
        let state = monitor.kittyStates[sid] ?? ""
        let term = monitor.terminalKinds[sid] ?? ""
        let bundleId = monitor.hostBundleIds[sid] ?? ""
        let waiting = waitingIds.contains(sid) ? "w" : ""
        return "\(state)|\(term)|\(bundleId)|\(waiting)"
    }

    // While any session is parked on a permission prompt the Perm Wait
    // cells tick once a second; otherwise no timer exists at all. The
    // waiting set can only change together with a live-status change,
    // so liveStateChanged is the one place that needs to resync.
    private var waitTickTimer: Timer? {
        willSet { waitTickTimer?.invalidate() }
    }

    private func syncWaitTicker() {
        let needed = !monitor.waiting.isEmpty
        if needed && waitTickTimer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickWaitColumn() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            waitTickTimer = t
        } else if !needed && waitTickTimer != nil {
            waitTickTimer = nil
        }
    }

    private func tickWaitColumn() {
        guard window?.isVisible == true,
              let col = outlineView.tableColumn(withIdentifier: ColumnID.permWait),
              !col.isHidden,
              let colIdx = outlineView.tableColumns.firstIndex(of: col)
        else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integer: colIdx)
        )
    }

    // The pearlescent fill animates itself on the render server; this 1 s tick
    // only refreshes the elapsed mm:ss text of visible busy rows, in place (no
    // reload, constant width → no relayout). Runs only while something is busy
    // and the window is open.
    private var busyTickTimer: Timer? {
        willSet { busyTickTimer?.invalidate() }
    }

    private func syncBusyTicker() {
        let needed = monitor.hasBusy
        if needed && busyTickTimer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickBusyColumn() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            busyTickTimer = t
        } else if !needed && busyTickTimer != nil {
            busyTickTimer = nil
        }
    }

    private func tickBusyColumn() {
        guard window?.isVisible == true,
              let col = outlineView.tableColumn(withIdentifier: ColumnID.status),
              !col.isHidden,
              let colIdx = outlineView.tableColumns.firstIndex(of: col)
        else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard let node = outlineView.item(atRow: row) as? OutlineNode,
                  let sid = node.session?.sessionId,
                  let dur = monitor.busyDuration(for: sid),
                  let badge = outlineView.view(atColumn: colIdx, row: row, makeIfNecessary: false) as? StatusBadgeView
            else { continue }
            badge.configure(text: Self.busyText(dur), color: .white, background: nil, pearlescent: true)
        }
    }

    // Busy badge text is just the elapsed mm:ss — the activity cue is the
    // pearlescent fill animating on the pill (Core Animation, no per-frame work).
    private static func busyText(_ duration: TimeInterval?) -> String {
        guard let d = duration else { return "Busy" }
        let total = Int(d)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func formatWait(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row.adaptive")
        if let view = outlineView.makeView(withIdentifier: id, owner: self) as? AdaptiveRowView {
            return view
        }
        let view = AdaptiveRowView()
        view.identifier = id
        return view
    }

    // MARK: - Date formatting

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f
    }()

    private static let dateAndTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd HHmm")
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd HHmm")
        return f
    }()

    private static func absoluteTime(_ d: Date) -> String { absoluteFormatter.string(from: d) }

    // Trim the "openai-" / "claude-" prefix and the trailing "-N"
    // version suffix so the column reads "gpt-5.5" / "opus-4-8" rather
    // than the full pricing-table key.
    private static func prettyModelName(_ raw: String) -> String {
        var s = raw
        for prefix in ["openai-", "claude-"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        return s
    }

    // Compact timestamp: today → just "14:35"; older but same year
    // → "Jun 8 14:35"; previous years → "Jun 8 2025 14:35". Output
    // follows the user's locale (en uses 12-hour, ru uses 24-hour
    // etc.) thanks to setLocalizedDateFormatFromTemplate.
    private static func relativeTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return timeOnlyFormatter.string(from: d)
        }
        let now = Date()
        if cal.component(.year, from: d) == cal.component(.year, from: now) {
            return dateAndTimeFormatter.string(from: d)
        }
        return fullDateFormatter.string(from: d)
    }
}

// When a row is selected and the table is focused, AppKit paints the
// accent-colour highlight — but our plain NSTextField cells keep their
// light-appearance colours, leaving dark text on a saturated blue.
// Forcing the row's appearance to dark aqua while the highlight is
// shown makes every dynamic colour inside (labelColor,
// secondaryLabelColor, Theme.* tokens, attributed strings) resolve as
// in dark mode, exactly like native NSTableCellView behaviour. Drops
// back to inherited appearance when the selection loses emphasis
// (window inactive → gray highlight → regular text colours).
final class AdaptiveRowView: NSTableRowView {
    override var isSelected: Bool { didSet { selectionChanged() } }
    override var isEmphasized: Bool { didSet { selectionChanged() } }

    private func selectionChanged() {
        refreshAppearance()
        needsDisplay = true
        // Cell views that vary with selection (the colour swatch's white
        // ring) aren't auto-redrawn on selection — nudge them.
        for cell in subviews { cell.needsDisplay = true }
        applyChangesSelectionState()
    }

    // The changes column shows +/- counts in green/red, but on the selected,
    // focused row those should read as the default (white-on-accent) colour.
    private func applyChangesSelectionState() {
        let neutral = isSelected && isEmphasized
        for v in subviews { (v as? ChangesTextField)?.neutral = neutral }
    }

    // A reloaded cell can be added to an already-selected row; sync it.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let changes = subview as? ChangesTextField {
            changes.neutral = isSelected && isEmphasized
        }
    }

    private func refreshAppearance() {
        let wantsDark = isSelected && isEmphasized
        appearance = wantsDark ? NSAppearance(named: .darkAqua) : nil
    }

    // The rounded inset rect shared by the zebra stripe and the
    // selection capsule so they sit on identical geometry.
    private var capsule: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 1), xRadius: 6, yRadius: 6)
    }

    // Alternating background as a rounded capsule (odd rows only),
    // matching the selection shape — the modern macOS list look. Asking
    // the table for our live row index keeps the parity correct when
    // rows shift without a full reload.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let table = superview as? NSTableView else { return }
        let row = table.row(for: self)
        guard row >= 0, row % 2 == 1 else { return }
        NSColor.alternatingContentBackgroundColors[1].setFill()
        capsule.fill()
    }

    // Selection as a rounded capsule. The system .inset style only
    // rounds under specific conditions; painting it ourselves is
    // deterministic and aligns with the zebra above.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        capsule.fill()
    }
}

// NSTextField draws its content at the top of its frame by default —
// when AppKit sizes the cell view to the row height, single-line text
// hugs the top edge while the selection highlight fills the whole row,
// so the row looks vertically off. Subclassing the cell to translate
// the title rect to the row's vertical centre puts the text where the
// eye expects it.

// AppKit pins the disclosure triangle to the top-left of its outline
// cell, so with a non-default rowHeight it sits visually above the
// row's centred text. Repositioning it onto the row's vertical centre
// makes the chevron and the bold group label line up.
final class CenteredOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        let rowRect = rect(ofRow: row)
        frame.origin.y = rowRect.minY + (rowRect.height - frame.height) / 2
        return frame
    }

    // Esc clears the row selection — matches Finder / Mail.
    override func keyDown(with event: NSEvent) {
        // 53 is the keyCode for Escape.
        if event.keyCode == 53, allowsEmptySelection, selectedRow != -1 {
            deselectAll(nil)
            return
        }
        super.keyDown(with: event)
    }
}

final class CenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        let size = attributedStringValue.size()
        r.origin.y = rect.origin.y + (rect.size.height - size.height) / 2
        r.size.height = size.height
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

class CenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredTextFieldCell.self }
        set { _ = newValue }
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// The "+added / −removed" cell. Holds its counts so it can re-render in the
// neutral (default) colour when its row is selected and focused, and back to
// green/red otherwise — driven by AdaptiveRowView.
final class ChangesTextField: CenteredTextField {
    private var added: Int64 = 0
    private var removed: Int64 = 0
    var neutral = false { didSet { if oldValue != neutral { render() } } }

    override init() {
        super.init()
        usesSingleLineMode = true
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = false
        alignment = .right
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setChanges(added: Int64, removed: Int64) {
        self.added = added
        self.removed = removed
        render()
    }

    private func render() {
        attributedStringValue = MainWindowController.changesString(
            added: added, removed: removed, neutral: neutral
        )
    }
}

// Plain coloured circle that mirrors the chart bar colour for the
// session — restores the visual table↔chart link when the provider
// icon column isn't enough.
final class SessionColorSwatchView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private var rowSelected: Bool {
        var view: NSView? = superview
        while let cur = view {
            if let row = cur as? NSTableRowView { return row.isSelected }
            view = cur.superview
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot: CGFloat = 8
        let rect = NSRect(
            x: (bounds.width - dot) / 2,
            y: (bounds.height - dot) / 2,
            width: dot, height: dot
        )
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        // White ring around the dot while the row is selected.
        if rowSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

// Renders the official Anthropic / OpenAI brand mark for the row's
// session provider. The view IS an NSImageView — NSImageView centres
// its image inside its own bounds for free, and NSOutlineView gives
// the cell view the full column-width × row-height frame, so there's
// no container needed.
// Pill-shaped status badge: text label on top of an optional rounded
// background. Used in the Status column to make the waiting/busy
// state pop without flooding the eye with bullets or colour everywhere.
// Shared mother-of-pearl cycle. Active-session pills and the Insights glyph
// deliberately use one palette and cadence so the colour has one meaning.
private enum PearlescentPalette {
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 0.96).cgColor
    }

    static let a = [color(0.58, 0.18, 0.50), color(0.40, 0.20, 0.64), color(0.22, 0.30, 0.70)]
    static let b = [color(0.40, 0.20, 0.64), color(0.22, 0.30, 0.70), color(0.12, 0.44, 0.62)]
    static let c = [color(0.22, 0.30, 0.70), color(0.12, 0.44, 0.62), color(0.12, 0.52, 0.44)]

    static func animate(_ layer: CAGradientLayer, key: String) {
        layer.colors = a
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = [a, b, c, a]
        animation.duration = 4
        animation.calculationMode = .linear
        animation.repeatCount = .infinity
        layer.add(animation, forKey: key)
    }
}

// Animated gradient clipped to a square toolbar symbol. It overlays a native
// NSButton and opts out of hit-testing, preserving the button's standard round
// hover and pressed states.
private final class PearlescentToolbarIconView: NSView {
    private let gradient = CAGradientLayer()
    private let glyphMask = CALayer()

    init(image: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = glyphMask
        layer?.addSublayer(gradient)

        if let image {
            var rect = NSRect(origin: .zero, size: image.size)
            glyphMask.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        glyphMask.contentsGravity = .resizeAspect
        updateContentsScale()
        PearlescentPalette.animate(gradient, key: "pearl")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        glyphMask.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        gradient.contentsScale = scale
        glyphMask.contentsScale = scale
    }
}

final class StatusBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private let pearl = CAGradientLayer()
    private var pillVisibleConstraints: [NSLayoutConstraint] = []
    private var pillHiddenConstraints: [NSLayoutConstraint] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        autoresizingMask = [.width, .height]

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 5
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        // Iridescent fill for the busy state — animates its own colours on the
        // render server (no per-frame CPU). Hidden until a pearlescent configure.
        pearl.cornerRadius = 5
        pearl.cornerCurve = .continuous
        pearl.startPoint = CGPoint(x: 0, y: 0.5)
        pearl.endPoint = CGPoint(x: 1, y: 0.5)
        pearl.isHidden = true
        pill.layer?.addSublayer(pearl)

        // Proportional letters (not a mono font), but fixed-width digits so the
        // busy mm:ss timer keeps a constant width as it ticks (no relayout).
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            pill.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            pill.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            pill.topAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -13),
            pill.bottomAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        pearl.frame = pill.bounds
    }

    func configure(text: String, color: NSColor, background: NSColor?, pearlescent: Bool = false) {
        label.textColor = color
        label.stringValue = text
        if pearlescent {
            pill.isHidden = false
            pill.layer?.backgroundColor = NSColor.clear.cgColor
            startPearl()
        } else {
            stopPearl()
            if let bg = background {
                pill.isHidden = false
                pill.layer?.backgroundColor = bg.cgColor
            } else {
                pill.isHidden = true
            }
        }
    }

    // Slowly cross-fades the gradient through the palettes — Core Animation, so
    // it runs on the render server with zero main-thread / relayout cost.
    private func startPearl() {
        pearl.isHidden = false
        guard pearl.animation(forKey: "pearl") == nil else { return }
        PearlescentPalette.animate(pearl, key: "pearl")
    }

    private func stopPearl() {
        pearl.removeAnimation(forKey: "pearl")
        pearl.isHidden = true
    }
}

final class ColorDotView: NSView {
    private var provider: SessionProvider = .claude
    private var isLoading: Bool = false
    private let imageView = NSImageView()
    private lazy var spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isDisplayedWhenStopped = false
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: centerXAnchor),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            s.widthAnchor.constraint(equalToConstant: 14),
            s.heightAnchor.constraint(equalToConstant: 14),
        ])
        return s
    }()

    private static let anthropicImage: NSImage? = loadIcon(name: "anthropic")
    private static let openaiImage: NSImage? = loadIcon(name: "openai")

    private static func loadIcon(name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 14, height: 14)
        img.isTemplate = true
        return img
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.contentTintColor = .secondaryLabelColor
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // `color:` is accepted for call-site compatibility but ignored —
    // the user asked for unpainted official icons only.
    func configure(color: NSColor, provider: SessionProvider, isLoading: Bool) {
        if self.provider != provider || imageView.image == nil {
            self.provider = provider
            // Codex → OpenAI; Claude (CLI or desktop) → Anthropic.
            imageView.image = (provider == .codex)
                ? Self.openaiImage
                : Self.anthropicImage
        }
        if self.isLoading != isLoading {
            self.isLoading = isLoading
            imageView.isHidden = isLoading
            if isLoading {
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
            }
        }
    }
}


// MARK: - Toolbar (unified, Activity Monitor-style)

extension NSToolbarItem.Identifier {
    static let reindex = NSToolbarItem.Identifier("episcope.reindex")
    static let copySession = NSToolbarItem.Identifier("episcope.copySession")
    static let messages = NSToolbarItem.Identifier("episcope.messages")
    static let openTerminal = NSToolbarItem.Identifier("episcope.openTerminal")
    static let collapseAll = NSToolbarItem.Identifier("episcope.collapseAll")
    static let expandAll = NSToolbarItem.Identifier("episcope.expandAll")
    static let back = NSToolbarItem.Identifier("episcope.back")
    static let chartMode = NSToolbarItem.Identifier("episcope.chartMode")
    static let search = NSToolbarItem.Identifier("episcope.search")
    static let deepSearch = NSToolbarItem.Identifier("episcope.deepSearch")
    static let deepSearchField = NSToolbarItem.Identifier("episcope.deepSearchField")
    static let analyze = NSToolbarItem.Identifier("episcope.analyze")
    static let copyResume = NSToolbarItem.Identifier("episcope.copyResume")
    static let revealFinder = NSToolbarItem.Identifier("episcope.revealFinder")
    static let analyzeSession = NSToolbarItem.Identifier("episcope.analyzeSession")
    static let deleteSession = NSToolbarItem.Identifier("episcope.deleteSession")
}

extension MainWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func makeToolbar(id: String, centered: Set<NSToolbarItem.Identifier>) -> NSToolbar {
        let toolbar = NSToolbar(identifier: id)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = centered
        return toolbar
    }

    private func actionItem(
        _ id: NSToolbarItem.Identifier, symbol: String,
        label: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = Self.toolbarSymbol(symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar === searchToolbar {
            // flexibleSpace first so back sits immediately left of the field
            // (the trailing edge) — the same spot the deepSearch button holds
            // in list mode, so the button doesn't jump horizontally on toggle.
            return [.flexibleSpace, .back, .deepSearchField]
        }
        if toolbar === insightsToolbar {
            // Reuse the reports window's own items; only Back is ours.
            return [.back] + reportsWC.toolbarDefaultItemIdentifiers(toolbar)
        }
        if toolbar === detailsToolbar {
            return [.back, .copySession, .copyResume, .openTerminal, .revealFinder,
                    .analyzeSession, .deleteSession, .flexibleSpace, .search]
        }
        // Islands: reindex stands alone (data refresh), then the selection
        // actions (copy / messages / host app); a fixed space breaks the
        // toolbar capsule between them. Collapse / expand ride with the
        // selection group and only appear when grouping by directory.
        // Insights is fleet-level, so it belongs in the trailing global-actions
        // island with full search rather than beside session-scoped actions.
        var ids: [NSToolbarItem.Identifier] = [.reindex, .space, .copySession, .messages, .openTerminal]
        if groupByDir { ids += [.collapseAll, .expandAll] }
        ids += [.flexibleSpace, .chartMode, .flexibleSpace, .analyze, .deepSearch, .search]
        return ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // Insights mode reuses the reports window's toolbar items (run, Lab,
        // ask, delete/reveal/copy); only Back is ours.
        if toolbar === insightsToolbar, id != .back {
            return reportsWC.toolbar(toolbar, itemForItemIdentifier: id,
                                     willBeInsertedIntoToolbar: flag)
        }
        switch id {
        case .reindex:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Reindex sessions"
            item.toolTip = "Reindex sessions"
            item.view = makeReindexView()
            updateLoadingIndicator()
            return item
        case .copySession:
            let item = actionItem(id, symbol: "doc.on.doc",
                                  label: "Copy session ID", action: #selector(copySelectedSessionId))
            copyItems.append(item)
            return item
        case .messages:
            return actionItem(id, symbol: "bubble.left",
                              label: "Messages", action: #selector(openMessages))
        case .openTerminal:
            let item = actionItem(id, symbol: "terminal",
                                  label: "Open session app", action: #selector(openSelectedTerminal))
            openSessionItems.append(item)
            updateOpenSessionToolbarItems()
            return item
        case .collapseAll:
            return actionItem(id, symbol: "arrow.down.to.line.compact",
                              label: "Collapse all", action: #selector(collapseAll))
        case .expandAll:
            return actionItem(id, symbol: "arrow.up.to.line.compact",
                              label: "Expand all", action: #selector(expandAll))
        case .back:
            return actionItem(id, symbol: "chevron.left",
                              label: "Back", action: #selector(goBack))
        case .chartMode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = chartModeControl
            item.label = "Chart mode"
            return item
        case .search:
            return toolbar === detailsToolbar ? detailsSearchItem : listSearchItem
        case .deepSearchField:
            return deepSearchItem
        case .deepSearch:
            return actionItem(id, symbol: "text.magnifyingglass",
                              label: "Deep search (full text)", action: #selector(openDeepSearch))
        case .analyze:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Insights"
            item.toolTip = "Insights"
            item.view = makeInsightsItemView()
            refreshInsightsBadge()
            return item
        case .copyResume:
            return actionItem(id, symbol: "list.clipboard",
                              label: "Copy Resume Command", action: #selector(copyResumeCommand))
        case .revealFinder:
            return actionItem(id, symbol: "folder",
                              label: "Reveal Transcript in Finder", action: #selector(revealTranscriptInFinder))
        case .analyzeSession:
            return actionItem(id, symbol: "sparkles",
                              label: "Analyze Session", action: #selector(analyzeClickedSession))
        case .deleteSession:
            return actionItem(id, symbol: "trash",
                              label: "Delete Session", action: #selector(deleteClickedSession))
        default:
            return nil
        }
    }

    // Enable/disable instead of hide/show — the Activity Monitor way.
    // NSToolbar revalidates on user events; selection changes call
    // revalidateToolbar() explicitly.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.toolbar === insightsToolbar, item.itemIdentifier != .back {
            return reportsWC.validateToolbarItem(item)
        }
        switch item.itemIdentifier {
        case .copySession, .revealFinder, .analyzeSession:
            return actionSession() != nil
        case .copyResume, .deleteSession:
            return actionSession().map(isCliSession) ?? false
        case .messages:
            return detailEntry == nil && selectedSession() != nil
        case .openTerminal:
            // Claude App can address an indexed historical session directly;
            // other providers require a live host from cc-states.json.
            guard let s = actionSession() else { return false }
            return !s.isExternalSource && (claudeDesktopRouteId(s) != nil
                || monitor.terminalKinds[s.sessionId] != nil
            )
        default:
            return true
        }
    }
}
