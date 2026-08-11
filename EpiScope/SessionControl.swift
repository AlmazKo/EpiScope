import Foundation

// Ending a session from the table — what `/exit` does from inside it.
//
// SIGTERM is the whole mechanism: Claude Code and Codex both shut down on it
// the way they do on `/exit`, and the transcript is already on disk (every
// record is appended as it happens), so nothing is lost by not asking the CLI
// nicely. There is deliberately no escalation to SIGKILL — a session that
// ignores SIGTERM is mid-write or wedged, and killing it outright is a
// different decision than "stop this session", one the operator can still make
// from a terminal.
//
// The pid is untrusted. Claude publishes it in ~/.claude/sessions/<pid>.json,
// which any local process can rewrite, and pids are reused: a forged or stale
// file points our signal at whatever now holds that number. So nothing is
// signalled until `ps` confirms the process is the provider's own program.
enum SessionControl {
    enum StopOutcome {
        case stopped
        // The process is gone already, or the pid now belongs to something that
        // is not this provider's CLI. Same answer either way: nothing to stop.
        case notRunning
        case failed
    }

    @discardableResult
    static func stop(pid: Int, provider: SessionProvider) -> StopOutcome {
        // pid 0 is "no process" in the synthesised entries; 1 is launchd.
        guard pid > 1, let program = provider.stoppableProcess,
              let command = processCommand(pid: pid),
              commandRuns(command, program: program)
        else { return .notRunning }
        return Darwin.kill(pid_t(pid), SIGTERM) == 0 ? .stopped : .failed
    }

    static func isRunning(pid: Int) -> Bool {
        // EPERM means the pid exists and belongs to somebody else — still alive.
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // Polls until the process is gone or the deadline passes. Polling, not
    // waitpid: the session is not our child, so there is no status to reap.
    @MainActor
    static func waitForExit(pid: Int, timeout: TimeInterval,
                            completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard isRunning(pid: pid) else { return completion(true) }
            guard Date() < deadline else { return completion(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
        }
        poll()
    }

    private static func processCommand(pid: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The CLI is usually not argv[0] — Claude Code runs as
    // `node /Users/…/.local/bin/claude --resume …` — so the program is looked
    // for as a whole path component of any argument, never as a substring:
    // "claude" appears in the command line of anything started from a directory
    // with that name, this app's own analysis runs included.
    private static func commandRuns(_ command: String, program: String) -> Bool {
        command.split(separator: " ").contains { token in
            (token.split(separator: "/").last.map(String.init) ?? String(token)) == program
        }
    }
}
