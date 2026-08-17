import Foundation

// Ctrl-B in Claude Code parks a session: the conversation is copied into a new
// session id and carries on there as a background job, while the transcript it
// came from stops mid-turn and stays on disk. The fleet therefore holds the
// same conversation twice — same path, same title, and the API calls that
// happened before the park are recorded in both files, so their tokens and
// their cost are counted twice.
//
// Neither transcript names the other. The link lives only in
// ~/.claude/sessions/<pid>.json while both processes are alive: the parked
// session carries `parkedJobId`, the job that took over carries `jobId`. It is
// recorded here the first time it is seen and never expires — the two
// transcripts it explains do not go away when the processes do.
@MainActor
final class ParkedSessions {
    static let shared = ParkedSessions()

    // Parked session id -> the session that continued it.
    private(set) var continuations: [String: String] = [:]

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appending(path: "EpiScope", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "parked-sessions.json")
    }()

    init() { load() }

    // Both ids come out of session files SessionStore has already validated, so
    // what is stored here can safely name a transcript later.
    // Returns true when a link was learned, so callers can repaint their rows.
    @discardableResult
    func observe(_ infos: [SessionInfo]) -> Bool {
        var sessionByJob: [String: String] = [:]
        for info in infos {
            guard let job = info.jobId else { continue }
            sessionByJob[job] = info.sessionId
        }
        var learned = false
        for info in infos {
            guard let job = info.parkedJobId,
                  let continuation = sessionByJob[job],
                  continuation != info.sessionId,
                  continuations[info.sessionId] != continuation
            else { continue }
            continuations[info.sessionId] = continuation
            learned = true
        }
        if learned { save() }
        return learned
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        continuations = stored.filter {
            SessionID.isValid($0.key) && SessionID.isValid($0.value)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(continuations) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
