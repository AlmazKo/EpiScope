import Foundation

// Locates the user's `claude` CLI binary. Session analysis shells out to
// `claude -p` (headless) so EpiScope itself stays free of network code and
// API keys — the CLI brings the user's existing login and plan with it.
// The CLI is user-installed rather than an EpiScope protocol component, so the
// `claudeCLIPath` user default wins, then the conventional install locations.
enum ClaudeCLI {
    static func locate() -> URL? {
        var candidates: [String] = []
        // The override is a power-user escape hatch, but it is also a plain
        // user default any local process can write — and an analysis starts on
        // its own daily timer, so whatever it names would run unattended.
        // Take it only while it still looks like the Claude CLI and neither it
        // nor its directory is writable by anyone but their owner.
        if let override = UserDefaults.standard.string(forKey: "claudeCLIPath"),
           !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("claude"),
               ownerOnlyWritable(path) {
                candidates.append(path)
            }
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

    // A binary sitting in a directory anyone can write to (say /tmp) can be
    // swapped out between the check and the launch, so treat both the file and
    // its directory as part of the identity.
    static func ownerOnlyWritable(_ path: String) -> Bool {
        let fm = FileManager.default
        for p in [path, (path as NSString).deletingLastPathComponent] {
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
                  mode & 0o022 == 0
            else { return false }
        }
        return true
    }

}
