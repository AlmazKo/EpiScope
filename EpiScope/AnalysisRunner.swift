import Foundation

// Runs one headless `claude -p` analysis at a time. The runner owns the
// child Process, feeds the prompt via stdin (argv would hit ARG_MAX and
// leak into `ps`), drains stdout/stderr concurrently (a long report
// overruns the 64KB pipe buffer — draining after waitUntilExit would
// deadlock), parses the CLI's result JSON, and enforces a wall-clock
// timeout with a SIGTERM → grace → SIGKILL ladder.
//
// The agent gets a read-only tool whitelist and its cwd is a scratch dir
// under the per-user temp root — so its own transcript lands in a ~/.claude
// project dir that SessionIndexer treats as temporary and never shows or
// scans (no self-pollution of the session table), and the read-only tools
// mean transcript text can't steer it into touching the machine.

nonisolated struct AnalysisRequest {
    // Full prompt text; packet/catalog files are referenced by path so
    // the prompt itself stays small.
    let prompt: String
    // Directories the agent may Read/Grep/Glob: the packet dir plus the
    // raw ~/.claude/projects/<encoded-cwd> dirs for drill-down.
    let addDirs: [URL]
    // CLI --model argument (alias or full id).
    let model: String
    // Scratch cwd for the run — create via AnalysisRunner.makeWorkDir()
    // and write packets into it before calling run().
    let workDir: URL
    var maxTurns: Int = 25
    var timeout: TimeInterval = 600
}

nonisolated struct AnalysisOutcome {
    let markdown: String
    let costUSD: Double?
    let agentSessionId: String?
    let numTurns: Int?
    let durationSec: Double?
    // false when stdout wasn't the expected result JSON and `markdown`
    // carries the raw output instead.
    let parsedJSON: Bool
}

nonisolated enum AnalysisError: Error {
    case cliNotFound
    case launchFailed(String)
    case exit(code: Int32, stderr: String)
    // Clean exit but the CLI reported is_error (not logged in, limit
    // reached, max turns exhausted…) — message comes from the result JSON.
    case agentError(String)
    case timeout(TimeInterval)
    case cancelled

    var userMessage: String {
        switch self {
        case .cliNotFound:
            return "The claude CLI was not found. Install Claude Code, or point "
                + "EpiScope at the binary via the claudeCLIPath default."
        case .launchFailed(let why):
            return "Could not launch the claude CLI: \(why)"
        case .exit(let code, let stderr):
            let tail = stderr.isEmpty ? "" : "\n\n\(stderr)"
            return "claude exited with status \(code).\(tail)"
        case .agentError(let message):
            return message
        case .timeout(let seconds):
            return "The analysis did not finish within \(Int(seconds))s and was stopped."
        case .cancelled:
            return "Cancelled."
        }
    }
}

@MainActor
final class AnalysisRunner {
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private var process: Process?
    // The analysis group is held for as long as the child lives; releasing it
    // is what lets a queued run start.
    private var activeLease: WorkScheduler.Lease?
    private var cancelled = false
    private var timedOut = false
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?

    // Accumulates one pipe's output from readabilityHandler callbacks
    // (arbitrary thread) and hands the full data back after termination.
    nonisolated private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = Data()
        private let handle: FileHandle
        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard let self, !chunk.isEmpty else { return }
                self.lock.lock()
                self.buf.append(chunk)
                self.lock.unlock()
            }
        }
        // Stop the handler and pick up whatever was still buffered in the
        // pipe when the child exited.
        func finish() -> Data {
            handle.readabilityHandler = nil
            let rest = (try? handle.readToEnd()) ?? nil
            lock.lock(); defer { lock.unlock() }
            if let rest { buf.append(rest) }
            return buf
        }
    }

    // Packets are verbatim conversation text, so the scratch root is the
    // per-user temp dir (/var/folders/…, created 0700 by the OS and private to
    // this account) rather than world-writable /private/tmp, where any other
    // local user could read them — or pre-create the root as a symlink. It
    // still resolves under /private/var, so SessionIndexer keeps classifying
    // the agent's own session as temporary and never shows it.
    nonisolated static var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("episcope-analysis", isDirectory: true)
    }

    static func makeWorkDir() -> URL {
        let dir = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    // An analysis is minutes of a child process. It may wait for anything else
    // in its group, and it must hold nothing anyone else needs — so it takes a
    // lease on the analysis group for the lifetime of the process, and only
    // that group. Nothing outside it ever queues behind an analysis.
    func run(_ request: AnalysisRequest,
             completion: @escaping (Result<AnalysisOutcome, AnalysisError>) -> Void) {
        WorkScheduler.shared.lease(group: WorkScheduler.Group.analysis) { [weak self] lease in
            DispatchQueue.main.async {
                guard let self else { lease.release(); return }
                MainActor.assumeIsolated {
                    self.launch(request, lease: lease, completion: completion)
                }
            }
        }
    }

    private func launch(_ request: AnalysisRequest, lease: WorkScheduler.Lease,
                        completion: @escaping (Result<AnalysisOutcome, AnalysisError>) -> Void) {
        guard !isRunning else {
            lease.release()
            completion(.failure(.launchFailed("an analysis is already running")))
            return
        }
        guard let cli = ClaudeCLI.locate() else {
            lease.release()
            completion(.failure(.cliNotFound))
            return
        }
        // Held until the process is reaped in finish(); the group stays busy
        // for exactly as long as the CLI runs.
        activeLease = lease

        let p = Process()
        p.executableURL = cli
        var args = [
            "-p",
            "--output-format", "json",
            "--model", request.model,
            "--max-turns", String(request.maxTurns),
            "--allowedTools", "Read,Grep,Glob",
            // --allowedTools pre-approves tools; it does not disable the rest.
            // Without the three flags below the run would inherit the user's
            // own permissions.allow, defaultMode and MCP servers — so how
            // contained this agent is would depend on how somebody else
            // configured their CLI, while it chews on transcript text written
            // by whoever the observed sessions talked to.
            "--disallowedTools",
            "Bash,Write,Edit,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task",
            "--permission-mode", "default",
            "--strict-mcp-config",
        ]
        for dir in request.addDirs { args += ["--add-dir", dir.path] }
        p.arguments = args
        p.currentDirectoryURL = request.workDir
        p.environment = ClaudeCLI.environment(for: cli)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        let outDrain = PipeDrain(stdoutPipe)
        let errDrain = PipeDrain(stderrPipe)

        p.terminationHandler = { [weak self] proc in
            let out = outDrain.finish()
            let err = errDrain.finish()
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                self?.finish(request: request, status: status,
                             stdout: out, stderr: err, completion: completion)
            }
        }

        isRunning = true
        startedAt = Date()
        cancelled = false
        timedOut = false
        process = p

        do {
            try p.run()
        } catch {
            isRunning = false
            process = nil
            activeLease?.release()
            activeLease = nil
            completion(.failure(.launchFailed(error.localizedDescription)))
            return
        }

        // Feed the prompt off-main: a write bigger than the pipe buffer
        // blocks until the child reads it.
        let promptData = Data(request.prompt.utf8)
        DispatchQueue.global(qos: .utility).async {
            let fh = stdinPipe.fileHandleForWriting
            try? fh.write(contentsOf: promptData)
            try? fh.close()
        }

        // SIGTERM lets the CLI exit cleanly; the kill ladder is armed by
        // stop(reason:) only if it lingers.
        let timeout = DispatchWorkItem { [weak self] in
            self?.stop(markTimedOut: true)
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: timeout)
    }

    func cancel() {
        guard isRunning else { return }
        stop(markTimedOut: false)
    }

    private func stop(markTimedOut: Bool) {
        guard let p = process, p.isRunning else { return }
        if markTimedOut { timedOut = true } else { cancelled = true }
        p.terminate()
        let pid = p.processIdentifier
        let kill = DispatchWorkItem { [weak self] in
            guard let p = self?.process, p.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
        killWork = kill
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: kill)
    }

    private func finish(request: AnalysisRequest, status: Int32,
                        stdout: Data, stderr: Data,
                        completion: (Result<AnalysisOutcome, AnalysisError>) -> Void) {
        timeoutWork?.cancel()
        killWork?.cancel()
        timeoutWork = nil
        killWork = nil
        process = nil
        isRunning = false
        startedAt = nil
        activeLease?.release()
        activeLease = nil

        if cancelled {
            cleanUp(request.workDir)
            completion(.failure(.cancelled))
            return
        }
        if timedOut {
            cleanUp(request.workDir)
            completion(.failure(.timeout(request.timeout)))
            return
        }
        if status != 0 {
            // Keep workDir for a post-mortem; the temp root is periodically
            // purged by the OS anyway.
            let tail = String(data: stderr.suffix(2000), encoding: .utf8) ?? ""
            completion(.failure(.exit(code: status,
                                      stderr: tail.trimmingCharacters(in: .whitespacesAndNewlines))))
            return
        }

        cleanUp(request.workDir)
        completion(Self.parseResult(stdout: stdout))
    }

    private func cleanUp(_ workDir: URL) {
        // Only ever remove our own scratch dirs, whatever the request said.
        guard workDir.path.hasPrefix(Self.scratchRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Result JSON

    // `claude -p --output-format json` prints a single result object:
    // {"type":"result","subtype":"success","is_error":false,"result":"…",
    //  "session_id":"…","total_cost_usd":…,"num_turns":…,"duration_ms":…}
    // Decoded defensively — on any mismatch the raw stdout becomes the
    // report body so a CLI format change degrades instead of failing.
    nonisolated private struct CLIResult: Decodable {
        let type: String?
        let subtype: String?
        let isError: Bool?
        let result: String?
        let sessionId: String?
        let totalCostUsd: Double?
        let numTurns: Int?
        let durationMs: Double?
    }

    nonisolated private static func parseResult(stdout: Data)
        -> Result<AnalysisOutcome, AnalysisError> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let res = try? decoder.decode(CLIResult.self, from: stdout) else {
            let raw = String(data: stdout, encoding: .utf8) ?? ""
            return .success(AnalysisOutcome(
                markdown: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                costUSD: nil, agentSessionId: nil, numTurns: nil,
                durationSec: nil, parsedJSON: false))
        }
        if res.isError == true {
            let msg = res.result?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.agentError(
                (msg?.isEmpty == false ? msg! : nil)
                    ?? "The agent reported an error (\(res.subtype ?? "unknown"))."))
        }
        return .success(AnalysisOutcome(
            markdown: res.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            costUSD: res.totalCostUsd,
            agentSessionId: res.sessionId,
            numTurns: res.numTurns,
            durationSec: res.durationMs.map { $0 / 1000 },
            parsedJSON: true))
    }
}
