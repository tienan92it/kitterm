import Foundation
import KittermDaemon

/// The opt-in local capture of `unknown` screens (`screen-state` capability
/// 5, `corpus/02-clef-decision.md`): when `screen_state` answers `unknown`
/// and the switch in `~/.kitterm/screen-state.json` is on, the bridge writes
/// the rendered screen text the rules saw to
/// `~/.kitterm/screen-unknown/<time>-<session>.txt`, so the missing rules
/// can be written from real samples. Off by default. The directory is
/// `0700`, each file `0600`, at most `maxFiles` files and `maxBytes` bytes
/// together, the oldest removed first. Nothing here is ever sent anywhere:
/// a captured screen can hold a secret the pane showed.
///
/// `capture` runs after the tool has answered (`MCPBridge.handleScreenState`)
/// and swallows every error, so a failed write never fails or delays the
/// call. The throwing halves exist for the tests and for the command.
enum ScreenStateCapture {
    static let maxFiles = 50
    static let maxBytes = 2 * 1024 * 1024

    // MARK: - the switch

    /// `{"captureUnknown": true|false}`. Off when the file is missing, is
    /// not readable, or does not hold that shape.
    struct Settings: Equatable {
        var captureUnknown: Bool

        static let off = Settings(captureUnknown: false)

        static func read(from url: URL = DaemonPaths.screenStateSettingsFile) -> Settings {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let on = object["captureUnknown"] as? Bool
            else { return .off }
            return Settings(captureUnknown: on)
        }

        /// Writes the file at `0600`, creating the state directory when it is
        /// missing. An existing file is replaced and keeps `0600`.
        func write(to url: URL = DaemonPaths.screenStateSettingsFile) throws {
            let data = try JSONSerialization.data(
                withJSONObject: ["captureUnknown": captureUnknown], options: [.sortedKeys]
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - one sample

    /// What one file holds: the header's facts and the screen's lines, the
    /// same `lines(styles: true)` the rules read.
    struct Sample: Equatable {
        let at: Date
        let session: String
        let state: ScreenState.Value
        let rule: String
        let foregroundProgram: String?
        let cols: Int
        let rows: Int
        let lines: [String]
    }

    static let headerTitle = "kitterm screen-unknown sample"

    /// The file's text: six header lines, one blank line, then the screen,
    /// one row per line.
    static func contents(of sample: Sample) -> String {
        var out = [
            headerTitle,
            "at: \(ScreenStateLog.isoFormatter().string(from: sample.at))",
            "session: \(sample.session)",
            "program: \(sample.foregroundProgram ?? "none")",
            "size: \(sample.cols)x\(sample.rows)",
            "rule: \(sample.rule)",
            "",
        ]
        out.append(contentsOf: sample.lines)
        return out.joined(separator: "\n") + "\n"
    }

    /// `<time>-<session>.txt`, the time in the ISO 8601 basic form in UTC
    /// (`20261022T071530.123Z`: no colon, so the name is plain on every file
    /// system, and it sorts by time). The session id is kept to the
    /// characters a UUID holds, so the name can never leave the directory.
    static func fileName(for sample: Sample) -> String {
        let session = sample.session.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            .map { String($0) }.joined()
        return "\(basicFormatter().string(from: sample.at))-\(session.isEmpty ? "session" : session).txt"
    }

    static func basicFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }

    // MARK: - the capture

    /// The bridge's call: nothing for a known state, nothing while the switch
    /// is off, else one file and a prune. Every error is swallowed, because
    /// the tool has already answered and that answer must not change.
    static func capture(
        _ sample: Sample,
        settingsFile: URL = DaemonPaths.screenStateSettingsFile,
        directory: URL = DaemonPaths.screenUnknownDirectory
    ) {
        guard sample.state == .unknown, Settings.read(from: settingsFile).captureUnknown else { return }
        _ = try? write(sample, in: directory)
    }

    /// Creates the directory at `0700` when it is missing, writes the file
    /// with `O_CREAT|O_EXCL` at `0600` (a second sample of the same session
    /// in the same millisecond gets a `-2` … `-9` suffix), then prunes.
    /// Returns the file written.
    @discardableResult
    static func write(_ sample: Sample, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let base = fileName(for: sample)
        let stem = String(base.dropLast(4))
        var candidates = [base]
        candidates.append(contentsOf: (2...9).map { "\(stem)-\($0).txt" })
        var fd: Int32 = -1
        var fileURL = directory.appendingPathComponent(base)
        for name in candidates {
            fileURL = directory.appendingPathComponent(name)
            fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 { break }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        guard fd >= 0 else { throw POSIXError(.EEXIST) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(contents(of: sample).utf8))
        try prune(in: directory)
        return fileURL
    }

    /// Removes the oldest files (by name, which starts with the time) while
    /// the directory holds more than `maxFiles` files or more than `maxBytes`
    /// bytes together. The newest file is never removed.
    static func prune(in directory: URL) throws {
        var entries = try samples(in: directory).reversed().map { $0 }  // oldest first
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        while entries.count > 1, entries.count > maxFiles || bytes > maxBytes {
            let oldest = entries.removeFirst()
            try FileManager.default.removeItem(at: oldest.url)
            bytes -= oldest.bytes
        }
    }

    // MARK: - reading back

    /// One sample file as `kitterm screen-state samples` lists it: the
    /// header's facts, read back from the file, and its size on disk.
    struct Entry: Equatable {
        let url: URL
        let at: Date?
        let session: String
        let program: String
        let size: String
        let bytes: Int

        var name: String { url.lastPathComponent }
    }

    /// Every `.txt` file of the directory, newest first; an empty list for
    /// a missing directory. A file whose header does not parse is listed
    /// with blank facts, never skipped: it still takes space the prune
    /// counts.
    static func samples(in directory: URL = DaemonPaths.screenUnknownDirectory) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".txt") }
            .sorted(by: >)
        return names.map { name in
            let url = directory.appendingPathComponent(name)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let header = headerFields(of: url)
            return Entry(
                url: url,
                at: header["at"].flatMap(ScreenStateLog.parseDate),
                session: header["session"] ?? "",
                program: header["program"] ?? "",
                size: header["size"] ?? "",
                bytes: bytes
            )
        }
    }

    /// The `key: value` lines before the first blank line, from the first
    /// 4 KiB of the file.
    static func headerFields(of url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return [:] }
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    /// Removes every sample. Returns how many were removed.
    @discardableResult
    static func clear(in directory: URL = DaemonPaths.screenUnknownDirectory) throws -> Int {
        let entries = try samples(in: directory)
        for entry in entries {
            try FileManager.default.removeItem(at: entry.url)
        }
        return entries.count
    }
}
