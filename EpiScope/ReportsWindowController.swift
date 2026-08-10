import AppKit
import UserNotifications

// One analysis run, fully resolved — no user-facing knobs. Every entry
// point (daily / weekly schedule, "Analyze Session…" on a row) builds
// one of these with fixed sensible defaults.
nonisolated struct AnalysisJobConfig {
    let type: AnalysisType
    let entries: [SessionIndexEntry]     // resolved scope, newest first
    let question: String?
    let model: String                    // CLI --model argument
    let scopeCwd: String?                // set when the scope is one project
    var titleOverride: String?
    var notify = false                   // banner when the report is ready
    // Overrides the prompt template for an insights-type run. Lets the Insights
    // Lab reuse the catalog+packets pipeline with a different prompt per
    // analytics variant (lab-<variant>). nil ⇒ the default "insights".
    var promptName: String?
    // Interval the report attributes work to — catalog metrics are windowed to
    // [now-window, now]. nil ⇒ lifetime totals (all-time).
    var window: TimeInterval?
}

// The Reports window: past analysis reports on the left (newest first,
// with an "analyzing…" row while a run is live), the rendered markdown
// on the right. Also owns the whole run pipeline: scope → packets
// (off-main) → prompt → AnalysisRunner → saved report.
@MainActor
final class ReportsWindowController: NSWindowController {
    private let indexer: SessionIndexer
    private let searchIndex: SearchIndex
    private let store: ReportStore
    private let runner: AnalysisRunner

    private var reports: [AnalysisReport] = []
    // Non-nil while a run is being prepared / executed — rendered as a
    // synthetic first table row with a ticking elapsed label.
    private var runningTitle: String?
    private var runStartedAt: Date?
    private var elapsedTimer: Timer?

    // Set by MainWindowController. Insights owns rendering, while the main
    // window owns the canonical table-row opening behaviour and host routing.
    var onOpenSession: ((String) -> Void)?

    private let tableView = NSTableView()
    private let textView = ReportTextView.make()
    private let cancelButton = NSButton(title: "Cancel analysis", target: nil, action: nil)
    // The content view (list + detail split), exposed so the main window can
    // host Insights inline instead of as a separate window.
    private(set) var rootView: NSView!

    init(indexer: SessionIndexer, searchIndex: SearchIndex,
         store: ReportStore, runner: AnalysisRunner) {
        self.indexer = indexer
        self.searchIndex = searchIndex
        self.store = store
        self.runner = runner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Reports"
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("EpiScopeReportsWindow")
        super.init(window: window)
        buildContent()
        reports = store.list()
        tableView.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show() {
        reports = store.list()
        tableView.reloadData()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildContent() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        // Per-report actions live here, not in the toolbar — the Insights mode
        // is intentionally bare (just the runs list + the report itself).
        tableView.menu = makeRowMenu()
        for (id, title, width) in [("title", "Report", 320.0),
                                   ("cost", "Cost", 56.0),
                                   ("date", "Date", 110.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            if id == "title" { col.resizingMask = .autoresizingMask }
            tableView.addTableColumn(col)
        }
        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 16, height: 18)
        textView.autoresizingMask = [.width]
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true

        cancelButton.target = self
        cancelButton.action = #selector(cancelAnalysis)
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let right = NSView()
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(textScroll)
        right.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: right.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            cancelButton.topAnchor.constraint(equalTo: right.topAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(right)
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        rootView = split
        window?.contentView = split
        split.setPosition(430, ofDividerAt: 0)
    }

    // Embedded-mode hooks — the main window hosts this content as an Insights
    // mode (à la deep search) rather than a separate window.
    func embeddableView() -> NSView { rootView }

    // Newest completed report's timestamp — drives the main window's unread
    // Insights badge (a still-running / failed run isn't something to read).
    func newestCompletedReportDate() -> Date? {
        store.list().first { $0.status == .completed }?.createdAt
    }

    // Called whenever the Insights mode is entered — reload and land on the
    // latest run so the freshest report is on screen without a click.
    func refresh() {
        reports = store.list()
        tableView.reloadData()
        if !reports.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
        renderSelection()
    }

    // MARK: - Run entry points (no dialogs — fixed sensible defaults)

    // The analysis model is the only knob besides the daily on/off
    // (Settings → Analysis Model). Defaults to Sonnet 4.6.
    static var defaultModel: String {
        UserDefaults.standard.string(forKey: "analysisModel") ?? "claude-sonnet-4-6"
    }

    private func visibleEntries(within seconds: TimeInterval?) -> [SessionIndexEntry] {
        var out = indexer.entries.filter { !$0.isTemporary }
        if let seconds {
            let cutoff = Date().addingTimeInterval(-seconds)
            out = out.filter { $0.lastActivity >= cutoff }
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    // Scheduled by AppDelegate once per day: a management overview of
    // the last 24h, delivered as a notification banner. Quietly skips
    // days with nothing worth reporting.
    // Returns whether a run actually started. The scheduler must not mark the
    // day done on a refusal — see AppDelegate.maybeRunDailyInsights.
    @discardableResult
    func runDailyInsights() -> Bool {
        guard !runner.isRunning, runningTitle == nil else { return false }
        let scope = visibleEntries(within: 86_400)
        guard scope.count >= 2 else { return false }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("MMMd")
        var config = AnalysisJobConfig(
            type: .insights, entries: scope, question: nil,
            model: Self.defaultModel, scopeCwd: nil)
        config.titleOverride = "Daily insights — \(day.string(from: Date()))"
        config.window = 86_400
        config.notify = true
        return startAnalysis(config)
    }

    // Scheduled by AppDelegate on Monday morning: the same overview over the
    // past 7 days, delivered as a separate report alongside that day's daily one.
    @discardableResult
    func runWeeklyInsights() -> Bool {
        guard !runner.isRunning, runningTitle == nil else { return false }
        let scope = visibleEntries(within: 7 * 86_400)
        guard scope.count >= 2 else { return false }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("MMMd")
        var config = AnalysisJobConfig(
            type: .insights, entries: scope, question: nil,
            model: Self.defaultModel, scopeCwd: nil)
        config.titleOverride = "Weekly insights — \(day.string(from: Date()))"
        config.window = 7 * 86_400
        config.notify = true
        return startAnalysis(config)
    }

    // "Analyze Session…" on a row — straight to a retro of that session.
    func runRetro(_ entry: SessionIndexEntry) {
        guard !runner.isRunning, runningTitle == nil else { NSSound.beep(); return }
        startAnalysis(AnalysisJobConfig(
            type: .retro, entries: [entry], question: nil,
            model: Self.defaultModel, scopeCwd: entry.cwd))
    }

    @discardableResult
    private func startAnalysis(_ config: AnalysisJobConfig) -> Bool {
        guard !runner.isRunning, runningTitle == nil else { NSSound.beep(); return false }
        let workDir = AnalysisRunner.makeWorkDir()
        let packetsDir = workDir.appendingPathComponent("packets", isDirectory: true)
        try? FileManager.default.createDirectory(at: packetsDir, withIntermediateDirectories: true)

        runningTitle = reportTitle(for: config)
        runStartedAt = Date()
        startElapsedTimer()
        NotificationCenter.default.post(name: .insightsRunStateChanged, object: nil)
        tableView.reloadData()
        tableView.selectRowIndexes([0], byExtendingSelection: false)

        switch config.type {
        case .question:
            prepareQuestion(config, workDir: workDir, packetsDir: packetsDir)
        case .insights:
            prepareInsights(config, workDir: workDir, packetsDir: packetsDir)
        default:
            prepareRetro(config, workDir: workDir, packetsDir: packetsDir)
        }
        return true
    }

    private func prepareRetro(_ config: AnalysisJobConfig, workDir: URL, packetsDir: URL) {
        guard let entry = config.entries.first else { return }
        let raw = SessionIndexer.transcriptURL(for: entry)
        let packet = packetsDir.appendingPathComponent("session-\(entry.sessionId).md")
        WorkScheduler.shared.run(.init(id: "analysis-prep", group: WorkScheduler.Group.analysis,
                                      priority: .background, coalesce: false)) { [weak self] in
            let ok = TranscriptExtractor.buildPacket(for: entry, to: packet)
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    self.failPreparation("The session's transcript file could not be read.",
                                         config: config)
                    return
                }
                let vars = [
                    "PACKET_PATH": packet.path,
                    "RAW_PATH": raw?.path ?? "(unavailable)",
                    "COST": String(format: "$%.2f", entry.costUSD),
                ]
                guard let prompt = PromptLibrary.render("retro", vars: vars) else {
                    self.failPreparation("Prompt template “retro” is missing.", config: config)
                    return
                }
                var addDirs = [workDir]
                if let rawDir = raw?.deletingLastPathComponent() { addDirs.append(rawDir) }
                self.launch(config, prompt: prompt, addDirs: addDirs,
                            workDir: workDir, maxTurns: 25)
            }
        }
    }

    // Management overview: the catalog carries the numbers for the whole
    // scope; the most expensive sessions also get digests so the agent
    // has qualitative material (tool churn, what actually happened) for
    // its bottleneck / worth-noting calls.
    private func prepareInsights(_ config: AnalysisJobConfig, workDir: URL, packetsDir: URL) {
        let topByCost = Array(config.entries
            .sorted { $0.costUSD > $1.costUSD }
            .prefix(8))
        let catalog = workDir.appendingPathComponent("catalog.md")
        let allEntries = config.entries
        WorkScheduler.shared.run(.init(id: "analysis-prep", group: WorkScheduler.Group.analysis,
                                      priority: .background, coalesce: false)) { [weak self] in
            let since = config.window.map { Date().addingTimeInterval(-$0) }
            TranscriptExtractor.buildCatalog(entries: allEntries, to: catalog, since: since)
            for e in topByCost {
                TranscriptExtractor.buildPacket(
                    for: e,
                    to: packetsDir.appendingPathComponent("session-\(e.sessionId).md"),
                    maxBytes: 60_000)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let vars = [
                    "CATALOG_PATH": catalog.path,
                    "PACKET_DIR": packetsDir.path,
                    "PACKET_COUNT": String(topByCost.count),
                ]
                let promptName = config.promptName ?? "insights"
                guard let prompt = PromptLibrary.render(promptName, vars: vars) else {
                    self.failPreparation("Prompt template “\(promptName)” is missing.", config: config)
                    return
                }
                let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".claude/projects", directoryHint: .isDirectory)
                self.launch(config, prompt: prompt, addDirs: [workDir, projectsRoot],
                            workDir: workDir, maxTurns: 20)
            }
        }
    }

    private func prepareQuestion(_ config: AnalysisJobConfig, workDir: URL, packetsDir: URL) {
        let question = config.question ?? ""
        searchIndex.search(question) { [weak self] hits in
            self?.questionSearchDone(config, hits: hits,
                                     workDir: workDir, packetsDir: packetsDir)
        }
    }

    private func questionSearchDone(_ config: AnalysisJobConfig, hits: [MessageHit],
                                    workDir: URL, packetsDir: URL) {
        let scopeIds = Set(config.entries.map(\.sessionId))
        var hitCounts: [String: Int] = [:]
        for h in hits where scopeIds.contains(h.sessionId) {
            hitCounts[h.sessionId, default: 0] += 1
        }
        // Full packets only for the sessions the FTS pre-search points at
        // (fallback: the most recent ones); everything else is reachable
        // via the catalog + raw grep.
        var packetEntries = config.entries
            .filter { hitCounts[$0.sessionId] != nil }
            .sorted { hitCounts[$0.sessionId]! > hitCounts[$1.sessionId]! }
        packetEntries = Array(packetEntries.prefix(8))
        if packetEntries.isEmpty { packetEntries = Array(config.entries.prefix(5)) }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let ftsLines = hits
            .filter { scopeIds.contains($0.sessionId) }
            .prefix(12)
            .map { h -> String in
                let clean = h.marked
                    .replacingOccurrences(of: SearchIndex.hlStart, with: "")
                    .replacingOccurrences(of: SearchIndex.hlEnd, with: "")
                let date = h.timestamp.map { day.string(from: $0) } ?? "—"
                return "- \(h.sessionId) · \(date) · “\(clean)”"
            }

        let catalog = workDir.appendingPathComponent("catalog.md")
        let allEntries = config.entries
        WorkScheduler.shared.run(.init(id: "analysis-prep", group: WorkScheduler.Group.analysis,
                                      priority: .background, coalesce: false)) { [weak self] in
            TranscriptExtractor.buildCatalog(entries: allEntries, to: catalog)
            for e in packetEntries {
                TranscriptExtractor.buildPacket(
                    for: e,
                    to: packetsDir.appendingPathComponent("session-\(e.sessionId).md"),
                    maxBytes: 80_000)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let vars = [
                    "QUESTION": config.question ?? "",
                    "CATALOG_PATH": catalog.path,
                    "PACKET_DIR": packetsDir.path,
                    "FTS_HITS": ftsLines.isEmpty
                        ? "(no full-text matches — rely on the catalog)"
                        : ftsLines.joined(separator: "\n"),
                ]
                guard let prompt = PromptLibrary.render("question", vars: vars) else {
                    self.failPreparation("Prompt template “question” is missing.", config: config)
                    return
                }
                // The whole projects root, so any raw transcript listed in
                // the catalog is grep-able (read-only tools regardless).
                let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".claude/projects", directoryHint: .isDirectory)
                self.launch(config, prompt: prompt, addDirs: [workDir, projectsRoot],
                            workDir: workDir, maxTurns: 15)
            }
        }
    }

    private func launch(_ config: AnalysisJobConfig, prompt: String,
                        addDirs: [URL], workDir: URL, maxTurns: Int) {
        // config.model carries the menu id (which is also the pricing key); the
        // CLI is asked for that engine's own name for the same model.
        let choice = AnalysisModelChoice.named(config.model)
        var request = AnalysisRequest(prompt: prompt, addDirs: addDirs,
                                      engine: choice.engine,
                                      model: choice.cliModel, workDir: workDir)
        request.maxTurns = maxTurns
        runner.run(request) { [weak self] result in
            self?.runFinished(config, result: result)
        }
    }

    private func failPreparation(_ message: String, config: AnalysisJobConfig) {
        clearRunningState()
        var report = makeReport(config, status: .failed)
        report.errorSummary = message
        insertSaved(store.save(report, markdown: ""))
        tableView.reloadData()
    }

    private func runFinished(_ config: AnalysisJobConfig,
                             result: Result<AnalysisOutcome, AnalysisError>) {
        clearRunningState()
        switch result {
        case .success(let outcome):
            var report = makeReport(config, status: .completed)
            report.costUSD = outcome.costUSD
            report.agentSessionId = outcome.agentSessionId
            report.durationSec = outcome.durationSec
            report.numTurns = outcome.numTurns
            let saved = store.save(report, markdown: outcome.markdown)
            insertSaved(saved)
            if config.notify { notifyReportReady(saved) }
        case .failure(.cancelled):
            var report = makeReport(config, status: .cancelled)
            report.errorSummary = "Cancelled."
            insertSaved(store.save(report, markdown: ""))
        case .failure(.cliNotFound(let engine)):
            tableView.reloadData()
            presentCLINotFound(engine)
        case .failure(let error):
            // No alert: the failure is already a row in the list with the
            // message in its body, and most runs are the daily/weekly ones
            // nobody asked for right now — a modal over whatever the operator
            // is doing is the wrong way to report them. The CLI-missing case
            // above keeps its dialog because it offers a fix.
            var report = makeReport(config, status: .failed)
            report.errorSummary = error.userMessage
            insertSaved(store.save(report, markdown: ""))
        }
    }

    private func makeReport(_ config: AnalysisJobConfig,
                            status: AnalysisReport.Status) -> AnalysisReport {
        AnalysisReport(
            id: UUID().uuidString,
            type: config.type,
            createdAt: Date(),
            title: reportTitle(for: config),
            question: config.question,
            scopeSessionIds: config.entries.map(\.sessionId),
            scopeCwd: config.scopeCwd,
            model: config.model,
            costUSD: nil, agentSessionId: nil, durationSec: nil, numTurns: nil,
            status: status, errorSummary: nil, fileBase: nil)
    }

    private func reportTitle(for config: AnalysisJobConfig) -> String {
        if let override = config.titleOverride { return override }
        let scope: String
        if config.type == .retro, let e = config.entries.first {
            scope = e.folderName
        } else if let cwd = config.scopeCwd {
            scope = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            scope = "All sessions"
        }
        if let q = config.question {
            let short = q.count > 40 ? String(q.prefix(40)) + "…" : q
            return "\(config.type.displayName) — \(short)"
        }
        return "\(config.type.displayName) — \(scope)"
    }

    private func insertSaved(_ report: AnalysisReport) {
        reports.insert(report, at: 0)
        tableView.reloadData()
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        renderSelection()
    }

    private func clearRunningState() {
        runningTitle = nil
        runStartedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        cancelButton.isHidden = true
        NotificationCenter.default.post(name: .insightsRunStateChanged, object: nil)
    }

    // Is an analysis in flight? Drives the toolbar's pulsing ✦.
    var isAnalysisRunning: Bool { runningTitle != nil }

    private func startElapsedTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.runningTitle != nil else { return }
                self.tableView.reloadData(forRowIndexes: [0], columnIndexes: [0])
                if self.tableView.selectedRow == 0 { self.renderSelection() }
            }
        }
        timer.tolerance = 0.3
        elapsedTimer = timer
    }

    @objc private func cancelAnalysis() {
        runner.cancel()
    }

    // The daily run happens unattended — the banner is how the report
    // reaches the user. Tap routing lives in TerminalTracker (the app's
    // notification delegate).
    private func notifyReportReady(_ report: AnalysisReport) {
        let content = UNMutableNotificationContent()
        content.title = "Daily insights ready"
        content.body = report.title
        content.userInfo = ["episcopeReport": report.fileBase ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "episcope-report-\(report.id)", content: content, trigger: nil))
    }

    // MARK: - Alerts

    // Recovery path for a missing CLI: pick the binary by hand — saved to that
    // engine's own path default, which its locate() checks first. Which CLI is
    // missing depends on the chosen model, so the alert names it rather than
    // assuming Claude.
    private func presentCLINotFound(_ engine: AnalysisEngine) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(engine.cliName) CLI not found"
        alert.informativeText = engine.cliMissingMessage
        alert.addButton(withTitle: "Choose Binary…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { self?.pickCLIBinary(engine) }
        }
    }

    private func pickCLIBinary(_ engine: AnalysisEngine) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Select the \(engine.cliName) CLI binary"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: engine.cliPathDefaultsKey)
        }
    }

    // MARK: - Detail rendering

    private func renderSelection() {
        let row = tableView.selectedRow
        cancelButton.isHidden = !(runningTitle != nil && row == 0)
        guard row >= 0 else {
            textView.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        if runningTitle != nil && row == 0 {
            let elapsed = runStartedAt.map { Int(-$0.timeIntervalSinceNow) } ?? 0
            let body = NSAttributedString(
                string: "Analyzing…\n\n\(runningTitle ?? "")\nElapsed: \(format(elapsed: elapsed))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            textView.textStorage?.setAttributedString(body)
            return
        }
        guard let report = report(at: row) else { return }

        let out = NSMutableAttributedString()
        let meta = NSMutableParagraphStyle()
        meta.paragraphSpacing = 10
        var metaLine = "\(report.title)  ·  \(Self.dateFormatter.string(from: report.createdAt))"
            + "  ·  \(report.model)"
        if let cost = report.costUSD { metaLine += String(format: "  ·  $%.2f", cost) }
        if let dur = report.durationSec { metaLine += String(format: "  ·  %.0fs", dur) }
        metaLine += "  ·  \(report.scopeSessionIds.count) session(s)"
        out.append(NSAttributedString(string: metaLine + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: meta,
        ]))
        switch report.status {
        case .completed:
            let markdown = store.markdown(for: report) ?? "(report file missing)"
            // Give the report body real leading: the source is one line per
            // bullet/paragraph, so lineSpacing airs out wrapped lines and
            // paragraphSpacing separates adjacent bullets (blank source lines
            // still break sections). Without this the text reads as a wall.
            let body = NSMutableParagraphStyle()
            body.lineSpacing = 4
            body.paragraphSpacing = 8
            let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(
                markdown, baseFont: .systemFont(ofSize: 14),
                paragraphStyle: body, codeBackground: .quaternaryLabelColor))
            linkSessionReferences(in: rendered, report: report)
            out.append(rendered)
        case .failed:
            out.append(NSAttributedString(
                string: report.errorSummary ?? "Failed.",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.systemRed]))
        case .cancelled:
            out.append(NSAttributedString(
                string: "Cancelled before completion.",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        textView.textStorage?.setAttributedString(out)
        textView.scroll(.zero)
    }

    // Reports are model output, so MarkdownRenderer intentionally refuses all
    // custom URL schemes. Add internal session links only after rendering and
    // only for ids that both belong to this report's saved scope and still
    // exist in the index. The model cannot choose the link destination.
    private func linkSessionReferences(
        in text: NSMutableAttributedString,
        report: AnalysisReport
    ) {
        let available = Set(indexer.entries.map(\.sessionId))
        var owners: [String: Set<String>] = [:]

        for sid in report.scopeSessionIds where available.contains(sid) {
            var tokens = [sid, String(sid.prefix(8))]
            // Cowork/local-agent ids start with `local_`; reports may shorten
            // either the full storage id or its UUID portion.
            if sid.hasPrefix("local_") {
                let uuid = String(sid.dropFirst("local_".count))
                tokens.append(String(uuid.prefix(8)))
                tokens.append("local_" + String(uuid.prefix(8)))
            }
            for token in tokens where token.count >= 8 {
                owners[token.lowercased(), default: []].insert(sid)
            }
        }

        let whole = NSRange(location: 0, length: text.length)
        for (token, ids) in owners where ids.count == 1 {
            guard let sid = ids.first,
                  let target = URL(string: "episcope-session://open/\(sid)") else { continue }
            // Session references are standalone tokens. This keeps the short
            // form from matching the beginning of a full UUID.
            let escaped = NSRegularExpression.escapedPattern(for: token)
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_-])\(escaped)(?![A-Za-z0-9_-])",
                options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text.string, range: whole) {
                text.addAttributes([
                    .link: target,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .toolTip: "Open session",
                ], range: match.range)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return f
    }()

    private func format(elapsed: Int) -> String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func report(at row: Int) -> AnalysisReport? {
        let idx = runningTitle != nil ? row - 1 : row
        guard reports.indices.contains(idx) else { return nil }
        return reports[idx]
    }

    private func selectedReport() -> AnalysisReport? {
        report(at: tableView.selectedRow)
    }

    // MARK: - Toolbar actions

    // Right-click a run to manage it — the only place runs are managed now
    // (the mode's toolbar is just Back). Handlers resolve their target from the
    // clicked row, falling back to the selection.
    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Copy Report", #selector(copyReport)),
                                ("Reveal in Finder", #selector(revealReport))] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let del = NSMenuItem(title: "Delete", action: #selector(deleteReport), keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        return menu
    }

    private func targetReport() -> AnalysisReport? {
        let clicked = tableView.clickedRow
        return clicked >= 0 ? report(at: clicked) : selectedReport()
    }

    @objc private func deleteReport() {
        guard let report = targetReport() else { return }
        store.delete(report)
        reports.removeAll { $0.id == report.id }
        tableView.reloadData()
        renderSelection()
    }

    @objc private func revealReport() {
        guard let report = targetReport(),
              let url = store.markdownURL(for: report),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyReport() {
        guard let report = targetReport(),
              let markdown = store.markdown(for: report) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
    }
}

extension ReportsWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let report = targetReport() else { return false }
        switch menuItem.action {
        case #selector(revealReport), #selector(copyReport):
            return report.status == .completed
        default:
            return true
        }
    }
}

// Internal report links never reach NSWorkspace. Ordinary web links still use
// NSTextView's default handling; MarkdownRenderer has already rejected every
// non-web target supplied by model output.
extension ReportsWindowController: NSTextViewDelegate {
    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL,
              url.scheme?.lowercased() == "episcope-session" else { return false }
        guard url.host == "open",
              let sid = url.pathComponents.last,
              SessionID.isValid(sid) else { return true }
        onOpenSession?(sid)
        return true
    }
}

// MARK: - Table

extension ReportsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        reports.count + (runningTitle != nil ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier.rawValue else { return nil }
        let cellId = NSUserInterfaceItemIdentifier("reportCell-" + colId)
        // Wrap the label in a cell view pinned to centerY so text stays
        // vertically centered in the row regardless of row height.
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let field = cell.textField!
        field.font = (colId == "cost" || colId == "date")
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.alignment = colId == "cost" ? .right : .natural

        if runningTitle != nil && row == 0 {
            if colId == "title" {
                let elapsed = runStartedAt.map { Int(-$0.timeIntervalSinceNow) } ?? 0
                field.stringValue = "⏳ \(runningTitle ?? "Analyzing…") · \(format(elapsed: elapsed))"
                field.textColor = .secondaryLabelColor
            } else {
                field.stringValue = ""
            }
            return cell
        }
        guard let report = report(at: row) else { return nil }
        switch colId {
        case "title":
            var title = report.title
            if report.status == .failed { title = "⚠︎ " + title }
            if report.status == .cancelled { title = "✕ " + title }
            field.stringValue = title
        case "cost":
            field.stringValue = report.costUSD.map { String(format: "$%.2f", $0) } ?? "—"
        case "date":
            field.stringValue = Self.dateFormatter.string(from: report.createdAt)
            field.textColor = .secondaryLabelColor
        default:
            field.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        renderSelection()
        window?.toolbar?.validateVisibleItems()
    }
}

// The report body's text view. Caps the line measure: at full window width a
// report line runs 150+ characters, which is the main reason it reads as a
// wall — the eye loses the line on the way back. Extra width becomes margin
// instead, so the column stays a comfortable ~90 characters and centred.
private final class ReportTextView: NSTextView {
    private let maxMeasure: CGFloat = 720

    // Hand-built TextKit 1 stack — the only way to install the chip-drawing
    // layout manager (a plain NSTextView() would come up on TextKit 2).
    static func make() -> ReportTextView {
        let storage = NSTextStorage()
        let layout = CodeChipLayoutManager()
        storage.addLayoutManager(layout)
        let huge = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 0, height: huge))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = ReportTextView(frame: .zero, textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: huge, height: huge)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        return view
    }

    override func setFrameSize(_ newSize: NSSize) {
        let side = max(16, (newSize.width - maxMeasure) / 2)
        if abs(textContainerInset.width - side) > 0.5 {
            textContainerInset = NSSize(width: side, height: textContainerInset.height)
        }
        super.setFrameSize(newSize)
    }
}

// Draws `.backgroundColor` runs (code spans) as padded, rounded chips. The
// stock fill is a tight rect the full height of the line fragment, which with
// the report's leading looks like a stripe rather than a code chip.
private final class CodeChipLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        color.setFill()
        let path = NSBezierPath()
        for i in 0..<count {
            // Widen a touch so glyphs don't touch the edge, and trim the
            // line-spacing padding off the top/bottom.
            let rect = rectArray[i].insetBy(dx: -3, dy: 1.5)
            path.append(NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4))
        }
        path.fill()
    }
}

// MARK: - Toolbar

// Insights is embedded in the main window as a bare mode: its only toolbar item
// is the Back button (owned by MainWindowController). This controller vends no
// toolbar items — runs happen automatically (daily / weekly), and a run is
// managed from the runs-list right-click menu.
extension ReportsWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
}
