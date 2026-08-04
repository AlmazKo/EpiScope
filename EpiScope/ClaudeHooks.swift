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
//   * a symlinked config is written through, not replaced, so a dotfiles
//     repo keeps owning the file and the backup holds content, not a link,
//   * a file that changed while we were merging is left alone entirely,
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

    // Both settings.json and the hook scripts are commonly symlinks into a
    // dotfiles repo. Write through the link: replacing the path itself leaves a
    // regular file behind and silently detaches the repo, and copying the link
    // would make the "backup" a second link instead of a copy of the content.
    private static func resolved(_ path: String) -> String {
        guard (try? FileManager.default.attributesOfItem(atPath: path))?[.type]
                as? FileAttributeType == .typeSymbolicLink
        else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // (mtime, size), taken before we read and re-checked before we swap. Our
    // write is a whole-document replacement, so a hook Claude Code added — or
    // an edit the user made — in between would vanish without a trace.
    private static func stamp(of path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber
        else { return nil }
        return "\(mtime.timeIntervalSince1970)/\(size.int64Value)"
    }

    private static func settingsRoot() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: resolved(settingsPath)),
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
            let target = resolved(path)
            let existing = try? String(contentsOfFile: target, encoding: .utf8)
            if existing == nil || existing?.contains(marker) == true {
                if existing != script {
                    try script.write(toFile: target, atomically: true, encoding: .utf8)
                }
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
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
        let target = resolved(settingsPath)
        let settingsExists = fm.fileExists(atPath: target)
        // Taken before the read, so a write that lands between the two is
        // still caught by the re-check below.
        let before = settingsExists ? stamp(of: target) : nil
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
                guard stamp(of: target) == before else {
                    return "~/.claude/settings.json changed while EpiScope was updating "
                         + "it — nothing was written, so that change is intact. "
                         + "EpiScope will retry on the next launch."
                }
                _ = try? fm.removeItem(atPath: backupPath)
                try fm.copyItem(atPath: target, toPath: backupPath)
                let tmp = target + ".episcope.tmp"
                _ = try? fm.removeItem(atPath: tmp)
                guard fm.createFile(atPath: tmp, contents: data)
                else { return "Could not write to ~/.claude." }
                do {
                    _ = try fm.replaceItemAt(
                        URL(fileURLWithPath: target),
                        withItemAt: URL(fileURLWithPath: tmp))
                } catch {
                    _ = try? fm.removeItem(atPath: tmp)   // no orphan next to their config
                    throw error
                }
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
