import Foundation

// Loads the analysis prompt templates. Bundled defaults ship in the app
// (prompt-<name>.md); a user copy at Application Support/EpiScope/
// prompts/<name>.md overrides — hot-patchable without re-releasing, the
// cc-open philosophy.
nonisolated enum PromptLibrary {
    static func render(_ name: String, vars: [String: String]) -> String? {
        guard var text = load(name) else { return nil }
        for (key, value) in vars {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return text
    }

    private static func load(_ name: String) -> String? {
        let override = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/EpiScope/prompts/\(name).md")
        if let custom = try? String(contentsOf: override, encoding: .utf8) {
            return custom
        }
        guard let bundled = Bundle.main.url(forResource: "prompt-\(name)", withExtension: "md")
        else { return nil }
        return try? String(contentsOf: bundled, encoding: .utf8)
    }
}
