import Foundation

// Installer for the Claude Code integration. Two bridges, both writing
// to ~/.claude/state for EpiScope to read:
//   * tab-state.sh — turns CC hook events into session-state signals
//     (instant busy/waiting/done transitions on top of status polling).
//   * episcope-statusline.sh — captures the real, server-side rate-limit
//     percentages CC pipes to the status line, so the Limits gauges show
//     authoritative numbers instead of a token estimate.
//
// settings.json is another tool's config and may carry the user's own
// hooks / status line — every touch here is deliberately gentle:
//   * strictly additive for hooks: only events with no tab-state.sh
//     route get an entry appended; nothing is removed or rewritten,
//   * statusLine is set only when absent or already ours; a foreign
//     status line is never clobbered,
//   * invalid JSON aborts the install rather than "fixing" the file,
//   * the previous settings.json is kept as settings.json.episcope.bak,
//   * the new file is round-trip-validated and swapped in atomically,
//   * a managed script is overwritten only while its marker is intact.
enum ClaudeHooks {
    struct HookSpec {
        let event: String
        let matcher: String
        let arg: String
        let async: Bool
    }

    static let specs: [HookSpec] = [
        .init(event: "UserPromptSubmit", matcher: "", arg: "thinking", async: false),
        .init(event: "PostToolUse", matcher: ".*", arg: "thinking", async: true),
        .init(event: "PermissionRequest", matcher: "", arg: "needs_permission", async: false),
        .init(event: "Stop", matcher: "", arg: "done", async: false),
        .init(event: "SessionEnd", matcher: "", arg: "idle", async: false),
    ]

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var scriptPath: String { home + "/.claude/hooks/tab-state.sh" }
    static var statusLinePath: String { home + "/.claude/hooks/episcope-statusline.sh" }
    static var settingsPath: String { home + "/.claude/settings.json" }
    static var backupPath: String { home + "/.claude/settings.json.episcope.bak" }

    // Markers separating our managed scripts from user copies — must
    // match the first comment line of the bundled scripts.
    private static let scriptMarker = "episcope-hook"
    private static let statusLineMarker = "episcope-statusline"

    private static func settingsRoot() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root
    }

    // Events not yet routed to tab-state.sh in the user's settings.
    static func missingEvents() -> [HookSpec] {
        guard let root = settingsRoot() else { return specs }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return specs.filter { spec in
            guard let groups = hooks[spec.event] as? [[String: Any]] else { return true }
            return !groups.contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains("tab-state.sh") == true
                }
            }
        }
    }

    enum StatusLineState { case missing, ours, foreign }

    static func statusLineState() -> StatusLineState {
        guard let root = settingsRoot(),
              let sl = root["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String
        else { return .missing }
        return cmd.contains("episcope-statusline") ? .ours : .foreign
    }

    static func isInstalled() -> Bool {
        missingEvents().isEmpty && statusLineState() == .ours
    }

    // Copies a bundled managed script into place, but only when it's
    // absent or carries our marker (never over a user-customised copy).
    private static func installScript(resource: String, to path: String,
                                      marker: String) -> String? {
        let fm = FileManager.default
        guard let bundled = Bundle.main.path(forResource: resource, ofType: "sh"),
              let script = try? String(contentsOfFile: bundled, encoding: .utf8)
        else { return "\(resource).sh is missing from the app bundle." }
        do {
            try fm.createDirectory(atPath: home + "/.claude/hooks",
                                   withIntermediateDirectories: true)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            if existing == nil || existing?.contains(marker) == true {
                if existing != script {
                    try script.write(toFile: path, atomically: true, encoding: .utf8)
                }
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        } catch {
            return "Could not install \(resource).sh: \(error.localizedDescription)"
        }
        return nil
    }

    // Returns nil on success, a user-facing error message otherwise.
    static func install() -> String? {
        let fm = FileManager.default

        // 1. The managed scripts (overwrite only what we own).
        if let err = installScript(resource: "tab-state", to: scriptPath, marker: scriptMarker) {
            return err
        }
        if let err = installScript(resource: "episcope-statusline",
                                   to: statusLinePath, marker: statusLineMarker) {
            return err
        }

        // 2. settings.json — additive hook merge + statusLine.
        let missing = missingEvents()
        let slState = statusLineState()
        let needsStatusLine = (slState == .missing)
        guard !missing.isEmpty || needsStatusLine else { return nil }

        var root: [String: Any] = [:]
        let settingsExists = fm.fileExists(atPath: settingsPath)
        if settingsExists {
            guard let parsed = settingsRoot() else {
                return "~/.claude/settings.json is not valid JSON — left untouched. "
                     + "Fix the file (or remove it) and try again."
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for spec in missing {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            var hook: [String: Any] = [
                "type": "command",
                "command": "~/.claude/hooks/tab-state.sh " + spec.arg,
            ]
            if spec.async { hook["async"] = true }
            groups.append(["matcher": spec.matcher, "hooks": [hook]])
            hooks[spec.event] = groups
        }
        root["hooks"] = hooks

        if needsStatusLine {
            root["statusLine"] = [
                "type": "command",
                "command": "~/.claude/hooks/episcope-statusline.sh",
            ]
        }

        do {
            var data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // JSONSerialization escapes every "/" as "\/" — valid but
            // unreadable in a config people open by hand. Undoing it is
            // lossless: "/" never needs escaping, and an even run of
            // backslashes before "\/" decodes identically either way.
            if let pretty = String(data: data, encoding: .utf8) {
                data = Data(pretty.replacingOccurrences(of: "\\/", with: "/").utf8)
            }
            _ = try JSONSerialization.jsonObject(with: data)  // round-trip guard
            if settingsExists {
                _ = try? fm.removeItem(atPath: backupPath)
                try fm.copyItem(atPath: settingsPath, toPath: backupPath)
                let tmp = settingsPath + ".episcope.tmp"
                guard fm.createFile(atPath: tmp, contents: data)
                else { return "Could not write to ~/.claude." }
                _ = try fm.replaceItemAt(
                    URL(fileURLWithPath: settingsPath),
                    withItemAt: URL(fileURLWithPath: tmp))
            } else {
                guard fm.createFile(atPath: settingsPath, contents: data)
                else { return "Could not write to ~/.claude." }
            }
        } catch {
            return "Could not update settings.json: \(error.localizedDescription). "
                 + "The original file is unchanged."
        }
        return nil
    }
}
