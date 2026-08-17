import AppKit

extension Notification.Name {
    // Posted (main thread) by SearchIndex via AppDelegate as the FTS index
    // folds files: userInfo ["done": Int, "total": Int]. total == 0 means idle.
    static let searchIndexProgress = Notification.Name("episcope.searchIndexProgress")
}

// Full-text search across every indexed session: a search field on top, and
// below it a non-tabular feed of result cards (one per matching session, with
// highlighted text excerpts). Embedded in the main window as its "search" mode
// (see MainWindowController.enterSearchMode) — clicking a card opens that
// session's Messages screen at the match.
final class SearchViewController: NSViewController {
    private let indexer: SessionIndexer
    private let searchIndex: SearchIndex
    // Set by MainWindowController: open the session's Messages screen and scroll
    // to the matched message (when a result card is clicked).
    var onOpenResult: ((_ sessionId: String, _ query: String, _ locator: String) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let feedStack = NSStackView()

    private var pending: DispatchWorkItem?
    private var currentQuery = ""
    private var indexingText: String?
    private var lastResultCount = 0
    private weak var selectedCard: SearchResultCardView?

    init(indexer: SessionIndexer, searchIndex: SearchIndex) {
        self.indexer = indexer
        self.searchIndex = searchIndex
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(statusLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        container.addSubview(scrollView)

        let doc = SearchDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        feedStack.translatesAutoresizingMaskIntoConstraints = false
        feedStack.orientation = .vertical
        feedStack.alignment = .leading
        feedStack.distribution = .fill
        feedStack.spacing = 0
        doc.addSubview(feedStack)
        scrollView.documentView = doc

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            feedStack.topAnchor.constraint(equalTo: doc.topAnchor),
            feedStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            feedStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            feedStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        view = container

        NotificationCenter.default.addObserver(
            self, selector: #selector(indexProgress(_:)),
            name: .searchIndexProgress, object: nil)
        showMessage("Type to search your prompts and replies across all sessions.")
        updateStatus()
    }

    // MARK: - Search (driven by the toolbar search field in MainWindowController)

    // Debounced query entry point. The text comes from the toolbar's search
    // field; the feed renders the matching session cards.
    func runQuery(_ text: String) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performSearch(text) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func performSearch(_ q: String) {
        currentQuery = q
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastResultCount = 0
            showMessage("Type to search your prompts and replies across all sessions.")
            updateStatus()
            return
        }
        searchIndex.search(q) { [weak self] hits in
            // Ignore stale callbacks if the query moved on.
            guard let self, q == self.currentQuery else { return }
            self.render(hits)
        }
    }

    private func render(_ hits: [MessageHit]) {
        clearFeed()
        selectedCard = nil
        lastResultCount = hits.count
        guard !hits.isEmpty else {
            showMessage("No matches.")
            updateStatus()
            return
        }
        let byId = Dictionary(indexer.userFacingEntries.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        for hit in hits {
            let card = SearchResultCardView(hit: hit, entry: byId[hit.sessionId])
            let sid = hit.sessionId
            let loc = hit.locator
            card.onOpen = { [weak self, weak card] in
                guard let self else { return }
                self.selectedCard?.selected = false
                card?.selected = true
                self.selectedCard = card
                self.onOpenResult?(sid, self.currentQuery, loc)
            }
            feedStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
        }
        updateStatus()
    }

    private func clearFeed() {
        for v in feedStack.arrangedSubviews {
            feedStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func showMessage(_ text: String) {
        clearFeed()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 40),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -40),
        ])
        feedStack.addArrangedSubview(holder)
        holder.widthAnchor.constraint(equalTo: feedStack.widthAnchor).isActive = true
    }

    private func updateStatus() {
        var parts: [String] = []
        if let indexingText { parts.append(indexingText) }
        if !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lastResultCount > 0 {
            parts.append(lastResultCount == 1 ? "1 message" : "\(lastResultCount) messages")
        }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    @objc private func indexProgress(_ note: Notification) {
        let total = note.userInfo?["total"] as? Int ?? 0
        let done = note.userInfo?["done"] as? Int ?? 0
        if total > 0 {
            indexingText = "Indexing \(done)/\(total)…"
        } else {
            let wasIndexing = indexingText != nil
            indexingText = nil
            // Freshly indexed content just landed — re-run the live query.
            if wasIndexing, !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch(currentQuery)
            }
        }
        updateStatus()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

// Flipped so the feed grows top-down inside the scroll view.
private final class SearchDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// One matching message — the whole card is a single click target that opens
// that session's Messages at the match. Session name / project / time are shown
// as context above the highlighted excerpt.
final class SearchResultCardView: NSView {
    var onOpen: (() -> Void)?

    private var hovered = false { didSet { updateBackground() } }
    // Set when this message was opened — stays lit after returning from the
    // Messages screen, so you can see where you came from.
    var selected = false { didSet { updateBackground() } }

    // Selected wins over hover; neither → transparent. (No needsLayout here —
    // a layout pass rebuilds the tracking area under the cursor and fires
    // spurious enter/exit, which made the highlight flicker.)
    private func updateBackground() {
        let color: NSColor? = selected ? Self.selectedBG : (hovered ? Self.hoverBG : nil)
        layer?.backgroundColor = color?.cgColor
    }

    private static let hoverBG = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10)
    private static let selectedBG = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22)
    private static let highlightBG = NSColor.controlAccentColor.withAlphaComponent(0.30)

    override var isFlipped: Bool { true }

    init(hit: MessageHit, entry: SessionIndexEntry?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build(hit: hit, entry: entry)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build(hit: MessageHit, entry: SessionIndexEntry?) {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.providerColor(hit.provider).cgColor
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)

        // Session context (secondary) — the message excerpt below is the focus.
        let sessionName = entry?.name ?? entry?.displayTitle ?? String(hit.sessionId.prefix(8))
        let folder = entry?.relativePath
        let contextText = folder.map { "\(sessionName)   ·   \($0)" } ?? sessionName
        let context = Self.label(contextText, font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor)
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(context)

        let when = (hit.timestamp ?? entry?.lastActivity).map { Self.relativeTime($0) } ?? ""
        let time = Self.label(when, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(time)

        let body = Self.label("", font: .systemFont(ofSize: 13), color: .labelColor)
        body.attributedStringValue = Self.attributedSnippet(role: hit.role, marked: hit.marked,
                                                            provider: hit.provider)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(body)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: context.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            context.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            context.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            context.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),

            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            time.centerYAnchor.constraint(equalTo: context.centerYAnchor),

            body.leadingAnchor.constraint(equalTo: context.leadingAnchor),
            body.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 3),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) { onOpen?() }

    // The whole card is one click target — route hits that land on child
    // labels (non-selectable NSTextFields still swallow clicks) to self.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // MARK: - Helpers

    private static func label(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    // Dim role tag + the excerpt, with FTS5's sentinel-wrapped terms turned
    // into an accent-tinted bold highlight.
    static func attributedSnippet(role: String, marked: String,
                                  provider: SessionProvider) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let tag = role == "user" ? "you" : providerShort(provider)
        out.append(NSAttributedString(string: tag + "   ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))

        let body = NSFont.systemFont(ofSize: 13)
        let bodyBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let startCh = Character(SearchIndex.hlStart)
        let endCh = Character(SearchIndex.hlEnd)

        var run = ""
        var isHL = false
        func flush() {
            guard !run.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
            if isHL {
                attrs[.font] = bodyBold
                attrs[.backgroundColor] = highlightBG
            }
            out.append(NSAttributedString(string: run, attributes: attrs))
            run = ""
        }
        for ch in marked.replacingOccurrences(of: "\n", with: " ") {
            if ch == startCh { flush(); isHL = true }
            else if ch == endCh { flush(); isHL = false }
            else { run.append(ch) }
        }
        flush()
        return out
    }

    static func providerColor(_ p: SessionProvider) -> NSColor {
        switch p {
        case .claude:        return .systemOrange
        case .codex:         return .systemGreen
        case .claudeDesktop: return .systemPurple
        }
    }
    static func providerName(_ p: SessionProvider) -> String {
        switch p {
        case .claude:        return "Claude"
        case .codex:         return "Codex"
        case .claudeDesktop: return "Claude Desktop"
        }
    }
    static func providerShort(_ p: SessionProvider) -> String {
        switch p {
        case .claude:        return "claude"
        case .codex:         return "codex"
        case .claudeDesktop: return "desktop"
        }
    }

    static func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let days = h / 24
        if days < 30 { return "\(days)d ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }
}
