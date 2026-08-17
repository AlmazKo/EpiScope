import XCTest
@testable import EpiScope

final class SessionControlTests: XCTestCase {
    func testProviderNameInUnrelatedArgumentDoesNotValidateProcess() {
        XCTAssertFalse(SessionControl.commandRuns(
            arguments: ["/usr/bin/python3", "/tmp/codex", "--serve"],
            executablePath: "/usr/bin/python3", provider: .codex))
        XCTAssertFalse(SessionControl.commandRuns(
            arguments: ["/usr/local/bin/node", "server.js", "/tmp/claude"],
            executablePath: "/usr/local/bin/node", provider: .claude))
        XCTAssertFalse(SessionControl.commandRuns(
            arguments: ["/tmp/codex", "resume", "abc"],
            executablePath: "/usr/bin/python3", provider: .codex))
    }

    func testNativeAndSupportedNodeEntrypointsValidate() {
        XCTAssertTrue(SessionControl.commandRuns(
            arguments: ["/opt/homebrew/bin/codex", "resume", "abc"],
            executablePath: "/opt/homebrew/bin/codex", provider: .codex))
        XCTAssertTrue(SessionControl.commandRuns(
            arguments: ["/opt/homebrew/bin/node", "/Users/me/.local/bin/claude", "--resume"],
            executablePath: "/opt/homebrew/bin/node", provider: .claude))
    }
}

final class SessionIndexParsingTests: XCTestCase {
    func testClearRequiresTheExactAttachmentShape() throws {
        let real = Data(#"{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"SessionStart","hookName":"SessionStart:clear"}}"#.utf8)
        let nested = Data(#"{"type":"user","toolUseResult":{"hookName":"SessionStart:clear"}}"#.utf8)
        let quoted = Data(#"{"type":"user","message":{"content":"{\"hookName\":\"SessionStart:clear\"}"}}"#.utf8)
        XCTAssertTrue(SessionIndexer.isClearStartRecord(real))
        XCTAssertFalse(SessionIndexer.isClearStartRecord(nested))
        XCTAssertFalse(SessionIndexer.isClearStartRecord(quoted))
    }

    func testPromptPreviewRejectsUnknownMachineEnvelope() {
        let wrapper = Data(#"{"type":"user","userType":"external","message":{"content":"<future-provider-wrapper>machine text</future-provider-wrapper>"}}"#.utf8)
        let typed = Data(#"{"type":"user","userType":"external","promptSource":"typed","message":{"content":"  Fix the totals row\nplease  "}}"#.utf8)
        XCTAssertNil(SessionIndexer.promptPreview(in: wrapper))
        XCTAssertEqual(SessionIndexer.promptPreview(in: typed), "Fix the totals row please")
    }

    func testHeadUuidPastFormer256KBoundaryIsFound() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let prelude = #"{"type":"attachment","attachment":{"content":""#
            + String(repeating: "x", count: 300_000) + #""}}"# + "\n"
        let user = #"{"type":"user","uuid":"head-uuid","message":{"content":"hello"}}"# + "\n"
        try Data((prelude + user).utf8).write(to: url)
        XCTAssertEqual(SessionIndexer.readHeadUuid(at: url.path), "head-uuid")
    }

    func testForkUsageIncludesMessagesAndPatchLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = [
            #"{"type":"assistant","uuid":"a1","requestId":"r1","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}"#,
            #"{"type":"user","uuid":"u1","message":{"content":"hello"}}"#,
            #"{"type":"user","uuid":"p1","toolUseResult":{"type":"update","structuredPatch":[{"lines":["+one","-two"," same"]}]}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(records.utf8).write(to: url)

        let usage = SessionIndexer.forkUsage(at: url.path)
        XCTAssertEqual(usage["a:r1"]?.input, 10)
        XCTAssertEqual(usage["a:r1"]?.turns, 1)
        XCTAssertEqual(usage["u:u1"]?.userMessages, 1)
        XCTAssertEqual(usage["u:p1"]?.linesAdded, 1)
        XCTAssertEqual(usage["u:p1"]?.linesRemoved, 1)
    }

    func testForkUsageDoesNotCountToolResultAsHumanMessage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let record = #"{"type":"user","uuid":"tool-result","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"ok"}]}}"# + "\n"
        try Data(record.utf8).write(to: url)

        XCTAssertNil(SessionIndexer.forkUsage(at: url.path)["u:tool-result"])
    }

    func testOldInheritedUsageDecodesWithoutNewCounters() throws {
        let old = Data(#"{"familyKey":"a,b","from":"a","input":1,"cacheCreation":2,"cacheRead":3,"output":4,"turns":1}"#.utf8)
        let usage = try JSONDecoder().decode(InheritedUsage.self, from: old)
        XCTAssertEqual(usage.userMessages ?? 0, 0)
        XCTAssertEqual(usage.linesAdded ?? 0, 0)
        XCTAssertEqual(usage.linesRemoved ?? 0, 0)
    }

    func testOldIndexKeepsRealCodexRowsVisibleWhileRebuilding() throws {
        let conversation = SessionIndexEntry(
            sessionId: "conversation", cwd: "/tmp/project", provider: .codex,
            title: nil, name: nil, model: "openai-gpt-5", inputTokens: 1,
            userMessageCount: 1, lastGitBranch: nil,
            fileModified: .distantPast, fileSize: 10)
        let metadata = SessionIndexEntry(
            sessionId: "metadata", cwd: "/tmp/project", provider: .codex,
            title: nil, name: nil, model: nil, userMessageCount: 0,
            lastGitBranch: nil, fileModified: .distantPast, fileSize: 10)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(
            SessionIndex(version: 22, entries: [conversation, metadata]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded = try decoder.decode(SessionIndex.self, from: data)
        let loaded = SessionIndexer.prepareLoadedIndex(decoded)

        XCTAssertTrue(loaded.requiresRebuild)
        XCTAssertEqual(loaded.entries[0].codexContentState, .conversation)
        XCTAssertFalse(loaded.entries[0].isMetadataOnlyCodex)
        XCTAssertEqual(loaded.entries[1].codexContentState, .metadataOnly)
        XCTAssertTrue(loaded.entries[1].isMetadataOnlyCodex)
    }
}

final class SchedulingAndDateTests: XCTestCase {
    func testCodexDoesNotTriggerChildProcessTableWalk() {
        let codex = SessionInfo(pid: 42, sessionId: "codex", cwd: "/tmp",
                                status: nil, waitingFor: nil, updatedAt: nil,
                                entrypoint: "codex")
        let sdk = SessionInfo(pid: 43, sessionId: "sdk", cwd: "/tmp",
                              status: nil, waitingFor: nil, updatedAt: nil,
                              entrypoint: "sdk-cli")
        XCTAssertFalse(TerminalTracker.needsChildAgeScan([codex]))
        XCTAssertTrue(TerminalTracker.needsChildAgeScan([codex, sdk]))
    }

    func testTwoDayTickStaysAtMidnightAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let config = TokenChartView.WindowConfig(days: 30)
        for components in [
            DateComponents(year: 2026, month: 3, day: 10, hour: 0),
            DateComponents(year: 2026, month: 11, day: 3, hour: 0),
        ] {
            let start = try XCTUnwrap(calendar.date(from: components))
            let prior = try XCTUnwrap(config.previousTick(before: start, calendar: calendar))
            XCTAssertEqual(calendar.component(.hour, from: prior), 0)
            XCTAssertEqual(calendar.dateComponents([.day], from: prior, to: start).day, 2)
        }
    }

    func testParkedAndClearedSessionsSharePresentationSuppression() {
        XCTAssertEqual(
            SessionMonitor.suppressionSet(
                cleared: ["cleared"], parkedInto: ["parked": "continuation"]),
            ["cleared", "parked"])
    }

    func testRestartedSessionChangesItsLiveProcessBinding() {
        let old = SessionInfo(pid: 41, sessionId: "same", cwd: "/tmp/project",
                              status: nil, waitingFor: nil, updatedAt: nil,
                              entrypoint: "codex")
        let restarted = SessionInfo(pid: 42, sessionId: "same", cwd: "/tmp/project",
                                    status: nil, waitingFor: nil, updatedAt: nil,
                                    entrypoint: "codex")
        XCTAssertFalse(SessionMonitor.sameProcessBindings(
            ["same": old], ["same": restarted]))
    }
}

final class PromptLibraryTests: XCTestCase {
    func testEmptyOverrideIsRejected() {
        XCTAssertFalse(PromptLibrary.isValidOverride("  \n\t"))
        XCTAssertTrue(PromptLibrary.isValidOverride("{{CATALOG}}"))
        XCTAssertNil(PromptLibrary.usableOverride(" \n"))
        XCTAssertEqual(PromptLibrary.usableOverride("valid"), "valid")
    }
}
