import Foundation

// A session as intervals instead of messages: where the wall clock went
// between the first prompt and the last record — the agent working, a stall
// waiting on somebody, the long silence before the session was picked up
// again — plus the moments worth seeing on that axis (errors, interrupts,
// compactions, edits). Drawn as a strip under the per-session token chart, on
// the same time domain, so behaviour and cost read against one another.
//
// The phases come from record timestamps; the permission ones do not, and
// cannot. No provider writes down "the user was asked for permission and took
// six minutes to answer", and a transcript cannot tell an approval prompt from
// a slow `npm test` — both are a minute with nothing written. So a stall
// inside a turn stays part of Working rather than being guessed at, and
// Permission is painted only from intervals `SessionMonitor` watched happen.
// A session that ran before EpiScope kept those segments shows Working, Idle
// and Away only, which is the whole truth available about it.
//
// Idle past `awayThreshold` is Away, and the prompt that ends it carries a
// Resumed mark. Claude Code appends a resumed session to the same transcript
// with no record of the gap, so a long silence is the only evidence there was
// one. Codex writes a fresh `session_meta` instead, and that one is exact.
nonisolated struct SessionTimeline: Sendable {
    // Idle past this is not "the human is reading the answer" — the session
    // was parked, and whatever comes next is a resume.
    static let awayThreshold: TimeInterval = 20 * 60

    enum Phase: Sendable, Equatable {
        case working
        case permission   // recorded by EpiScope while the prompt was open
        case idle
        case away
    }

    struct Span: Sendable {
        let phase: Phase
        let start: Date
        let end: Date
        var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    enum Event: Sendable, Equatable {
        case error
        case interrupt
        case compact
        case resume
        case edit(lines: Int)
    }

    struct Mark: Sendable {
        let event: Event
        let at: Date
    }

    // The curves the strip sits under. Read from the same whole-file pass, not
    // from the viewer's 4 MB tail: a 39 MB session would otherwise draw a month
    // of phases against ten percent of a curve, and the curve's cumulative
    // totals would restart at the tail boundary instead of at the session's.
    // Series are combined the way the table combines them — cache creation
    // bills like input, cached reads keep their own line.
    struct UsagePoint: Sendable {
        let at: Date
        let input: Int64
        let cacheRead: Int64
        let output: Int64
    }

    var spans: [Span] = []
    var marks: [Mark] = []
    var usage: [UsagePoint] = []
    var userMessages: [Date] = []
    var assistantMessages: [Date] = []

    var isEmpty: Bool { spans.isEmpty }
    var start: Date? { spans.first?.start }
    var end: Date? { spans.last?.end }

    func total(_ phase: Phase) -> TimeInterval {
        spans.reduce(0) { $0 + ($1.phase == phase ? $1.duration : 0) }
    }

    func count(_ event: Event) -> Int {
        marks.reduce(0) { $0 + ($1.event == event ? 1 : 0) }
    }

    var editCount: Int {
        marks.reduce(0) { sum, mark in
            if case .edit = mark.event { return sum + 1 }
            return sum
        }
    }
}

// MARK: - Building

extension SessionTimeline {
    // Whole-file, not the viewer's tail: the strip is about how the session
    // spent its hours, and JSONLReader streams in bounded chunks either way.
    // Only the lines whose byte signature matches are decoded, the way
    // SessionIndexer.foldUsage does it — a megabyte of tool output never
    // reaches JSONDecoder.
    // `permissionWaits` comes from SessionMonitor, which is main-actor state —
    // the caller reads it before hopping off, so the scan itself needs nothing
    // but the file.
    static func build(for entry: SessionIndexEntry,
                      permissionWaits: [(start: Date, end: Date)]) -> SessionTimeline {
        if DemoFleet.isEnabled {
            return build(fromEvents: DemoFleet.transcript(for: entry))
        }
        guard let url = SessionIndexer.transcriptURL(for: entry) else { return SessionTimeline() }
        var raw = Raw()
        switch entry.provider {
        case .claude:        scanClaude(url, into: &raw)
        case .codex:         scanCodex(url, into: &raw)
        case .claudeDesktop: scanClaudeDesktop(url, into: &raw)
        }
        return assemble(raw, permissionWaits: permissionWaits)
    }

    // Screenshot mode has no transcript on disk — derive everything from the
    // staged conversation so details mode still looks like details mode.
    static func build(fromEvents events: [SessionIndexer.TranscriptEvent]) -> SessionTimeline {
        var raw = Raw()
        for event in events {
            guard let at = event.timestamp else { continue }
            raw.activity.append(at)
            switch event.kind {
            case .user:      raw.prompts.append(at)
            case .assistant: raw.assistantMessages.append(at)
            case .usage:     break
            }
            if let input = event.cumInput, let write = event.cumCacheWrite,
               let read = event.cumCacheRead, let output = event.cumOutput {
                raw.usage.append(UsagePoint(at: at, input: input + write,
                                            cacheRead: read, output: output))
            }
        }
        return assemble(raw, permissionWaits: [])
    }

    // What a scan collects: turn starts, everything that proves the session
    // was alive at a moment, the provider's own turn-end receipts, and the
    // point events. Assembly is shared — only the parsing is per-provider.
    private struct Raw {
        var prompts: [Date] = []
        var activity: [Date] = []
        var turnEnds: [Date] = []
        var marks: [Mark] = []
        var usage: [UsagePoint] = []
        var assistantMessages: [Date] = []
    }

    private static func assemble(_ raw: Raw,
                                 permissionWaits: [(start: Date, end: Date)]) -> SessionTimeline {
        let activity = raw.activity.sorted()
        let turnEnds = raw.turnEnds.sorted()
        var prompts = raw.prompts.sorted()
        // The curves and markers stand on their own: a transcript with usage
        // but no discernible turn still draws a chart.
        var chart = SessionTimeline()
        chart.usage = raw.usage.sorted { $0.at < $1.at }
        chart.userMessages = prompts
        chart.assistantMessages = raw.assistantMessages.sorted()
        chart.marks = raw.marks.sorted { $0.at < $1.at }

        // A transcript can carry no typed prompt at all — an SDK run, or one
        // driven entirely by a slash command. Treat its first record as the
        // start of a turn so the strip still has something to say.
        if prompts.isEmpty, let first = activity.first { prompts = [first] }
        guard !prompts.isEmpty else { return chart }

        var spans: [Span] = []
        var marks = raw.marks
        var cursor = 0
        var endCursor = 0

        for (i, promptTime) in prompts.enumerated() {
            let nextPrompt = i + 1 < prompts.count ? prompts[i + 1] : Date.distantFuture
            // Everything written between this prompt and the next belongs to
            // its turn: the model's records, its tools', and the receipt.
            while cursor < activity.count, activity[cursor] < promptTime { cursor += 1 }
            let from = cursor
            while cursor < activity.count, activity[cursor] < nextPrompt { cursor += 1 }
            let inTurn = activity[from..<cursor]

            while endCursor < turnEnds.count, turnEnds[endCursor] < promptTime { endCursor += 1 }
            var declaredEnd: Date?
            var probe = endCursor
            while probe < turnEnds.count, turnEnds[probe] < nextPrompt {
                declaredEnd = turnEnds[probe]
                probe += 1
            }
            let end = max(declaredEnd ?? .distantPast, inTurn.last ?? promptTime)
            if end > promptTime {
                spans.append(Span(phase: .working, start: promptTime, end: end))
            }

            guard nextPrompt != .distantFuture, nextPrompt > end else { continue }
            let gap = nextPrompt.timeIntervalSince(end)
            spans.append(Span(phase: gap > awayThreshold ? .away : .idle,
                              start: end, end: nextPrompt))
            if gap > awayThreshold { marks.append(Mark(event: .resume, at: nextPrompt)) }
        }

        chart.spans = overlay(spans, with: permissionWaits)
        chart.marks = marks.sorted { $0.at < $1.at }
        return chart
    }

    // Repaint the intervals EpiScope actually watched: a recorded wait cuts
    // whatever span it lands in and takes that slice for itself. Recorded
    // waits are sequential per session, so they never overlap each other.
    //
    // A wait is split at SessionMonitor.waitCap the same way its totals are —
    // up to the cap somebody was blocked on the dialog, past it the prompt was
    // simply left sitting — so the strip and the table's Waited column cannot
    // disagree about the same minutes.
    private static func overlay(_ spans: [Span],
                                with waits: [(start: Date, end: Date)]) -> [Span] {
        guard !waits.isEmpty else { return spans }
        var out: [Span] = []
        for span in spans {
            var pieces = [span]
            for wait in waits {
                let capped = min(wait.end, wait.start.addingTimeInterval(SessionMonitor.waitCap))
                var next: [Span] = []
                for piece in pieces {
                    let from = max(piece.start, wait.start)
                    let to = min(piece.end, wait.end)
                    guard from < to else { next.append(piece); continue }
                    if piece.start < from {
                        next.append(Span(phase: piece.phase, start: piece.start, end: from))
                    }
                    if from < capped {
                        next.append(Span(phase: .permission, start: from, end: min(to, capped)))
                    }
                    if to > capped {
                        next.append(Span(phase: .away, start: max(from, capped), end: to))
                    }
                    if to < piece.end {
                        next.append(Span(phase: piece.phase, start: to, end: piece.end))
                    }
                }
                pieces = next
            }
            out.append(contentsOf: pieces)
        }
        return out
    }
}

// MARK: - Per-provider parsing

extension SessionTimeline {
    private struct ClaudeRecord: Decodable {
        let subtype: String?
        let timestamp: String?
        let isMeta: Bool?
        // Claude Code emits several assistant records per API call, each
        // carrying the FULL usage for that call. Summing them all inflates the
        // curves 1.7-2.3× against the table, which dedupes the same way.
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let content: Content?
            let usage: Usage?
            enum Content: Decodable {
                case text(String)
                case blocks([Block])
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let s = try? c.decode(String.self) { self = .text(s); return }
                    self = .blocks((try? c.decode([Block].self)) ?? [])
                }
            }
            struct Block: Decodable { let type: String? }
            struct Usage: Decodable {
                let inputTokens: Int64?
                let cacheCreationInputTokens: Int64?
                let cacheReadInputTokens: Int64?
                let outputTokens: Int64?
            }
        }

        // A typed prompt carries prose; a tool-result echo carries only
        // tool_result blocks, and an attachment only an image. The same test
        // picks the assistant records that said something to the human.
        var hasPromptText: Bool {
            switch message?.content {
            case let .text(s):
                return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .blocks(blocks):
                return blocks.contains { $0.type == "text" }
            case nil:
                return false
            }
        }
    }

    // Edit / Write results, decoded only when the line carries a patch — a
    // third twin of SessionIndexer.PatchLine, which counts the same +/- lines
    // for the table but has no use for when they landed.
    private struct ClaudePatchLine: Decodable {
        let toolUseResult: Result?
        struct Result: Decodable {
            let type: String?
            let content: String?
            let structuredPatch: [Hunk]?
            struct Hunk: Decodable { let lines: [String]? }
        }
    }

    private static func scanClaude(_ url: URL, into raw: inout Raw) {
        let userSig = Data(#""type":"user""#.utf8)
        let assistantSig = Data(#""type":"assistant""#.utf8)
        let systemSig = Data(#""type":"system""#.utf8)
        let toolResultSig = Data("toolUseResult".utf8)
        let patchSig = Data(#""structuredPatch""#.utf8)
        let toolErrorSig = Data(#""is_error":true"#.utf8)
        let apiErrorSig = Data(#""isApiErrorMessage":true"#.utf8)
        let interruptSig = Data("Request interrupted by user".utf8)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parser = TimestampParser()
        var counted: Set<String> = []
        var cumInput: Int64 = 0
        var cumCacheRead: Int64 = 0
        var cumOutput: Int64 = 0

        _ = JSONLReader.stream(at: url) { line in
            let isUser = line.range(of: userSig) != nil
            let isAssistant = !isUser && line.range(of: assistantSig) != nil
            let isSystem = !isUser && !isAssistant && line.range(of: systemSig) != nil
            guard isUser || isAssistant || isSystem,
                  let record = try? decoder.decode(ClaudeRecord.self, from: line),
                  let at = parser.date(from: record.timestamp)
            else { return }
            raw.activity.append(at)

            if isSystem {
                switch record.subtype {
                case "turn_duration":    raw.turnEnds.append(at)
                case "api_error":        raw.marks.append(Mark(event: .error, at: at))
                case "compact_boundary": raw.marks.append(Mark(event: .compact, at: at))
                default: break
                }
                return
            }
            if isAssistant {
                if line.range(of: apiErrorSig) != nil {
                    raw.marks.append(Mark(event: .error, at: at))
                }
                if record.hasPromptText { raw.assistantMessages.append(at) }
                let fresh = record.requestId.map { counted.insert($0).inserted } ?? true
                if fresh, let usage = record.message?.usage {
                    cumInput += (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                    cumCacheRead += usage.cacheReadInputTokens ?? 0
                    cumOutput += usage.outputTokens ?? 0
                    raw.usage.append(UsagePoint(at: at, input: cumInput,
                                                cacheRead: cumCacheRead, output: cumOutput))
                }
                return
            }
            // An interrupt is written as a user record but starts no turn.
            if line.range(of: interruptSig) != nil {
                raw.marks.append(Mark(event: .interrupt, at: at))
                return
            }
            if line.range(of: toolResultSig) != nil {
                if line.range(of: toolErrorSig) != nil {
                    raw.marks.append(Mark(event: .error, at: at))
                }
                if line.range(of: patchSig) != nil,
                   let lines = editedLines(line, decoder) {
                    raw.marks.append(Mark(event: .edit(lines: lines), at: at))
                }
                return
            }
            // isMeta records are Claude talking to itself — caveats, pasted
            // images, "Continue from where you left off." — not a human turn.
            if record.isMeta != true, record.hasPromptText { raw.prompts.append(at) }
        }
    }

    private static func editedLines(_ line: Data, _ decoder: JSONDecoder) -> Int? {
        guard let record = try? decoder.decode(ClaudePatchLine.self, from: line),
              let result = record.toolUseResult
        else { return nil }
        // Claude Code 2.1 stopped labelling Edit results: an update now carries
        // oldString / newString / structuredPatch and no `type` at all. Older
        // transcripts still say "update", so both shapes count.
        switch result.type {
        case "update", nil:
            let changed = (result.structuredPatch ?? []).reduce(0) { sum, hunk in
                sum + (hunk.lines ?? []).filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.count
            }
            return changed > 0 ? changed : nil
        case "create":
            guard let content = result.content, !content.isEmpty else { return nil }
            return content.utf8.lazy.filter { $0 == 0x0a }.count + 1
        default:
            // A Read echo or bash output that merely mentions structuredPatch.
            return nil
        }
    }

    private struct CodexRecord: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: TokenInfo?
            struct TokenInfo: Decodable { let totalTokenUsage: CodexTokenUsage? }
        }
    }

    private static func scanCodex(_ url: URL, into raw: inout Raw) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let parser = TimestampParser()
        var sawMeta = false

        _ = JSONLReader.stream(at: url) { line in
            guard let record = try? decoder.decode(CodexRecord.self, from: line),
                  let at = parser.date(from: record.timestamp)
            else { return }
            raw.activity.append(at)
            switch record.type {
            case "session_meta":
                // Codex writes a fresh session_meta every time a thread is
                // reopened, so every one after the first is an exact resume.
                if sawMeta { raw.marks.append(Mark(event: .resume, at: at)) }
                sawMeta = true
            case "event_msg":
                switch record.payload?.type {
                case "user_message":      raw.prompts.append(at)
                case "agent_message":     raw.assistantMessages.append(at)
                case "task_complete":     raw.turnEnds.append(at)
                case "token_count":
                    // Codex reports running totals, not per-response deltas.
                    if let breakdown = record.payload?.info?.totalTokenUsage?.breakdown {
                        raw.usage.append(UsagePoint(
                            at: at,
                            input: breakdown.input + breakdown.cacheWrite,
                            cacheRead: breakdown.cacheRead,
                            output: breakdown.output))
                    }
                case "turn_aborted":      raw.marks.append(Mark(event: .interrupt, at: at))
                case "context_compacted": raw.marks.append(Mark(event: .compact, at: at))
                // The rollout says a patch was applied, never how big it was.
                case "patch_apply_end":   raw.marks.append(Mark(event: .edit(lines: 0), at: at))
                default: break
                }
            default: break
            }
        }
    }

    // The audit spells its keys differently from every other transcript, so it
    // needs its own record and a decoder without the snake-case strategy.
    private struct DesktopRecord: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
        enum CodingKeys: String, CodingKey {
            case type
            case timestamp = "_audit_timestamp"
            case requestId = "request_id"
            case message
        }
        struct Message: Decodable {
            let content: ClaudeRecord.Message.Content?
            let usage: Usage?
            struct Usage: Decodable {
                let inputTokens: Int64?
                let cacheCreationInputTokens: Int64?
                let cacheReadInputTokens: Int64?
                let outputTokens: Int64?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case outputTokens = "output_tokens"
                }
            }
        }

        var hasText: Bool {
            switch message?.content {
            case let .text(s):
                return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .blocks(blocks):
                return blocks.contains { $0.type == "text" }
            case nil:
                return false
            }
        }
    }

    // The desktop audit is messages and nothing else: no tool records, no
    // system receipts, so the strip is turns and the silences between them.
    private static func scanClaudeDesktop(_ url: URL, into raw: inout Raw) {
        let decoder = JSONDecoder()
        let parser = TimestampParser()
        var counted: Set<String> = []
        var cumInput: Int64 = 0
        var cumCacheRead: Int64 = 0
        var cumOutput: Int64 = 0

        _ = JSONLReader.stream(at: url) { line in
            guard let record = try? decoder.decode(DesktopRecord.self, from: line),
                  let at = parser.date(from: record.timestamp)
            else { return }
            raw.activity.append(at)
            switch record.type {
            case "user":
                if record.hasText { raw.prompts.append(at) }
            case "assistant":
                if record.hasText { raw.assistantMessages.append(at) }
                let fresh = record.requestId.map { counted.insert($0).inserted } ?? true
                if fresh, let usage = record.message?.usage {
                    cumInput += (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                    cumCacheRead += usage.cacheReadInputTokens ?? 0
                    cumOutput += usage.outputTokens ?? 0
                    raw.usage.append(UsagePoint(at: at, input: cumInput,
                                                cacheRead: cumCacheRead, output: cumOutput))
                }
            default:
                break
            }
        }
    }

    // Claude writes fractional seconds, the desktop audit sometimes doesn't.
    // One instance per scan, reused across every line of it.
    private final class TimestampParser {
        private let fractional = ISO8601DateFormatter()
        private let plain = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(from string: String?) -> Date? {
            guard let string else { return nil }
            return fractional.date(from: string) ?? plain.date(from: string)
        }
    }
}
