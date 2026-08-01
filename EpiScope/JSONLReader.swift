import Foundation

// Streams a .jsonl file line-by-line in bounded chunks, so callers parse and
// extract only what they need without ever holding the whole (multi-MB) file
// in memory. Each complete '\n'-terminated line is handed to `body` as its own
// Data; a trailing partial line (the writer mid-append, or a final record with
// no newline) is left unconsumed for the next incremental pass.
//
// Returns the absolute byte offset just past the last complete line — callers
// store it as their parse cursor and resume from there next time.
enum JSONLReader {
    static func stream(at url: URL, from offset: Int64 = 0,
                       chunkSize: Int = 1 << 18,
                       _ body: (Data) -> Void) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }

        var consumed = offset
        var buf = Data()
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return false
            }
            buf.append(chunk)
            var idx = buf.startIndex
            while let nl = buf[idx...].firstIndex(of: 0x0a) {
                let after = buf.index(after: nl)
                let line = buf[idx..<nl]
                if !line.isEmpty { body(Data(line)) }
                consumed += Int64(buf.distance(from: idx, to: after))
                idx = after
            }
            // Keep only the unparsed tail (partial line) for the next chunk.
            buf = idx < buf.endIndex ? Data(buf[idx...]) : Data()
            return true
        }) {}
        return consumed
    }
}
