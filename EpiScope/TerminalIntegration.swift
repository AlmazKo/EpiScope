import AppKit

// Terminal integration — always on. EpiScope tracks every Claude Code
// session's hosting terminal (kitty, iTerm2, Terminal, Ghostty, xterm —
// see TerminalTracker) and can bring the user to it from the table
// (double-click) or from a notification banner. Both go through the
// same entry point: the `cc-open <session-id>` script, which resolves
// the session via ~/.claude/state/cc-states.json and focuses the
// hosting window (kitty / iTerm2), activates the hosting app
// (ancestry-detected terminals), or opens a fresh terminal at the
// session's cwd. Keeping that logic in a script makes it hot-patchable
// without re-releasing the app.

enum TerminalIntegration {
    // A copy of cc-open ships in the app bundle, so double-click works
    // out of the box. A user copy in the conventional script locations
    // (or the `ccOpenPath` user default) overrides it — that keeps the
    // script hot-patchable without re-releasing the app.
    private static let ccOpenPath: String? = {
        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "ccOpenPath"),
           !override.isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            home + "/.local/bin/cc-open",
            home + "/bin/cc-open",
            home + "/dotfiles/bin/cc-open",
            "/usr/local/bin/cc-open",
            "/opt/homebrew/bin/cc-open",
        ]
        if let bundled = Bundle.main.path(forResource: "cc-open", ofType: nil) {
            candidates.append(bundled)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func openSession(sessionId: String) {
        // Opening a session counts as acknowledging it — clear its Finished /
        // needs-attention state (window focus can't be detected for the Claude app).
        TerminalTracker.shared.acknowledge(sessionId: sessionId)
        guard let path = ccOpenPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [sessionId]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()  // fire and forget — the script owns all fallbacks
    }
}
