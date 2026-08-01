import Foundation

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

    var isWaiting: Bool { status == "waiting" }
    var isSdkCli: Bool { entrypoint == "sdk-cli" }

    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var updatedAtDate: Date {
        guard let updatedAt else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000)
    }
}
