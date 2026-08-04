import AppKit

// Terminal integration — always on. EpiScope tracks every Claude Code
// session's hosting terminal (kitty, iTerm2, Terminal, Ghostty, xterm —
// see TerminalTracker) and can bring the user to it from the table
// (double-click) or from a notification banner. Both go through the
// same entry point: the bundled `cc-open <session-id>` script, which resolves
// the session via ~/.claude/state/cc-states.json and focuses the
// hosting window (kitty / iTerm2), activates the hosting app
// (ancestry-detected terminals), or opens a fresh terminal at the
// session's cwd.

enum TerminalIntegration {
    // The opener and the cc-states.json producer evolve as one protocol. Using
    // an arbitrary user script here lets an older parser silently discard new
    // fields and trigger the wrong fallback, so only the version shipped with
    // this app is valid.
    private static let bundledCCOpenPath = Bundle.main.path(forResource: "cc-open", ofType: nil)

    static func openSession(sessionId: String,
                            claudeDesktopSessionId: String? = nil) {
        // Opening a session counts as acknowledging it — clear its Finished /
        // needs-attention state (window focus can't be detected for the Claude app).
        TerminalTracker.shared.acknowledge(sessionId: sessionId)
        guard let path = bundledCCOpenPath, SessionID.isValid(sessionId) else { return }
        if let desktop = claudeDesktopSessionId, !SessionID.isValid(desktop) { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [sessionId] + (claudeDesktopSessionId.map { [$0] } ?? [])
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()  // fire and forget — the script owns all fallbacks
    }
}
