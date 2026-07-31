import Foundation

/// Spills a session's output to disk so ranges older than the 4 MiB ring can
/// still be read — enough for someone scrolling a tab, not for a build log.
///
/// The file does not begin at stream offset zero: a shell prints before the
/// session has an id to name a file after. So the store records where it
/// started (`origin`) and translates; assuming otherwise returns wrong bytes
/// rather than none.
///
/// All I/O goes to a utility queue and is never awaited on the event loop, the
/// same discipline `SessionRecorder` uses.
final class SessionLogStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kitterm.logstore", qos: .utility)
    private let url: URL
    private let maxBytes: Int
    private var writeHandle: FileHandle?
    private var closed = false
    /// Stream offset of the first byte still on disk: where the store started,
    /// pushed forward by rotation.
    private var fileBase: UInt64
    /// Stream offset just past the last byte written.
    private var streamEnd: UInt64

    /// `origin` is the session's log head when the store is attached — the
    /// stream offset that lands at file position zero.
    init?(directory: URL, sessionID: UUID, maxBytes: Int, origin: UInt64) {
        self.fileBase = origin
        self.streamEnd = origin
        self.url = directory.appendingPathComponent("\(sessionID.uuidString).log")
        self.maxBytes = maxBytes
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            self.writeHandle = try FileHandle(forWritingTo: url)
        } catch {
            FileHandle.standardError.write(
                Data("kitterm: cannot retain logs for \(sessionID): \(error)\n".utf8)
            )
            return nil
        }
    }

    /// Called from the event loop; returns immediately.
    func append(_ data: Data) {
        queue.async { [self] in
            guard !closed, let handle = writeHandle else { return }
            handle.write(data)
            streamEnd += UInt64(data.count)
            if streamEnd - fileBase > UInt64(maxBytes) { rotate(handle: handle) }
        }
    }

    /// Drop the front half once the cap is hit. Halving rather than trimming
    /// exactly keeps these file rewrites rare.
    private func rotate(handle: FileHandle) {
        let keepFrom = streamEnd - UInt64(maxBytes / 2)
        do {
            let existing = try Data(contentsOf: url)
            let dropCount = Int(keepFrom - fileBase)
            guard dropCount > 0, dropCount < existing.count else { return }
            let kept = existing.suffix(from: dropCount)
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            handle.write(kept)
            fileBase = keepFrom
        } catch {
            // The cap is a courtesy to the disk, not a correctness property, so
            // a failed rotation must not stop the session.
            FileHandle.standardError.write(
                Data("kitterm: log rotation failed: \(error)\n".utf8)
            )
        }
    }

    /// Read `[from, to)` from disk, off the event loop. `completion` runs on the
    /// store's queue; the caller hops back to its own loop.
    func read(from: UInt64, to: UInt64, completion: @escaping (Data, UInt64) -> Void) {
        queue.async { [self] in
            guard !closed, to > from else { return completion(Data(), from) }
            let start = max(from, fileBase)
            guard to > start, let handle = try? FileHandle(forReadingFrom: url) else {
                return completion(Data(), start)
            }
            defer { try? handle.close() }
            do {
                // Stream offset → file position; the file may start mid-stream.
                try handle.seek(toOffset: start - fileBase)
                let data = try handle.read(upToCount: Int(to - start)) ?? Data()
                completion(data, start)
            } catch {
                completion(Data(), start)
            }
        }
    }

    /// Retained output should not outlive the shell that produced it.
    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            try? writeHandle?.close()
            writeHandle = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}
