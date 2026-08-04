import Foundation

// Hand-written LaunchAgent plist. SMAppService.mainApp is the modern
// alternative but pulls ServiceManagement.framework into the link
// graph (~1MB at runtime); for a tiny menu bar utility a plist at
// ~/Library/LaunchAgents/<bundleID>.plist achieves the same thing
// and is what the framework would write anyway.
//
// On first launch we silently flip Launch-at-Login on so the user
// doesn't have to discover the menu item — same one-shot behavior
// as in dots.

@MainActor
enum LoginItem {
    private static let autoEnabledKey = "loginItemAutoEnabled"

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "almazko.EpiScope"
    }

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() {
        guard let exec = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": [exec],
            "RunAtLoad": true,
        ]
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else { return }
        // Atomic: a plist truncated by a crash mid-write is one launchd
        // rejects, and the user only finds out at the next login.
        try? data.write(to: plistURL, options: .atomic)
    }

    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    static func ensureFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoEnabledKey) else { return }
        defaults.set(true, forKey: autoEnabledKey)
        enable()
    }
}
