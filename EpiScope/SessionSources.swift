import AppKit

extension Notification.Name {
    static let sessionSourcesChanged = Notification.Name("episcope.sessionSourcesChanged")
}

nonisolated enum SessionSourceLayout: String, Codable, Sendable, CaseIterable {
    case auto
    case claude
    case codex
    case claudeDesktop

    var title: String {
        switch self {
        case .auto: return "Auto Detect"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .claudeDesktop: return "Claude Desktop"
        }
    }
}

nonisolated struct SessionSource: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var rootPath: String
    var layout: SessionSourceLayout
    var enabled: Bool
    var lastSuccessfulSync: Date?
}

nonisolated struct SessionIndexRoot: Sendable {
    let sourceID: String
    let sourceName: String
    let provider: SessionProvider
    let url: URL
    let external: Bool
}

@MainActor
final class SessionSourceStore {
    static let shared = SessionSourceStore()

    static let builtInClaudeID = "builtin.claude"
    static let builtInCodexID = "builtin.codex"
    static let builtInClaudeDesktopID = "builtin.claude-desktop"

    enum Availability: Equatable {
        case available
        case syncing
        case stale(Date?)
        case offline(Date?)

        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
    }

    private struct StoredSources: Codable {
        var version = 1
        var sources: [SessionSource]
    }

    nonisolated private static let baseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appending(path: "EpiScope", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    nonisolated private static let storeURL = baseURL.appending(path: "session-sources.json")
    nonisolated private static let snapshotsURL: URL = {
        let url = baseURL.appending(path: "session-sources", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: url.path)
        return url
    }()

    private(set) var customSources: [SessionSource] = []
    private var availability: [String: Availability] = [:]
    private var processes: [String: Process] = [:]
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var failures: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    private var started = false

    private init() {
        load()
        for source in customSources {
            availability[source.id] = snapshotExists(for: source.id)
                ? .stale(source.lastSuccessfulSync) : .offline(source.lastSuccessfulSync)
        }
    }

    nonisolated static func validatedSnapshotPath(_ path: String) -> URL? {
        let root = snapshotsURL.resolvingSymlinksInPath().standardizedFileURL.path
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(root + "/") ? url : nil
    }

    var allSources: [SessionSource] { Self.builtIns + customSources }

    static var builtIns: [SessionSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SessionSource(id: builtInClaudeID, name: "Claude Code",
                          rootPath: home.appending(path: ".claude/projects").path,
                          layout: .claude, enabled: true, lastSuccessfulSync: nil),
            SessionSource(id: builtInCodexID, name: "Codex",
                          rootPath: home.appending(path: ".codex/sessions").path,
                          layout: .codex, enabled: true, lastSuccessfulSync: nil),
            SessionSource(id: builtInClaudeDesktopID, name: "Claude Desktop",
                          rootPath: home.appending(
                            path: "Library/Application Support/Claude/local-agent-mode-sessions").path,
                          layout: .claudeDesktop, enabled: true, lastSuccessfulSync: nil),
        ]
    }

    func start() {
        guard !started else { return }
        started = true
        WorkScheduler.shared.register(.init(
            id: "external-session-sources", interval: 30, target: .main, initialDelay: 2
        ) { [weak self] in
            MainActor.assumeIsolated { self?.syncEnabledSources() }
        })
    }

    func source(id: String) -> SessionSource? {
        allSources.first { $0.id == id }
    }

    func state(for sourceID: String) -> Availability {
        if sourceID.hasPrefix("builtin.") { return .available }
        return availability[sourceID] ?? .offline(nil)
    }

    func isOffline(sourceID: String) -> Bool { state(for: sourceID).isOffline }

    func indexRoots() -> [SessionIndexRoot] {
        var roots = [
            SessionIndexRoot(sourceID: Self.builtInClaudeID, sourceName: "Claude Code",
                             provider: .claude, url: SessionProvider.claude.watchRoot,
                             external: false),
            SessionIndexRoot(sourceID: Self.builtInCodexID, sourceName: "Codex",
                             provider: .codex, url: SessionProvider.codex.watchRoot,
                             external: false),
            SessionIndexRoot(sourceID: Self.builtInClaudeDesktopID,
                             sourceName: "Claude Desktop", provider: .claudeDesktop,
                             url: SessionProvider.claudeDesktop.watchRoot, external: false),
        ]
        for source in customSources where source.enabled {
            let snapshot = snapshotURL(for: source.id)
            roots.append(SessionIndexRoot(
                sourceID: source.id, sourceName: source.name, provider: .claude,
                url: snapshot.appending(path: "claude", directoryHint: .isDirectory), external: true))
            roots.append(SessionIndexRoot(
                sourceID: source.id, sourceName: source.name, provider: .codex,
                url: snapshot.appending(path: "codex", directoryHint: .isDirectory), external: true))
            roots.append(SessionIndexRoot(
                sourceID: source.id, sourceName: source.name, provider: .claudeDesktop,
                url: snapshot.appending(path: "claude-desktop", directoryHint: .isDirectory),
                external: true))
        }
        return roots
    }

    @discardableResult
    func add(name: String, rootPath: String,
             layout: SessionSourceLayout = .auto) -> SessionSource {
        let source = SessionSource(
            id: UUID().uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            rootPath: URL(fileURLWithPath: rootPath).standardizedFileURL.path,
            layout: layout, enabled: true, lastSuccessfulSync: nil)
        customSources.append(source)
        availability[source.id] = .offline(nil)
        save()
        changed()
        sync(sourceID: source.id, force: true)
        return source
    }

    func update(_ source: SessionSource) {
        guard let index = customSources.firstIndex(where: { $0.id == source.id }) else { return }
        customSources[index] = source
        save()
        changed()
        if source.enabled { sync(sourceID: source.id, force: true) }
    }

    func setEnabled(_ enabled: Bool, sourceID: String) {
        guard let index = customSources.firstIndex(where: { $0.id == sourceID }) else { return }
        customSources[index].enabled = enabled
        if !enabled {
            processes[sourceID]?.terminate()
            timeouts[sourceID]?.cancel()
            timeouts[sourceID] = nil
        }
        save()
        changed()
        if enabled { sync(sourceID: sourceID, force: true) }
    }

    func remove(sourceID: String) {
        guard let index = customSources.firstIndex(where: { $0.id == sourceID }) else { return }
        processes[sourceID]?.terminate()
        processes[sourceID] = nil
        timeouts[sourceID]?.cancel()
        timeouts[sourceID] = nil
        customSources.remove(at: index)
        availability[sourceID] = nil
        failures[sourceID] = nil
        retryAfter[sourceID] = nil
        let cache = snapshotURL(for: sourceID).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: cache.path) {
            try? FileManager.default.trashItem(at: cache, resultingItemURL: nil)
        }
        save()
        changed()
    }

    func clearCache(sourceID: String) {
        guard customSources.contains(where: { $0.id == sourceID }) else { return }
        let process = processes.removeValue(forKey: sourceID)
        process?.terminate()
        timeouts[sourceID]?.cancel()
        timeouts[sourceID] = nil
        let cache = snapshotURL(for: sourceID).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: cache.path) {
            try? FileManager.default.trashItem(at: cache, resultingItemURL: nil)
        }
        availability[sourceID] = .offline(source(id: sourceID)?.lastSuccessfulSync)
        changed()
    }

    func syncEnabledSources() {
        for source in customSources where source.enabled { sync(sourceID: source.id) }
    }

    func sync(sourceID: String, force: Bool = false) {
        guard processes[sourceID] == nil,
              let source = customSources.first(where: { $0.id == sourceID }),
              source.enabled,
              let script = Bundle.main.path(forResource: "source-sync", ofType: nil)
        else { return }
        if !force, let retry = retryAfter[sourceID], retry > Date() { return }

        let destination = snapshotURL(for: source.id)
        try? FileManager.default.createDirectory(at: destination,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: destination.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script, source.rootPath, destination.path, source.layout.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.syncFinished(sourceID: source.id, succeeded: finished.terminationStatus == 0)
            }
        }
        do {
            try process.run()
        } catch {
            availability[source.id] = .offline(source.lastSuccessfulSync)
            changed()
            return
        }
        processes[source.id] = process
        availability[source.id] = .syncing
        changed(reindex: false)

        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, self.processes[source.id] === process else { return }
            process?.terminate()
        }
        timeouts[source.id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
    }

    private func syncFinished(sourceID: String, succeeded: Bool) {
        guard processes[sourceID] != nil else { return }
        timeouts[sourceID]?.cancel()
        timeouts[sourceID] = nil
        processes[sourceID] = nil
        guard let index = customSources.firstIndex(where: { $0.id == sourceID }) else { return }
        if succeeded {
            let now = Date()
            customSources[index].lastSuccessfulSync = now
            availability[sourceID] = .available
            failures[sourceID] = nil
            retryAfter[sourceID] = nil
            save()
        } else {
            availability[sourceID] = .offline(customSources[index].lastSuccessfulSync)
            let count = min(3, (failures[sourceID] ?? 0) + 1)
            failures[sourceID] = count
            let delays: [TimeInterval] = [30, 120, 300]
            retryAfter[sourceID] = Date().addingTimeInterval(delays[count - 1])
        }
        changed()
    }

    private func changed(reindex: Bool = true) {
        NotificationCenter.default.post(
            name: .sessionSourcesChanged, object: self,
            userInfo: ["reindex": reindex])
    }

    private func snapshotURL(for sourceID: String) -> URL {
        Self.snapshotsURL.appending(path: sourceID, directoryHint: .isDirectory)
            .appending(path: "snapshot", directoryHint: .isDirectory)
    }

    private func snapshotExists(for sourceID: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: sourceID).path)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: Self.storeURL),
              let stored = try? decoder.decode(StoredSources.self, from: data),
              stored.version == 1 else { return }
        customSources = stored.sources.filter { source in
            UUID(uuidString: source.id) != nil && source.rootPath.hasPrefix("/")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StoredSources(sources: customSources)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.storeURL.path)
    }
}

@MainActor
final class SessionSourcesWindowController: NSWindowController, NSTableViewDataSource,
                                            NSTableViewDelegate {
    private let store = SessionSourceStore.shared
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private let retryButton = NSButton()
    private let clearButton = NSButton()
    private var sources: [SessionSource] { store.allSources }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Session Sources"
        window.minSize = NSSize(width: 560, height: 280)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .sessionSourcesChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        for (id, title, width) in [("enabled", "", 32.0), ("name", "Source", 170.0),
                                   ("path", "Directory", 290.0), ("status", "Status", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.target = self
        table.action = #selector(selectionChanged)
        scroll.documentView = table

        let add = NSButton(title: "+", target: self, action: #selector(addSource))
        add.bezelStyle = .rounded
        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSource)
        retryButton.title = "Retry"
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retrySource)
        clearButton.title = "Clear Cache…"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearCache)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let controls = NSStackView(
            views: [add, removeButton, retryButton, clearButton, statusLabel])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addSubview(scroll)
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        selectionChanged()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sources.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let source = sources[row]
        if id == "enabled" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSource(_:)))
            button.state = source.enabled ? .on : .off
            button.tag = row
            button.isEnabled = !source.id.hasPrefix("builtin.")
            return button
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = id == "path" ? .byTruncatingMiddle : .byTruncatingTail
        switch id {
        case "name": field.stringValue = source.name
        case "path": field.stringValue = source.rootPath
        case "status": field.stringValue = statusText(for: source)
        default: break
        }
        return field
    }

    private func statusText(for source: SessionSource) -> String {
        switch store.state(for: source.id) {
        case .available: return source.id.hasPrefix("builtin.") ? "Built-in" : "Available"
        case .syncing: return "Syncing…"
        case .stale(let date): return date.map { "Stale · " + Self.relative($0) } ?? "Stale"
        case .offline(let date): return date.map { "Offline · " + Self.relative($0) } ?? "Offline"
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func refresh() {
        table.reloadData()
        selectionChanged()
    }

    @objc private func selectionChanged() {
        let row = table.selectedRow
        let custom = row >= 0 && row < sources.count && !sources[row].id.hasPrefix("builtin.")
        removeButton.isEnabled = custom
        retryButton.isEnabled = custom && sources[row].enabled
        clearButton.isEnabled = custom
        statusLabel.stringValue = row >= 0 && row < sources.count ? statusText(for: sources[row]) : ""
    }

    @objc private func toggleSource(_ sender: NSButton) {
        guard sender.tag < sources.count else { return }
        store.setEnabled(sender.state == .on, sourceID: sources[sender.tag].id)
    }

    @objc private func addSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose an agent session directory or mounted home"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Add Session Source"
        alert.informativeText = "EpiScope reads this directory through a local snapshot. It does not mount or modify the source."
        let name = NSTextField(string: url.lastPathComponent)
        name.placeholderString = "Source name"
        let layout = NSPopUpButton()
        for value in SessionSourceLayout.allCases { layout.addItem(withTitle: value.title) }
        layout.selectItem(at: 0)
        let stack = NSStackView(views: [name, layout])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = SessionSourceLayout.allCases[max(0, layout.indexOfSelectedItem)]
        let sourceName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        store.add(name: sourceName.isEmpty ? url.lastPathComponent : sourceName,
                  rootPath: url.path, layout: chosen)
    }

    @objc private func removeSource() {
        let row = table.selectedRow
        guard row >= 0, row < sources.count,
              !sources[row].id.hasPrefix("builtin.") else { return }
        let source = sources[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(source.name)”?"
        alert.informativeText = "Its local snapshot will be moved to the Trash. The mounted directory is never modified."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(sourceID: source.id)
    }

    @objc private func retrySource() {
        let row = table.selectedRow
        guard row >= 0, row < sources.count else { return }
        store.sync(sourceID: sources[row].id, force: true)
    }

    @objc private func clearCache() {
        let row = table.selectedRow
        guard row >= 0, row < sources.count,
              !sources[row].id.hasPrefix("builtin.") else { return }
        let source = sources[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear cached sessions for “\(source.name)”?"
        alert.informativeText = "Only EpiScope’s local snapshot is moved to the Trash. The source directory is never modified."
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearCache(sourceID: source.id)
    }
}
