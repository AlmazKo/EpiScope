import Darwin
import Foundation

// Ending a session from the table — what `/exit` does from inside it.
//
// A pid is never an identity: session files are untrusted, pids are reused and
// a confirmation sheet may stay open indefinitely. The caller therefore keeps
// this kernel-backed snapshot and stop() requires the same process to still be
// behind the pid immediately before SIGTERM.
enum SessionControl {
    struct ProcessIdentity: Equatable, Sendable {
        let pid: Int
        let provider: SessionProvider
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
        let executablePath: String
        let arguments: [String]
    }

    enum StopOutcome {
        case stopped
        // The process is gone already, was replaced, or is not this provider's
        // CLI. Same safe answer in every case: nothing was signalled.
        case notRunning
        case failed
    }

    static func identity(pid: Int, provider: SessionProvider) -> ProcessIdentity? {
        guard pid > 1, provider.stoppableProcess != nil,
              let started = processStart(pid: pid),
              let executable = executablePath(pid: pid),
              let arguments = processArguments(pid: pid),
              commandRuns(arguments: arguments, executablePath: executable,
                          provider: provider)
        else { return nil }
        return ProcessIdentity(
            pid: pid, provider: provider,
            startedSeconds: started.seconds,
            startedMicroseconds: started.microseconds,
            executablePath: executable,
            arguments: arguments)
    }

    // Codex keeps its rollout open for the lifetime of the session. A direct
    // owner lookup is used only for an explicit destructive action, closing the
    // few-second gap before the periodic tracker publishes a newly started pid.
    static func identityOwningFile(_ url: URL, provider: SessionProvider) -> ProcessIdentity? {
        guard provider == .codex else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let identities = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) }
            .compactMap { identity(pid: $0, provider: provider) }
        return identities.count == 1 ? identities[0] : nil
    }

    @discardableResult
    static func stop(_ expected: ProcessIdentity) -> StopOutcome {
        guard identity(pid: expected.pid, provider: expected.provider) == expected
        else { return .notRunning }
        return Darwin.kill(pid_t(expected.pid), SIGTERM) == 0 ? .stopped : .failed
    }

    static func isRunning(_ expected: ProcessIdentity) -> Bool {
        identity(pid: expected.pid, provider: expected.provider) == expected
    }

    // Polls until that exact process is gone or the deadline passes. A reused
    // pid is an exit, not a reason to wait on somebody else's process.
    @MainActor
    static func waitForExit(_ expected: ProcessIdentity, timeout: TimeInterval,
                            completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard isRunning(expected) else { return completion(true) }
            guard Date() < deadline else { return completion(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
        }
        poll()
    }

    // Match argv structure, not an arbitrary word. Native CLIs are their own
    // executable. Claude's npm install is the supported wrapper exception:
    // node/bun launches a script whose argv[1] itself is named `claude`.
    nonisolated static func commandRuns(arguments: [String], executablePath: String,
                                         provider: SessionProvider) -> Bool {
        guard let program = provider.stoppableProcess else { return false }
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent
        if executable == program { return true }
        guard provider == .claude, ["node", "bun"].contains(executable),
              arguments.count > 1 else { return false }
        return URL(fileURLWithPath: arguments[1]).lastPathComponent == program
    }

    private static func processStart(pid: Int) -> (seconds: UInt64, microseconds: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size
        else { return nil }
        return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
    }

    private static func executablePath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // KERN_PROCARGS2 returns argc followed by the executable path and the
    // original NUL-delimited argv. Unlike `ps command`, spaces and quoting in a
    // path cannot turn one argument into several or manufacture a match.
    private static func processArguments(pid: Int) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0
        else { return nil }

        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func skipString() {
            while cursor < size, bytes[cursor] != 0 { cursor += 1 }
        }
        skipString() // executable path preceding argv
        while cursor < size, bytes[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        while cursor < size, arguments.count < Int(argc) {
            let start = cursor
            skipString()
            guard cursor > start,
                  let value = String(bytes: bytes[start..<cursor], encoding: .utf8)
            else { return nil }
            arguments.append(value)
            while cursor < size, bytes[cursor] == 0 { cursor += 1 }
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
