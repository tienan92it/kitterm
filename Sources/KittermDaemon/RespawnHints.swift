import Foundation
import NIOConcurrencyHelpers

/// What a pane's shell keeps when the daemon that owned it is gone: its name
/// and its labels.
///
/// A daemon restart closes every PTY. Each browser pane reconnects with the
/// session id it had, finds nothing, and gets a fresh shell with a fresh id.
/// The name and labels lived only in the old process, so a foreman that
/// adopted `crew:alpha` sessions would find a fleet of anonymous shells. The
/// registry records them here as they change, and the pane's respawn reads
/// them back, so `list_sessions label="crew:alpha"` still answers after a
/// restart — with new ids, which is the part the epoch on `/api/events` tells
/// the foreman about.
public struct RespawnHints: Sendable, Equatable {
    public let name: String?
    public let labels: SessionLabels

    public init(name: String?, labels: SessionLabels) {
        self.name = name
        self.labels = labels
    }
}

/// One JSON file under the state directory, keyed by session id. Small: only
/// sessions with a name or a label are recorded, an entry is dropped when its
/// session is removed or respawned, and the file is capped at `maxEntries`
/// (oldest first) so panes that never come back cannot grow it forever.
///
/// Called from the registry actor, which is off the event loop, so the
/// synchronous writes never stall a connection. Lock-guarded anyway: the cost
/// is nothing and it makes the class safe to hand elsewhere.
public final class RespawnHintStore: @unchecked Sendable {
    public static let formatVersion = 1
    public static let maxEntries = 256

    private struct Entry: Codable {
        var name: String?
        var labels: [String: String]
        /// Epoch seconds, for the oldest-first cap.
        var at: Double
    }

    private struct FileShape: Codable {
        var version: Int
        var sessions: [String: Entry]
    }

    private let file: URL
    private let lock = NIOLock()
    private var entries: [String: Entry]

    public init(file: URL) {
        self.file = file
        self.entries = Self.load(file)
    }

    /// Remember a session's name and labels; forget it when both are empty.
    public func record(id: UUID, name: String?, labels: SessionLabels) {
        lock.withLock {
            if name == nil, labels.isEmpty {
                guard entries.removeValue(forKey: id.uuidString) != nil else { return }
            } else {
                entries[id.uuidString] = Entry(name: name, labels: labels.values, at: Date().timeIntervalSince1970)
                if entries.count > Self.maxEntries {
                    let excess = entries.count - Self.maxEntries
                    for key in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(excess).map(\.key) {
                        entries.removeValue(forKey: key)
                    }
                }
            }
            persistLocked()
        }
    }

    /// The session is gone for good (reaped, killed, archived).
    public func forget(id: UUID) {
        lock.withLock {
            guard entries.removeValue(forKey: id.uuidString) != nil else { return }
            persistLocked()
        }
    }

    /// Read and drop a session's hints — a respawn consumes them.
    public func take(id: UUID) -> RespawnHints? {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: id.uuidString) else { return nil }
            persistLocked()
            return RespawnHints(name: entry.name, labels: SessionLabels(entry.labels))
        }
    }

    public var count: Int { lock.withLock { entries.count } }

    private static func load(_ file: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: ignoring \(file.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return [:]
            }
            return shape.sessions
        } catch {
            FileHandle.standardError.write(Data("kitterm: ignoring \(file.path): \(error)\n".utf8))
            return [:]
        }
    }

    /// Caller holds `lock`.
    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(FileShape(version: Self.formatVersion, sessions: entries))
            try data.write(to: file, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("kitterm: cannot write \(file.path): \(error)\n".utf8))
        }
    }
}
