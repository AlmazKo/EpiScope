import Foundation

// Locates the user's `claude` CLI binary. Session analysis shells out to
// `claude -p` (headless) so EpiScope itself stays free of network code and
// API keys — the CLI brings the user's existing login and plan with it.
// Same override philosophy as cc-open (TerminalIntegration): the
// `claudeCLIPath` user default wins, then the conventional install
// locations.
enum ClaudeCLI {
    static func locate() -> URL? {
        var candidates: [String] = []
        if let override = UserDefaults.standard.string(forKey: "claudeCLIPath"),
           !override.isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            home + "/.claude/local/claude",
            home + "/.local/bin/claude",
            home + "/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // PATH for spawned CLI runs. Finder-launched apps inherit a bare
    // /usr/bin:/bin PATH; the CLI (or the node its wrapper execs) may live
    // in Homebrew or ~/.local, so prepend the usual suspects plus the
    // resolved binary's own directory.
    static func environment(for cli: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            cli.deletingLastPathComponent().path,
            home + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }
}
