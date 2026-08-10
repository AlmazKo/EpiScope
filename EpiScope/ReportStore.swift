import Foundation

// Analysis reports on disk: ~/Library/Application Support/EpiScope/
// reports/, one pair of files per report — a clean shareable .md (the
// agent's output, nothing prepended) and a .json sidecar with the run
// metadata. No master index: the folder holds tens of files at most, so
// list() is a plain dir scan, and there's nothing to corrupt.

nonisolated enum AnalysisType: String, Codable, CaseIterable, Sendable {
    case retro
    case question
    case insights
    case digest

    var displayName: String {
        switch self {
        case .retro: return "Retro"
        case .question: return "Question"
        case .insights: return "Insights"
        case .digest: return "Digest"
        }
    }
}

nonisolated struct AnalysisReport: Codable, Sendable {
    enum Status: String, Codable, Sendable { case completed, failed, cancelled }

    let id: String                 // UUID; fileBase is derived once on save
    var type: AnalysisType
    var createdAt: Date
    var title: String              // "Retro — EpiScope — Jul 3 14:02"
    var question: String?
    var scopeSessionIds: [String]
    var scopeCwd: String?
    var model: String
    var costUSD: Double?
    var agentSessionId: String?    // the analysis run's own session id
    var durationSec: Double?
    var numTurns: Int?
    var status: Status
    var errorSummary: String?
    var fileBase: String?          // shared basename of the .md/.json pair
}

@MainActor
final class ReportStore {
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/EpiScope/reports",
                   directoryHint: .isDirectory)

    // Sidecars are user-visible files — ISO dates over the index cache's
    // millisecond ints.
    nonisolated private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    func list() -> [AnalysisReport] {
        // Screenshot mode: staged runs, so Insights has something to show
        // without a real analysis run having ever happened on this machine.
        if DemoFleet.isEnabled { return DemoFleet.reports() }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.dir,
                                                      includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = Self.makeDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AnalysisReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                var report = try? decoder.decode(AnalysisReport.self, from: data)
                // Self-heal a hand-renamed pair: the sidecar's own basename
                // is authoritative for locating the .md next to it.
                report?.fileBase = url.deletingPathExtension().lastPathComponent
                return report
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func markdownURL(for report: AnalysisReport) -> URL? {
        report.fileBase.map { Self.dir.appending(path: "\($0).md") }
    }

    func markdown(for report: AnalysisReport) -> String? {
        if DemoFleet.isEnabled { return DemoFleet.markdown(for: report) }
        guard let url = markdownURL(for: report) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Returns the saved report with fileBase filled in.
    @discardableResult
    func save(_ report: AnalysisReport, markdown: String) -> AnalysisReport {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)

        var saved = report
        if saved.fileBase == nil {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            var base = "\(stamp.string(from: report.createdAt))-\(report.type.rawValue)"
            if let slug = Self.slug(for: report) { base += "-\(slug)" }
            saved.fileBase = base
        }
        let base = saved.fileBase!

        try? markdown.write(to: Self.dir.appending(path: "\(base).md"),
                            atomically: true, encoding: .utf8)
        if let data = try? Self.makeEncoder().encode(saved) {
            try? data.write(to: Self.dir.appending(path: "\(base).json"),
                            options: .atomic)
        }
        // Let the main window refresh its unread Insights badge.
        NotificationCenter.default.post(name: .insightsReportsChanged, object: nil)
        return saved
    }

    func delete(_ report: AnalysisReport) {
        guard let base = report.fileBase else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: Self.dir.appending(path: "\(base).md"))
        try? fm.removeItem(at: Self.dir.appending(path: "\(base).json"))
    }

    nonisolated private static func slug(for report: AnalysisReport) -> String? {
        let source = report.scopeCwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? report.question
        guard let source else { return nil }
        let cleaned = source.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch != "-" || acc.last != "-" { acc.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(24))
    }
}
