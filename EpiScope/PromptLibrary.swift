import Foundation

// Loads the analysis prompt templates. Bundled defaults ship in the app
// (prompt-<name>.md); a user copy at Application Support/EpiScope/
// prompts/<name>.md overrides — hot-patchable without re-releasing, the
// cc-open philosophy.
nonisolated enum PromptLibrary {
    // The templates an analysis run can reach, and what each one drives. This
    // list is what Settings → Insights offers; a template missing from it is
    // still loadable, just not editable there.
    struct Template: Sendable {
        let name: String
        let title: String
        let blurb: String
    }

    static let templates: [Template] = [
        .init(name: "insights", title: "Daily & weekly insights",
              blurb: "The scheduled fleet report: the catalog of in-scope sessions "
                   + "plus digests of the priciest ones."),
        .init(name: "retro", title: "Session retrospective",
              blurb: "One session, analysed on request from the table."),
        .init(name: "question", title: "Fleet question",
              blurb: "A question asked of the fleet, answered from the catalog and "
                   + "full-text search hits."),
    ]

    static func render(_ name: String, vars: [String: String]) -> String? {
        guard var text = load(name) else { return nil }
        for (key, value) in vars {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return text
    }

    private static func load(_ name: String) -> String? {
        custom(name) ?? bundled(name)
    }

    static var overridesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/EpiScope/prompts",
                       directoryHint: .isDirectory)
    }

    private static func overrideURL(_ name: String) -> URL {
        overridesDirectory.appending(path: "\(name).md")
    }

    static func bundled(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: "prompt-\(name)", withExtension: "md")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func custom(_ name: String) -> String? {
        usableOverride(try? String(contentsOf: overrideURL(name), encoding: .utf8))
    }

    static func isCustomised(_ name: String) -> Bool {
        custom(name) != nil
    }

    // Writing the bundled text verbatim still counts as an override — the file
    // is what the operator edits, and silently dropping it would undo an edit
    // that only looks like a no-op until the next release changes the default.
    @discardableResult
    static func save(_ text: String, for name: String) -> Bool {
        // An empty override is never a usable analysis prompt. Refuse the
        // write and leave the last valid custom copy (or bundled fallback) in
        // force while the editor reports that the draft was not saved.
        guard isValidOverride(text) else {
            return false
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return false }
        do {
            try data.write(to: overrideURL(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func isValidOverride(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func usableOverride(_ text: String?) -> String? {
        guard let text, isValidOverride(text) else { return nil }
        return text
    }

    // Restoring the default deletes the override, so the app falls back to the
    // bundled copy and keeps following it as later releases change it. The file
    // goes to the Trash: it may be an hour of somebody's wording.
    static func restoreDefault(_ name: String) {
        let url = overrideURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // The {{PLACEHOLDERS}} a template is rendered with, in the order they first
    // appear. Read off the bundled text: it is the contract the run fills in,
    // and an edited copy that dropped one should still say what was available.
    static func placeholders(_ name: String) -> [String] {
        guard let text = bundled(name) else { return [] }
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let key = String(rest[open.upperBound..<close.lowerBound])
            if !key.isEmpty, !key.contains("\n"), !found.contains(key) { found.append(key) }
            rest = rest[close.upperBound...]
        }
        return found
    }
}
