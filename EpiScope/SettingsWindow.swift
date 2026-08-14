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
        // A unified toolbar is what merges the title bar into the content: the
        // sidebar then runs the full height of the window and the traffic
        // lights sit on it, instead of on a strip above it. Empty on purpose —
        // it exists for the title and the window buttons, not for items.
        let toolbar = NSToolbar(identifier: "episcope.settings")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The section names itself in the title bar, where System Settings puts
        // it. A heading inside the pane would say it a second time, and push
        // the first card down past where the eye looks for it.
        window.titleVisibility = .visible
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
        // The sidebar now runs under the title bar, so the first row has to
        // clear the window buttons rather than start at the top edge.
        scroll.automaticallyAdjustsContentInsets = true
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

// Hosts one pane at a time and scrolls it. The section is named by the window
// title, not by a heading here.
@MainActor
private final class SettingsDetailViewController: NSViewController {
    private let container = NSView()
    private var current: NSViewController?
    private var shown: SettingsWindowController.Section?
    private var panes: [SettingsWindowController.Section: NSViewController] = [:]

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        let content = SettingsBackgroundView()
        content.wantsLayer = true
        content.addSubview(container)
        NSLayoutConstraint.activate([
            // The pane starts below the unified title bar; the toolbar reserves
            // the height, this is the breathing room under it.
            container.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor,
                                           constant: 16),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        view = content
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The window may not exist yet when the first section is picked.
        if let shown { view.window?.title = shown.label }
    }

    // Panes are built once and kept: they hold live state (an edited prompt, a
    // table selection) that must survive a trip through another section.
    func show(_ section: SettingsWindowController.Section) {
        _ = view
        guard shown != section else { return }
        shown = section
        view.window?.title = section.label
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

// The two surfaces of a settings pane. Note which way round they go: System
// Settings puts its groups on a *white* sheet as light grey cards — not white
// cards on a grey sheet, which is the iOS grouped-list arrangement and reads as
// a different platform. Spelled out rather than taken from
// windowBackgroundColor / controlBackgroundColor, which both resolve to the
// same white here and left the cards invisible.
extension NSColor {
    static let settingsSheet = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 1)
            : NSColor(white: 1.0, alpha: 1)
    }

    static let settingsCard = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.17, alpha: 1)
            : NSColor(white: 0.949, alpha: 1)
    }
}

// The surface the islands sit on.
final class SettingsBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.settingsSheet.cgColor
    }
}

// One-pixel divider in the system's own separator colour.
final class HairlineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// A rounded card. `updateLayer` rather than a stored cgColor: the fill has to
// follow a switch to dark mode, and a colour captured once does not. The
// hairline is what keeps the card readable if the two surfaces ever resolve to
// the same value again.
final class IslandView: NSView {
    override var wantsUpdateLayer: Bool { true }
    // No border: the system's cards are a fill and nothing else. An outline
    // turns the group into a framed box, which is the look this replaced.
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.settingsCard.cgColor
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
                // A hairline of separatorColor, not NSBox(.separator): the box
                // draws a heavier line of its own, which on a card reads as a
                // rule between sections rather than as a divider between rows.
                let line = HairlineView()
                line.wantsLayer = true
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

    // A row that explains its own value: title and control on the first line,
    // the description of what is currently selected under the title. The
    // description may run under the control — the control only occupies the
    // first line, as it does in the system's own panes.
    static func row(_ title: String, _ control: NSView, description: NSTextField) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        for view in [label, control, description] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),

            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                             constant: 12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: label.centerYAnchor),

            description.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            description.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            description.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            description.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
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

    // A group heading that says what the group is for, the way `Energy Mode`
    // introduces its card. The sentence goes above the island, not under it:
    // it explains what follows rather than qualifying what came before.
    static func groupHeader(_ title: String, _ description: String) -> NSView {
        let heading = groupTitle(title)
        let text = caption(description)
        let stack = NSStackView(views: [heading, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [heading, text] as [NSView] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
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
    private let blurb = NSTextField(wrappingLabelWithString: "")
    private let placeholders = NSTextField(wrappingLabelWithString: "")
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

        // Let into the card edge to edge, the way Xcode's settings inset an
        // editor: the text area is a band of the card between two hairlines,
        // not a framed field floating inside it.
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        // With a unified title bar in the window, AppKit hands scroll views an
        // automatic top inset meant to clear it. This one is deep inside a
        // card; left on, it pushed the first line up under the row above.
        editorScroll.automaticallyAdjustsContentInsets = false
        editorScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        // A bare NSTextView dropped into a scroll view sizes itself to its text
        // and paints only that far, which is why the editor came up grey with a
        // white patch. It has to be told it grows downwards, tracks the scroll
        // view's width, and draws its own text background.
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0,
                                                     height: CGFloat.greatestFiniteMagnitude)
        // The band is the card's own surface, so the text needs the padding a
        // framed field would have given it — on every side, not just the sides.
        editor.textContainerInset = NSSize(width: 16, height: 16)
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

        // What the prompt takes and what state it is in belong together under
        // the editor; a hairline between those two would chop the card up.
        let notes = NSStackView(views: [placeholders, footer])
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = 8
        for row in [placeholders, footer] as [NSView] {
            row.widthAnchor.constraint(equalTo: notes.widthAnchor).isActive = true
        }

        // What a template drives belongs with the control that picks it — read
        // under the editor it looked like a caption for the text above it.
        blurb.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = SettingsWindowController.width - 320
        blurb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        add(SettingsUI.groupHeader(
            "Prompts",
            "Every analysis is built from one of these templates. Edit one and your copy "
            + "runs from then on; Restore Default hands the prompt back to the bundled "
            + "version, including whatever later releases change in it."), gap: 22)
        add(SettingsUI.island([
            SettingsUI.row("Template", picker, description: blurb),
            SettingsUI.wideRow(editorScroll, height: 260,
                               insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
            SettingsUI.wideRow(notes,
                               insets: NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)),
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
        // A template opens at its first line. Setting the string leaves the
        // scroll where the previous one was read to, which looks like the top
        // of the text has been cut off.
        editor.scroll(NSPoint(x: 0, y: 0))
        let keys = PromptLibrary.placeholders(t.name)
        blurb.stringValue = t.blurb
        placeholders.stringValue = keys.isEmpty
            ? ""
            : "Placeholders: " + keys.map { "{{\($0)}}" }.joined(separator: "  ")
        refreshStatus()
    }

    private func refreshStatus() {
        let customised = PromptLibrary.isCustomised(template.name)
        restore.isEnabled = customised
        status.stringValue = customised
            // The group heading already explains what editing does; this line
            // only reports which of the two states the template is in.
            ? "Edited"
            : "Bundled default"
    }

    @objc private func pickTemplate() {
        flushSave()
        loadTemplate()
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

// A list row that draws its own separator, inset to the text column. The
// table's grid line runs the full width, which reads as a table rather than as
// a settings list.
final class SourceRowView: NSTableRowView {
    var drawsSeparator = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsSeparator else { return }
        // separatorColor as it comes — black at 0.098 alpha. The system's
        // dividers are barely there, and anything stronger reads as a grid.
        NSColor.separatorColor.setFill()
        NSRect(x: 46, y: bounds.maxY - 1, width: bounds.width - 46, height: 1).fill()
    }
}

@MainActor
final class SourcesSettingsViewController: SettingsPaneViewController, NSTableViewDataSource,
                                           NSTableViewDelegate, NSMenuDelegate {
    private let store = SessionSourceStore.shared
    private let table = NSTableView()
    private let removeButton = NSButton()
    private var sources: [SessionSource] { store.allSources }

    override func build() {
        // A list inside the card, the way Login Items is one: no column headers,
        // no frame of its own, one row per source with its state on the right.
        // The table shape was a leftover from when this lived in its own window.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.style = .plain
        table.backgroundColor = .clear
        // Two lines and a full-size switch need the height a system list row
        // has; the separators are drawn per row, inset, not by the grid.
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.action = #selector(selectionChanged)
        scroll.documentView = table

        // Borderless symbol buttons in a thin strip under the list, split by a
        // hairline — the add/remove pair every system list of this shape uses.
        // Retry and Clear Cache are per-source verbs and live in the row's
        // context menu, where a list keeps the actions that need a target.
        let addButton = Self.stripButton(symbol: "plus", label: "Add source",
                                         target: self, action: #selector(addSource))
        removeButton.image = NSImage(systemSymbolName: "minus",
                                     accessibilityDescription: "Remove source")
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeSource)
        let divider = HairlineView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let controls = NSStackView(views: [addButton, divider, removeButton, NSView()])
        controls.orientation = .horizontal
        controls.spacing = 6

        table.menu = rowMenu()

        add(SettingsUI.island([
            SettingsUI.wideRow(SettingsUI.caption(
                "EpiScope reads an added directory through a local snapshot, and never "
                + "mounts, writes to or deletes from it. The three built-in roots cannot "
                + "be removed."),
                               insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)),
            SettingsUI.wideRow(scroll, height: 220,
                               insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
            SettingsUI.wideRow(controls,
                               insets: NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)),
        ]))

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: .sessionSourcesChanged, object: nil)
        selectionChanged()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    // One row, in the order the system's lists use: icon, name over its
    // directory, then the state, then the switch on the trailing edge. Built
    // fresh per row rather than reused — four sources are not a scrolling
    // workload, and a recycled row is how a stale switch ends up on a built-in.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sources.count else { return nil }
        let source = sources[row]
        let builtIn = source.id.hasPrefix("builtin.")

        let icon = NSImageView()
        icon.image = Self.icon(for: source)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let name = NSTextField(labelWithString: source.name)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: source.rootPath)
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [name, path])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        let state = NSTextField(labelWithString: statusText(for: source))
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        state.textColor = .secondaryLabelColor
        state.setContentHuggingPriority(.required, for: .horizontal)

        // Full size, like every switch in a system settings list. A built-in
        // source cannot be turned off, so its switch is on and disabled.
        let toggle = NSSwitch()
        toggle.state = source.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleSource(_:))
        toggle.tag = row
        toggle.isEnabled = !builtIn

        let stack = NSStackView(views: [icon, titles, NSView(), state, toggle])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(stack)
        cell.textField = name
        cell.imageView = icon
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // Rows are separated from the text column inward, not edge to edge — the
    // inset is what makes a list read as rows of one card instead of a grid.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SourceRowView()
        view.drawsSeparator = row < sources.count - 1
        return view
    }

    // The built-in roots are one engine each, so they carry that engine's mark —
    // the same artwork the table's AI column uses. A custom source can hold
    // transcripts from any of them, so it gets the neutral drive symbol.
    private static func icon(for source: SessionSource) -> NSImage? {
        switch source.id {
        case SessionSourceStore.builtInClaudeID,
             SessionSourceStore.builtInClaudeDesktopID:
            return ProviderIcon.image(for: .claude, size: 16)
        case SessionSourceStore.builtInCodexID:
            return ProviderIcon.image(for: .codex, size: 16)
        default:
            return NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                           accessibilityDescription: source.name)
        }
    }

    private static func stripButton(symbol: String, label: String,
                                    target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol,
                                             accessibilityDescription: label) ?? NSImage(),
                              target: target, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    // The verbs that need a source to act on. A list puts those on the row, not
    // in a button bar that has to explain which row it means.
    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [("Sync Now", #selector(retrySource)),
                                ("Clear Cache…", #selector(clearCache)),
                                ("Remove Source…", #selector(removeSource))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private var targetRow: Int {
        let clicked = table.clickedRow
        return clicked >= 0 ? clicked : table.selectedRow
    }

    // Every verb applies to a custom source only: a built-in has no snapshot to
    // clear, nothing of ours to sync, and cannot be removed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = targetRow
        let source = row >= 0 && row < sources.count ? sources[row] : nil
        let custom = source.map { !$0.id.hasPrefix("builtin.") } ?? false
        for item in menu.items {
            item.isEnabled = item.action == #selector(retrySource)
                ? custom && (source?.enabled ?? false)
                : custom
        }
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
        removeButton.isEnabled = row >= 0 && row < sources.count
            && !sources[row].id.hasPrefix("builtin.")
    }

    @objc private func toggleSource(_ sender: NSSwitch) {
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
        let row = targetRow
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
        let row = targetRow
        guard row >= 0, row < sources.count else { return }
        store.sync(sourceID: sources[row].id, force: true)
    }

    @objc private func clearCache() {
        let row = targetRow
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
