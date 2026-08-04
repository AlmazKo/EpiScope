import Foundation

// Claude names a project directory after the session's working directory with
// every "/" replaced by "-": /Users/alex/prime-server → -Users-alex-prime-server.
//
// The encoding is lossy in one direction only. Encoding is what Claude itself
// does and is exact; decoding is a guess, because a path component that already
// contains a dash is indistinguishable from a separator — `-Users-alex-prime-server`
// reads back as /Users/alex/prime/server. Half of this machine's project dirs
// have a hyphen in the last component, so this is the common case, not an edge.
//
// What saves the lookup path is that `encode(decode(x)) == x`: a mis-decoded cwd
// still re-encodes to the directory it came from, so opening a transcript works
// even when the cwd we display is wrong. That is why the flaw stayed invisible.
// It follows that a decoded cwd is safe as a lookup key and unsafe as an
// identity: never compare it against an authoritative cwd (deepScan overwrites
// SessionIndexEntry.cwd with the one recorded inside the transcript), or the
// same project ends up as two different groups.
//
// This lived hand-written in six places, four encoding and two decoding. One
// home makes the asymmetry above statable in exactly one comment instead of
// none.
// nonisolated: the target defaults to MainActor isolation, and every caller
// here is a background pass (rebuildShallow, the chart's scan body).
nonisolated enum ClaudeProjectPath {
    // cwd → project directory name. Exact.
    static func encode(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    // Project directory name → best-effort cwd. Lossy on hyphens (see above).
    // Prefer SessionIndexEntry.cwd whenever an entry is at hand; this is for
    // the discovery pass, which meets the directory before it meets the entry.
    static func decode(_ directoryName: String) -> String {
        "/" + directoryName.split(separator: "-").joined(separator: "/")
    }

    // The transcript of one session under a projects root.
    static func transcript(sessionId: String, cwd: String, in root: URL) -> URL {
        root
            .appending(path: encode(cwd), directoryHint: .isDirectory)
            .appending(path: "\(sessionId).jsonl")
    }
}
