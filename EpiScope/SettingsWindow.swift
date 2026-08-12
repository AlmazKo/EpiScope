import AppKit
import UserNotifications

// The Settings window, shaped like System Settings: a source-list sidebar picks
// the section, and the section is a column of islands — rounded cards holding
// one row per control, with the explanation under the card rather than beside
// the control.
//
// Sections are added by extending `Section`, so a pane cannot be built without
// also being listed and vice versa.
@MainActor
final class SettingsWindowController: NSWindowController {
    enum Section: String, CaseIterable {
        case alerts
        case sources
        case insights

        var label: String {
            switch self {
            case .alerts: return "Alerts"
            case .sources: return "Sources"
            case .insights: return "Insights"
            }
        }

        var symbol: String {
            switch self {
            case .alerts: return "bell.badge"
            case .sources: return "externaldrive.connected.to.line.below"
            case .insights: return "sparkles"
            }
        }

        // The tinted rounded square the sidebar draws behind the symbol — the
        // one place a settings row carries colour, exactly as the system's does.
        var tint: NSColor {
            switch self {
            case .alerts: return .systemRed
            case .sources: return .systemBlue
            case .insights: return .systemPurple
            }
        }

        @MainActor
        func makeViewController() -> NSViewController {
            switch self {
            case .alerts: return AlertsSettingsViewController()
            case .sources: return SourcesSettingsViewController()
            case .insights: return InsightsSettingsViewController()
            }
        }
    }

    static let width: CGFloat = 780
    private let split = SettingsSplitViewController()

    init() {
        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        // The section name is the big heading inside the pane, the way the
        // system's own settings title a section; repeating it in the title bar
        // would say it twice.
        window.titleVisibility = .hidden
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        // Fixed width, free height — the shape of every settings window on the
        // system, and the thing that keeps a long caption from deciding how
        // wide the window is.
        window.setContentSize(NSSize(width: Self.width, height: 560))
        window.minSize = NSSize(width: Self.width, height: 420)
        window.maxSize = NSSize(width: Self.width, height: 2000)
        super.init(window: window)
        windowFrameAutosaveName = "EpiScopeSettings"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ section: Section? = nil) {
        if let section { split.select(section) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Frame

@MainActor
private final class SettingsSplitViewController: NSSplitViewController {
    private let sidebar = SettingsSidebarViewController()
    private let detail = SettingsDetailViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebar.onSelect = { [weak self] section in self?.detail.show(section) }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        // A two-section window has nothing to gain from a collapsed sidebar and
        // everything to lose: the picker would be gone with no way back.
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
        sidebar.select(.alerts)
    }

    func select(_ section: SettingsWindowController.Section) {
        sidebar.select(section)
    }
}

@MainActor
private final class SettingsSidebarViewController: NSViewController,
                                                   NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SettingsWindowController.Section) -> Void)?
    private let table = NSTableView()
    private let sections = SettingsWindowController.Section.allCases

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        table.style = .sourceList
        table.rowSizeStyle = .medium
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section")))
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        view = scroll
    }

    func select(_ section: SettingsWindowController.Section) {
        guard let index = sections.firstIndex(of: section) else { return }
        // loadView may not have run yet when the caller picks a section.
        _ = view
        // And the table may not have asked for its rows yet. Selecting a row it
        // does not know about sticks — the row draws selected once the data
        // arrives — but sends no selection change, which is how the window came
        // up with a highlighted section and an empty pane.
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        // Told directly rather than through the delegate, so this path does not
        // depend on whether the selection counted as a change.
        onSelect?(section)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let section = sections[row]
        let cell = NSTableCellView()
        let icon = SettingsUI.tintedIcon(symbol: section.symbol, tint: section.tint,
                                         accessibility: section.label)
        let title = NSTextField(labelWithString: section.label)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [icon, title])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < sections.count else { return }
        onSelect?(sections[row])
    }
}

// Hosts one pane at a time under the section's heading, and scrolls it.
@MainActor
private final class SettingsDetailViewController: NSViewController {
    private let heading = NSTextField(labelWithString: "")
    private let container = NSView()
    private var current: NSViewController?
    private var shown: SettingsWindowController.Section?
    private var panes: [SettingsWindowController.Section: NSViewController] = [:]

    override func loadView() {
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let content = SettingsBackgroundView()
        content.wantsLayer = true
        content.addSubview(heading)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            // Clears the transparent title bar the traffic lights sit in.
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                              constant: -24),
            container.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        view = content
    }

    // Panes are built once and kept: they hold live state (an edited prompt, a
    // table selection) that must survive a trip through another section.
    func show(_ section: SettingsWindowController.Section) {
        _ = view
        guard shown != section else { return }
        shown = section
        heading.stringValue = section.label
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        let pane = panes[section] ?? section.makeViewController()
        panes[section] = pane
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: container.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        current = pane
    }
}

// MARK: - Pane furniture

// A settings pane: a scrolling column of islands, every one pinned to the same
// two margins. Laid out by hand rather than by a stack view — NSStackView's
// edgeInsets apply to the stack, not to what it arranges, so the islands, the
// captions and the heading each ended up on a margin of their own.
@MainActor
class SettingsPaneViewController: NSViewController {
    static let margin: CGFloat = 24
    private let document = FlippedView()
    private var lastAdded: NSView?
    private var bottomPin: NSLayoutConstraint?

    override func loadView() {
        document.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Width from the scroll view, height from the content: the column
            // scrolls vertically and never sideways.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        view = content
        build()
    }

    // Subclass hook — called once, after the document exists.
    func build() {}

    func add(_ item: NSView, gap: CGFloat = 18) {
        item.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(item)
        NSLayoutConstraint.activate([
            item.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.margin),
            item.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                           constant: -Self.margin),
            item.topAnchor.constraint(equalTo: lastAdded?.bottomAnchor ?? document.topAnchor,
                                      constant: lastAdded == nil ? 0 : gap),
        ])
        bottomPin?.isActive = false
        let pin = document.bottomAnchor.constraint(equalTo: item.bottomAnchor, constant: 24)
        pin.isActive = true
        bottomPin = pin
        lastAdded = item
    }

    // A caption belongs to the island above it, so it sits closer to that island
    // than the next one does.
    func addCaption(_ text: String) {
        add(SettingsUI.caption(text), gap: 8)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// The frame around an editable text area. It is a view of its own rather than a
// border on the scroll view: a scroll view's clip view covers whatever the
// scroll view itself draws, so the outline was never visible.
//
// The fill is deliberately not the card's — a white text area on a white card
// reads as printed text, and the only sign it can be typed into would be the
// cursor. Focus moves the outline to the accent colour, the way a focused field
// does everywhere else on the system.
final class FieldWellView: NSView {
    var isFocused = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = isFocused ? 2 : 1
        layer?.borderColor = (isFocused ? NSColor.controlAccentColor
                                        : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

// The surface the islands sit on. Without it the cards are white on white in
// light mode and the grouping disappears.
final class SettingsBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

// A rounded card. `updateLayer` rather than a stored cgColor: the fill has to
// follow a switch to dark mode, and a colour captured once does not.
final class IslandView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

@MainActor
enum SettingsUI {
    // One island: rows stacked with a hairline between them, the way a group of
    // settings reads in System Settings.
    static func island(_ rows: [NSView]) -> IslandView {
        let island = IslandView()
        island.wantsLayer = true
        island.translatesAutoresizingMaskIntoConstraints = false
        var previous: NSView?
        for (index, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            island.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: island.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: island.trailingAnchor),
                row.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? island.topAnchor),
            ])
            if index < rows.count - 1 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                island.addSubview(line)
                NSLayoutConstraint.activate([
                    line.topAnchor.constraint(equalTo: row.bottomAnchor),
                    // Inset like the system's, so the divider reads as inside
                    // the card rather than as its edge.
                    line.leadingAnchor.constraint(equalTo: island.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: island.trailingAnchor),
                    line.heightAnchor.constraint(equalToConstant: 1),
                ])
                previous = line
            } else {
                previous = row
            }
        }
        if let last = previous {
            last.bottomAnchor.constraint(equalTo: island.bottomAnchor).isActive = true
        }
        return island
    }

    // A row: title on the left, control on the right.
    static func row(_ title: String, _ control: NSView, height: CGFloat = 40) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                             constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    // A row whose content spans the card — a table, an editor, a button bar.
    static func wideRow(_ content: NSView, height: CGFloat? = nil,
                        insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 16,
                                                            bottom: 12, right: 16)) -> NSView {
        let row = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -insets.bottom),
        ])
        if let height {
            content.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        return row
    }

    // The grey line under an island that explains it.
    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        // A wrapping label asks for the width its text would take on one line.
        // Left to argue, it wins — through the scroll view's document, up into
        // the window's fitting size — and the window opens metres wide.
        field.preferredMaxLayoutWidth = SettingsWindowController.width - 300
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // The label over an island, naming the group.
    static func groupTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    // Wraps a scroll view in the outlined, tinted well that says "you can type
    // here". NSScrollView's own border types are the old bezel and read as a
    // foreign object on a card.
    static func fieldWell(around scroll: NSScrollView) -> FieldWellView {
        let well = FieldWellView()
        well.wantsLayer = true
        well.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: well.topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2),
        ])
        return well
    }

    static func tintedIcon(symbol: String, tint: NSColor, accessibility: String,
                           side: CGFloat = 20) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = tint.cgColor
        box.layer?.cornerRadius = 5
        box.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        image.contentTintColor = .white
        image.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(image)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: side),
            box.heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }
}

// MARK: - Alerts

// How a session that needs the operator announces itself: the banner, which the
// OS owns, and the chime, which we own.
@MainActor
final class AlertsSettingsViewController: SettingsPaneViewController {
    private let bannerStatus = NSTextField(labelWithString: "")
    private let bannerButton = NSButton()
    private let soundPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    override func build() {
        bannerButton.bezelStyle = .rounded
        bannerButton.target = self
        bannerButton.action = #selector(handleBanner)
        bannerStatus.textColor = .secondaryLabelColor

        for name in Chime.choices {
            soundPopUp.addItem(withTitle: name)
            if name == Chime.none { soundPopUp.menu?.addItem(.separator()) }
        }
        soundPopUp.selectItem(withTitle: Chime.name)
        soundPopUp.target = self
        soundPopUp.action = #selector(selectSound)

        let banner = NSStackView(views: [bannerStatus, bannerButton])
        banner.orientation = .horizontal
        banner.spacing = 10

        add(SettingsUI.island([
            SettingsUI.row("Notifications", banner),
            SettingsUI.row("Alert sound", soundPopUp),
        ]))
        addCaption("A banner arrives when a session asks for permission, finishes a turn "
                   + "or fails one; the sound plays when it starts waiting on you. Whether "
                   + "banners are allowed at all is the system's switch, not ours — picking "
                   + "a sound plays it, so it can be chosen by ear.")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        soundPopUp.selectItem(withTitle: Chime.name)
        refreshBannerState()
    }

    // The grant belongs to the OS and can change behind us — in System Settings,
    // or by moving the app — so it is read every time the pane appears rather
    // than mirrored into a pref of our own.
    private func refreshBannerState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional:
                    self.bannerStatus.stringValue = "Allowed"
                    self.bannerButton.title = "Open System Settings…"
                case .notDetermined:
                    self.bannerStatus.stringValue = "Not asked yet"
                    self.bannerButton.title = "Allow Notifications…"
                default:
                    self.bannerStatus.stringValue = "Turned off in System Settings"
                    self.bannerButton.title = "Open System Settings…"
                }
            }
        }
    }

    // The tracker asks for authorization once at launch. If that prompt was
    // dismissed, or the grant was lost (the app running from the DMG instead of
    // /Applications does it), this is the way back: ask again while the system
    // still allows asking, otherwise hand over to System Settings, which owns
    // the switch from then on.
    @objc private func handleBanner() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                        DispatchQueue.main.async { self?.refreshBannerState() }
                    }
                    return
                }
                let bid = Bundle.main.bundleIdentifier ?? ""
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.notifications?id=\(bid)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func selectSound() {
        let name = soundPopUp.titleOfSelectedItem ?? Chime.defaultName
        Chime.name = name
        // Preview, so the choice can be made by ear rather than by memory.
        Chime.play(name)
    }
}

// MARK: - Insights

// Insights is one subject — whether the runs happen, on what model, and the
// prompt they run on — so it is one section, two islands.
@MainActor
final class InsightsSettingsViewController: SettingsPaneViewController, NSTextViewDelegate {
    private let autoRun = NSSwitch()
    private let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSTextView()
    private var editorWell: FieldWellView?
    private let placeholders = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let restore = NSButton()
    private var saveWork: DispatchWorkItem?

    private var template: PromptLibrary.Template {
        PromptLibrary.templates[max(0, min(picker.indexOfSelectedItem,
                                           PromptLibrary.templates.count - 1))]
    }

    override func build() {
        // Two controls for the runs, by product decision: whether they happen
        // at all, and which model they run on. Anything else about a report is
        // decided by the report.
        autoRun.target = self
        autoRun.action = #selector(toggleAutoRun)
        autoRun.state = Self.autoRunEnabled ? .on : .off
        modelPopUp.target = self
        modelPopUp.action = #selector(selectModel)
        rebuildModelMenu()

        add(SettingsUI.island([
            SettingsUI.row("Automatic reports", autoRun),
            SettingsUI.row("Analysis model", modelPopUp),
        ]))
        addCaption("One consolidated report a day, plus a weekly one, with a notification "
                   + "when it is ready. A run shells out to the local CLI of the engine the "
                   + "model belongs to; nothing is sent anywhere by EpiScope.")

        for t in PromptLibrary.templates { picker.addItem(withTitle: t.title) }
        picker.target = self
        picker.action = #selector(pickTemplate)

        placeholders.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                  weight: .regular)
        placeholders.textColor = .secondaryLabelColor
        placeholders.lineBreakMode = .byTruncatingTail
        placeholders.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A bare NSTextView dropped into a scroll view sizes itself to its text
        // and paints only that far, which is why the editor came up grey with a
        // white patch. It has to be told it grows downwards, tracks the scroll
        // view's width, and draws its own text background.
        let editorScroll = NSScrollView()
        let well = SettingsUI.fieldWell(around: editorScroll)
        editorWell = well
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0,
                                                     height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.isRichText = false
        // A prompt is source, not prose: smart quotes and dashes would rewrite
        // {{PLACEHOLDERS}} and code fences into something the run cannot use.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.allowsUndo = true
        editor.delegate = self
        editorScroll.documentView = editor

        restore.title = "Restore Default"
        restore.bezelStyle = .rounded
        restore.target = self
        restore.action = #selector(restoreDefault)
        let footer = NSStackView(views: [status, NSView(), restore])
        footer.orientation = .horizontal
        footer.spacing = 10
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The editor, what it takes and what state it is in are one row: a
        // hairline between each of them would chop the card into stripes.
        let editing = NSStackView(views: [well, placeholders, footer])
        editing.orientation = .vertical
        editing.alignment = .leading
        editing.spacing = 8
        well.heightAnchor.constraint(equalToConstant: 260).isActive = true
        for row in [well, placeholders, footer] as [NSView] {
            row.widthAnchor.constraint(equalTo: editing.widthAnchor).isActive = true
        }

        add(SettingsUI.groupTitle("Prompts"), gap: 22)
        add(SettingsUI.island([
            SettingsUI.row("Template", picker),
            SettingsUI.wideRow(editing,
                               insets: NSEdgeInsets(top: 0, left: 16, bottom: 12, right: 16)),
        ]))
        loadTemplate()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The prefs can change from elsewhere (a default written by hand), and a
        // settings pane that shows a stale value is worse than no pane.
        autoRun.state = Self.autoRunEnabled ? .on : .off
        rebuildModelMenu()
        refreshStatus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Leaving the section is as much an end of editing as a pause in typing.
        flushSave()
    }

    // MARK: Runs

    private static var autoRunEnabled: Bool {
        UserDefaults.standard.object(
            forKey: AppDelegate.dailyInsightsEnabledKey) as? Bool ?? true
    }

    @objc private func toggleAutoRun() {
        UserDefaults.standard.set(autoRun.state == .on,
                                  forKey: AppDelegate.dailyInsightsEnabledKey)
    }

    @objc private func selectModel(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "analysisModel")
    }

    // Grouped by engine and labelled with it: which CLI a run shells out to
    // decides whose plan pays for it and which login has to be there, so it is
    // not an implementation detail the popup can hide. Derived from allCases,
    // so adding an engine cannot leave its models unlisted.
    private func rebuildModelMenu() {
        let menu = NSMenu()
        let current = ReportsWindowController.defaultModel
        for engine in AnalysisEngine.allCases {
            let models = AnalysisModelChoice.all.filter { $0.engine == engine }
            guard !models.isEmpty else { continue }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: engine.menuHeading, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for choice in models {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.representedObject = choice.id
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }
        modelPopUp.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == current }) {
            modelPopUp.select(item)
        }
    }

    // MARK: Prompts

    private func loadTemplate() {
        let t = template
        editor.string = PromptLibrary.custom(t.name) ?? PromptLibrary.bundled(t.name) ?? ""
        let keys = PromptLibrary.placeholders(t.name)
        placeholders.stringValue = keys.isEmpty
            ? t.blurb
            : t.blurb + "  Placeholders: " + keys.map { "{{\($0)}}" }.joined(separator: " ")
        refreshStatus()
    }

    private func refreshStatus() {
        let customised = PromptLibrary.isCustomised(template.name)
        restore.isEnabled = customised
        status.stringValue = customised
            ? "Edited — the bundled default is no longer followed."
            : "Bundled default. Editing keeps your copy from now on."
    }

    @objc private func pickTemplate() {
        flushSave()
        loadTemplate()
    }

    func textDidBeginEditing(_ notification: Notification) {
        editorWell?.isFocused = true
    }

    func textDidEndEditing(_ notification: Notification) {
        editorWell?.isFocused = false
    }

    // Typing saves, on a short delay: a settings pane applies as you go, and a
    // write per keystroke would churn a file the analysis queue reads.
    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let name = template.name
        let text = editor.string
        let work = DispatchWorkItem { [weak self] in
            PromptLibrary.save(text, for: name)
            self?.saveWork = nil
            self?.refreshStatus()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSave() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        PromptLibrary.save(editor.string, for: template.name)
        refreshStatus()
    }

    @objc private func restoreDefault() {
        let t = template
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the default “\(t.title)” prompt?"
        alert.informativeText = "Your edited copy moves to the Trash, and the prompt "
            + "follows the bundled one again — including its changes in later releases."
        alert.addButton(withTitle: "Restore Default")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.saveWork?.cancel()
            self.saveWork = nil
            PromptLibrary.restoreDefault(t.name)
            self.loadTemplate()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }
}

// MARK: - Sources

@MainActor
final class SourcesSettingsViewController: SettingsPaneViewController, NSTableViewDataSource,
                                           NSTableViewDelegate {
    private let store = SessionSourceStore.shared
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private let retryButton = NSButton()
    private let clearButton = NSButton()
    private var sources: [SessionSource] { store.allSources }

    override func build() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.style = .inset
        table.backgroundColor = .clear
        for (id, title, width) in [("enabled", "", 28.0), ("name", "Source", 130.0),
                                   ("path", "Directory", 230.0), ("status", "Status", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.target = self
        table.action = #selector(selectionChanged)
        scroll.documentView = table

        let addButton = NSButton(title: "+", target: self, action: #selector(addSource))
        addButton.bezelStyle = .rounded
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
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [addButton, removeButton, retryButton, clearButton,
                                           statusLabel])
        controls.orientation = .horizontal
        controls.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        add(SettingsUI.island([
            SettingsUI.wideRow(scroll, height: 280,
                               insets: NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)),
            SettingsUI.wideRow(controls,
                               insets: NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)),
        ]))
        addCaption("EpiScope reads an added directory through a local snapshot, and never "
                   + "mounts, writes to or deletes from it. The three built-in roots cannot "
                   + "be removed.")

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .sessionSourcesChanged, object: nil)
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
