import Foundation

/// Writes a session's output to an asciinema v2 `.cast` file
/// (https://docs.asciinema.org/manual/asciicast/v2/) — replayable with
/// `asciinema play` or any web player.
final class SessionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kitterm.recorder", qos: .utility)
    private let handle: FileHandle
    /// When the cast began; every event's timestamp is relative to it.
    let startedAt: Date
    private var closed = false

    public let fileURL: URL

    /// Continue a cast another process began (live upgrade): append to the
    /// same file with the same origin, so the timestamps keep their base.
    init?(reopening url: URL, startedAt: Date) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        self.handle = handle
        self.startedAt = startedAt
        self.fileURL = url
    }

    /// Block until every write queued so far has reached the file. Only the
    /// takeover path calls this, from off the event loop, before `exec`
    /// destroys the queue's thread.
    func drain() {
        queue.sync {}
    }

    init?(directory: URL, cols: UInt16, rows: UInt16, shell: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(stamp)-\(UUID().uuidString.prefix(8)).cast"
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)
        } catch {
            return nil
        }
        self.fileURL = url
        self.startedAt = Date()

        let header: [String: Any] = [
            "version": 2,
            "width": Int(cols),
            "height": Int(rows),
            "timestamp": Int(Date().timeIntervalSince1970),
            "env": ["SHELL": shell, "TERM": "xterm-256color"],
        ]
        writeLine(json: header)
    }

    func recordOutput(_ data: Data) {
        let elapsed = Date().timeIntervalSince(startedAt)
        queue.async { [self] in
            guard !closed else { return }
            // Lossy decode: a chunk may split a multibyte sequence; asciinema
            // requires valid UTF-8 strings per event.
            let text = String(decoding: data, as: UTF8.self)
            writeEvent(elapsed, kind: "o", payload: text)
        }
    }

    func recordResize(cols: UInt16, rows: UInt16) {
        let elapsed = Date().timeIntervalSince(startedAt)
        queue.async { [self] in
            guard !closed else { return }
            writeEvent(elapsed, kind: "r", payload: "\(cols)x\(rows)")
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }

    private func writeLine(json: Any) {
        // Serialised here rather than on the queue: `Any` cannot cross into a
        // sendable closure, and doing the encoding at the call site keeps the
        // queue block carrying nothing but bytes.
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        queue.async { [self] in
            guard !closed else { return }
            handle.write(data)
            handle.write(Data([0x0a]))
        }
    }

    /// Runs on `queue`.
    private func writeEvent(_ elapsed: TimeInterval, kind: String, payload: String) {
        let event: [Any] = [(elapsed * 1_000_000).rounded() / 1_000_000, kind, payload]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}
