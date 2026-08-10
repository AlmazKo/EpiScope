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
    // Which CLI runs this — it decides the argv and how the result is read.
    var engine: AnalysisEngine = .claude
    // CLI --model argument (alias or full id), in that CLI's own naming.
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
    case cliNotFound(AnalysisEngine)
    case launchFailed(String)
    case exit(code: Int32, stderr: String)
    // Clean exit but the CLI reported is_error (not logged in, limit
    // reached, max turns exhausted…) — message comes from the result JSON.
    case agentError(String)
    case timeout(TimeInterval)
    case cancelled

    var userMessage: String {
        switch self {
        case .cliNotFound(let engine):
            return engine.cliMissingMessage
        case .launchFailed(let why):
            return "Could not launch the analysis CLI: \(why)"
        case .exit(let code, let stderr):
            let tail = stderr.isEmpty ? "" : "\n\n\(stderr)"
            return "The analysis CLI exited with status \(code).\(tail)"
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
        guard let cli = request.engine.locate() else {
            lease.release()
            completion(.failure(.cliNotFound(request.engine)))
            return
        }
        // Held until the process is reaped in finish(); the group stays busy
        // for exactly as long as the CLI runs.
        activeLease = lease

        let p = Process()
        p.executableURL = cli
        p.arguments = request.engine.arguments(for: request)
        p.currentDirectoryURL = request.workDir
        p.environment = AnalysisEngine.environment(for: cli)

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
            // Codex says why in its event stream and puts startup noise on
            // stderr (a models-cache warning it prints on healthy runs too), so
            // the exit code plus stderr is the least informative thing we have.
            // Prefer the stream whenever it carried an error.
            if request.engine == .codex,
               let streamed = Self.codexStreamError(stdout: stdout) {
                cleanUp(request.workDir)
                completion(.failure(.agentError(streamed)))
                return
            }
            // Keep workDir for a post-mortem; the temp root is periodically
            // purged by the OS anyway.
            let tail = String(data: stderr.suffix(2000), encoding: .utf8) ?? ""
            completion(.failure(.exit(code: status,
                                      stderr: tail.trimmingCharacters(in: .whitespacesAndNewlines))))
            return
        }

        // Parse before cleanUp: Codex writes its final message into a file
        // inside workDir, so removing the dir first would take the report.
        let outcome = Self.parseResult(request: request, stdout: stdout)
        cleanUp(request.workDir)
        completion(outcome)
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

    nonisolated private static func parseResult(request: AnalysisRequest, stdout: Data)
        -> Result<AnalysisOutcome, AnalysisError> {
        switch request.engine {
        case .claude: return parseClaudeResult(stdout: stdout)
        case .codex: return parseCodexResult(request: request, stdout: stdout)
        }
    }

    nonisolated private static func parseClaudeResult(stdout: Data)
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

    // MARK: - Codex event stream

    // `codex exec --json` streams one JSON object per line:
    //   {"type":"thread.started","thread_id":"…"}
    //   {"type":"turn.started"}
    //   {"type":"item.completed","item":{"type":"agent_message","text":"…"}}
    //   {"type":"turn.completed","usage":{"input_tokens":…,"cached_input_tokens":…,
    //                                     "output_tokens":…,"reasoning_output_tokens":…}}
    // The report itself comes from --output-last-message rather than the last
    // agent_message: it survives a stream shape change, and reasoning-only
    // turns don't shift which message is "last".
    nonisolated private struct CodexEvent: Decodable {
        struct Item: Decodable {
            let type: String?
            let text: String?
        }
        struct Usage: Decodable {
            let inputTokens: Int64?
            let cachedInputTokens: Int64?
            let outputTokens: Int64?
            let reasoningOutputTokens: Int64?
        }
        struct Failure: Decodable {
            let message: String?
        }
        let type: String?
        let threadId: String?
        let item: Item?
        let usage: Usage?
        // Why a run failed: an `error` event carries the message at the top
        // level, `turn.failed` puts it under `error`. Both are emitted, and the
        // process exits non-zero — but its stderr holds only startup noise, so
        // this stream is the only place the actual reason appears.
        let message: String?
        let error: Failure?
    }

    nonisolated private static func parseCodexResult(request: AnalysisRequest, stdout: Data)
        -> Result<AnalysisOutcome, AnalysisError> {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = String(data: stdout, encoding: .utf8) ?? ""

        var threadId: String?
        var lastMessage: String?
        var usage: CodexEvent.Usage?
        var turns = 0
        let errorMessage = codexStreamError(stdout: stdout)
        var sawEvent = false

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(CodexEvent.self, from: data)
            else { continue }   // Codex prefixes some lines with plain log text.
            sawEvent = true
            switch event.type {
            case "thread.started": threadId = event.threadId ?? threadId
            case "turn.completed":
                turns += 1
                usage = event.usage ?? usage
            case "item.completed":
                if event.item?.type == "agent_message", let text = event.item?.text {
                    lastMessage = text
                }
            default: break
            }
        }

        if let errorMessage {
            return .failure(.agentError(errorMessage))
        }

        // The file is authoritative; the stream is the fallback.
        let fromFile = request.engine.lastMessageURL(in: request.workDir)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let markdown = (fromFile ?? lastMessage ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty {
            return .failure(.agentError("Codex produced no report."))
        }
        return .success(AnalysisOutcome(
            markdown: markdown,
            costUSD: usage.map { cost(of: $0, model: request.model) },
            agentSessionId: threadId,
            numTurns: turns > 0 ? turns : nil,
            durationSec: nil,
            // False when nothing decoded as an event — the body is then raw
            // output, which is exactly what the flag means for Claude too.
            parsedJSON: sawEvent && fromFile != nil))
    }

    // The reason a Codex run failed, if its stream carried one. Separate from
    // the full parse because it is needed on both paths: a run can fail with a
    // non-zero exit, or announce the failure and still exit 0.
    nonisolated private static func codexStreamError(stdout: Data) -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = String(data: stdout, encoding: .utf8) ?? ""
        var found: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(CodexEvent.self, from: data),
                  event.type == "error" || event.type == "turn.failed"
            else { continue }
            if let message = event.message ?? event.error?.message, !message.isEmpty {
                found = unwrapCodexError(message)
            }
        }
        return found
    }

    // Codex hands the upstream API error through verbatim, so the message is
    // itself a JSON document: {"type":"error","status":400,"error":{"message":…}}.
    // Shown raw it is a wall of escaped braces, and the one sentence that tells
    // the user what to do ("that model needs a newer Codex") is buried in it.
    nonisolated private static func unwrapCodexError(_ message: String) -> String {
        guard let data = message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = obj["error"] as? [String: Any],
              let text = inner["message"] as? String, !text.isEmpty
        else { return message }
        return text
    }

    // Codex reports cumulative input with cache reads folded in, the same shape
    // the index already normalises, so the split is done the same way here.
    // The CLI names models without a vendor prefix; the pricing table keys on
    // one, hence `openai-`.
    nonisolated private static func cost(of usage: CodexEvent.Usage, model: String) -> Double {
        let total = max(0, usage.inputTokens ?? 0)
        let cacheRead = min(total, max(0, usage.cachedInputTokens ?? 0))
        let input = total - cacheRead
        let output = max(0, usage.outputTokens ?? 0) + max(0, usage.reasoningOutputTokens ?? 0)
        let p = SessionIndex.pricing(for: model.hasPrefix("openai-") ? model : "openai-" + model)
        return (Double(input) * p.input
            + Double(cacheRead) * p.cacheRead
            + Double(output) * p.output) / 1_000_000
    }
}
