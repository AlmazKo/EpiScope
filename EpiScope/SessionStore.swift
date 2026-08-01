import Foundation

// Single decode authority for ~/.claude/sessions/<pid>.json.
//
// Claude Code rewrites these files on every status change, but the directory
// is tiny (one file per live session). Both the SessionMonitor (1 s, main
// thread) and the TerminalTracker (1 s, background) need the decoded
// contents on every tick — re-reading and JSON-decoding all of them on each
// poll, from two threads, was a measurable chunk of idle CPU.
//
// SessionStore decodes each file at most once per change: it stats every file
// and reuses the cached SessionInfo whenever (mtime, size) is unchanged, so a
// poll where nothing moved is just a readdir + one stat per file. Safe to call
// from any thread.
final class SessionStore {
    static let shared = SessionStore()

    private let dirPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/sessions", directoryHint: .isDirectory).path
    private let lock = NSLock()
    private let decoder = JSONDecoder()

    private struct Cached {
        let mtime: Date
        let size: Int64
        let info: SessionInfo
    }
    private var cache: [String: Cached] = [:]   // filename -> last decode

    // The currently-live session files, decoded. Only files whose (mtime,
    // size) changed since the last call are re-read and re-decoded; the rest
    // come from the cache. Removed files fall out of the cache automatically.
    func sessions() -> [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else {
            cache.removeAll()
            return []
        }
        var next: [String: Cached] = [:]
        next.reserveCapacity(names.count)
        var out: [SessionInfo] = []
        for name in names where name.hasSuffix(".json") {
            let path = dirPath + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.int64Value
            else { continue }
            if let c = cache[name], c.mtime == mtime, c.size == size {
                next[name] = c
                out.append(c.info)
                continue
            }
            guard let data = fm.contents(atPath: path),
                  let info = try? decoder.decode(SessionInfo.self, from: data)
            else { continue }
            let c = Cached(mtime: mtime, size: size, info: info)
            next[name] = c
            out.append(info)
        }
        cache = next
        return out
    }
}
