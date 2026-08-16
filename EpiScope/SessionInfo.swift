import Foundation

// Session ids come out of files other tools write — ~/.claude/sessions/<pid>.json,
// transcript filenames — and we then use them as path components
// (~/.claude/state/sig-<id>, which we also delete) and as arguments of a shell
// command we put on the clipboard. Real ids are uuids, with a local_ prefix in
// the Claude desktop store, so anything carrying a separator or a quote is a
// forgery rather than a session and gets dropped before it can name a file.
enum SessionID {
    static func isValid(_ sid: String) -> Bool {
        guard !sid.isEmpty, sid.count <= 128 else { return false }
        return sid.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F || c == 0x2E
        }
    }
}

struct SessionInfo: Decodable, Equatable {
    let pid: Int
    let sessionId: String
    let cwd: String

    // status / waitingFor / updatedAt are only written by the regular
    // `cli` entrypoint. SDK-CLI sessions (--permission-prompt-tool stdio)
    // omit them entirely, and the monitor synthesises them from the
    // session jsonl tail.
    var status: String?
    var waitingFor: String?
    var updatedAt: Int64?
    // Epoch-ms when `status` last changed — used to time how long a session
    // has been busy ("thinking" elapsed).
    var statusUpdatedAt: Int64?
    var entrypoint: String?
    // Optional session label from ~/.claude/sessions/<pid>.json (e.g. a
    // worktree name). Claude sets the terminal tab title to it, so it's the key
    // that disambiguates several sessions sharing one cwd in Ghostty.
    var name: String?

    // Ctrl-B parks a session: the conversation moves into a background job that
    // gets a session id — and a transcript — of its own, while the foreground
    // record stays behind pointing at it. The two are matched on the *job* id,
    // which is what both fields carry: `parkedJobId` on the session that was
    // parked, `jobId` on the job that took it over. Neither is a session id.
    var jobId: String?
    var parkedJobId: String?

    // User-opened overlays (currently `/btw`) temporarily publish
    // `waiting / dialog open` even though the main turn keeps running. They are
    // not permission/question requests and must not enter the attention path.
    var isEphemeralDialogOpen: Bool {
        status == "waiting" && waitingFor == "dialog open"
    }
    var isWaiting: Bool { status == "waiting" && !isEphemeralDialogOpen }
    var attentionStatus: String? { isEphemeralDialogOpen ? nil : status }
    var isSdkCli: Bool { entrypoint == "sdk-cli" }

    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    // Exact for regular CLI sessions; updatedAt is the provider fallback for
    // Codex and SDK-driven sessions that do not publish statusUpdatedAt.
    var statusChangedAtDate: Date? {
        guard let ms = statusUpdatedAt ?? updatedAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
