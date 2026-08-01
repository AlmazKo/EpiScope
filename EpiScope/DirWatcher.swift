import CoreServices
import Foundation

// Thin FSEvents wrapper: fires `onChange` (coalesced, on a background queue)
// whenever anything under the watched directory trees is created, modified or
// removed. We use it as a "something moved" doorbell so the indexer can skip
// its file walk entirely when nothing has changed, instead of re-stat'ing
// hundreds of transcripts every second.
final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "episcope.dirwatcher", qos: .utility)

    // `paths` that don't exist are dropped; returns nil-ish (no stream) if none
    // remain, in which case the owner just falls back to its safety-net poll.
    init?(paths: [String], latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        self.onChange = onChange

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil, callback, &ctx, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
