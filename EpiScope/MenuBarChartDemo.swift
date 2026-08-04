import AppKit

// TEMPORARY — a harness for eyeballing the menu-bar chart in every state
// without arranging real sessions. Delete this file and its two lines in
// AppDelegate (the `chartDemo` property and the `start` call, plus the
// early return in `render()`) when the look is settled.
//
// It walks a fixed list of configurations, one every 6 seconds, and puts
// the current one's name in the status item's tooltip so hovering says
// what is on screen. Off by default — turn it on (and restart) with:
//
//   defaults write almazko.EpiScope menuBarDemo -bool YES
@MainActor
final class MenuBarChartDemo {
    private static let interval: TimeInterval = 6

    private static let configs: [(name: String, bars: [MenuBarChart.Bar])] = [
        ("0 · nothing live (all slots free)", []),
        ("1 · one running", [.active]),
        ("2 · three running", [.active, .active, .active]),
        ("3 · five running (one slot free)", Array(repeating: .active, count: 5)),
        ("4 · six running (all slots taken)", Array(repeating: .active, count: 6)),
        ("5 · ten running (four cut)", Array(repeating: .active, count: 10)),
        ("6 · one permission alone", [.permission]),
        ("7 · one question alone", [.question]),
        ("8 · permission + three running", [.permission, .active, .active, .active]),
        ("9 · question + three running", [.question, .active, .active, .active]),
        ("10 · both blinks + two running", [.permission, .question, .active, .active]),
        ("11 · three permissions", [.permission, .permission, .permission]),
        ("12 · three questions", [.question, .question, .question]),
        ("13 · busy fleet, running bars cut",
            [.permission, .permission, .question, .question]
            + Array(repeating: .active, count: 6)),
    ]

    private(set) var isRunning = false
    private weak var chart: MenuBarChart?
    private weak var statusItem: NSStatusItem?
    private var index = 0
    private var timer: Timer?

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "menuBarDemo")
    }

    func start(chart: MenuBarChart, statusItem: NSStatusItem) {
        guard Self.isEnabled, !isRunning else { return }
        isRunning = true
        self.chart = chart
        self.statusItem = statusItem
        show()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.index = (self.index + 1) % Self.configs.count
                self.show()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func show() {
        let config = Self.configs[index]
        NSLog("[menu-bar demo] %@", config.name)
        statusItem?.button?.toolTip = "Demo: \(config.name)"
        chart?.update(bars: config.bars)
    }
}
