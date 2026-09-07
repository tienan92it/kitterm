import Foundation
import KittermProtocol

/// The state one daemon process hands to the next across `execv`
/// (`docs/live-upgrade.md`). The old binary writes it, the new binary reads
/// it, so the shape is versioned: `formatVersion` names the major layout, a
/// reader ignores fields it does not know, and a reader refuses a major
/// version it was not built for.
///
/// Only what cannot be rebuilt crosses the boundary: the PTY master fds, the
/// per-session records the ring and the marks hold, and the event feed's
/// identity. Sockets, observers, controllers, approval holds and waiters die
/// with the old process; clients reconnect and find their sessions.
public struct TakeoverState: Codable, Equatable, Sendable {
    /// The layout this file follows. A reader accepts exactly this value.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// The version of the binary that wrote the file, for the log line.
    public var writtenBy: String
    /// The fd numbers carried across `exec`, so a reader that refuses the
    /// rest of the file can still close them and boot clean.
    public var fds: [Int32]
    public var eventLog: EventLogState
    public var sessions: [SessionState]

    public init(
        formatVersion: Int = TakeoverState.currentFormatVersion,
        writtenBy: String,
        fds: [Int32],
        eventLog: EventLogState,
        sessions: [SessionState]
    ) {
        self.formatVersion = formatVersion
        self.writtenBy = writtenBy
        self.fds = fds
        self.eventLog = eventLog
        self.sessions = sessions
    }

    /// The feed's identity and its ring, so a foreman's cursor stays valid
    /// and `daemon.started` for the takeover lands inside the same epoch.
    public struct EventLogState: Codable, Equatable, Sendable {
        public var epoch: String
        public var lastSeq: UInt64
        public var events: [EventRecord]

        public init(epoch: String, lastSeq: UInt64, events: [EventRecord]) {
            self.epoch = epoch
            self.lastSeq = lastSeq
            self.events = events
        }
    }

    public struct EventRecord: Codable, Equatable, Sendable {
        public var seq: UInt64
        /// Epoch milliseconds.
        public var at: Int64
        public var type: String
        public var session: UUID?
        public var data: [String: String]

        public init(seq: UInt64, at: Int64, type: String, session: UUID?, data: [String: String]) {
            self.seq = seq
            self.at = at
            self.type = type
            self.session = session
            self.data = data
        }
    }

    public struct MarkRecord: Codable, Equatable, Sendable {
        public var offset: UInt64
        public var kind: UInt8
        public var exit: Int32?
        public var command: String?
        /// Epoch milliseconds.
        public var at: Int64

        public init(offset: UInt64, kind: UInt8, exit: Int32?, command: String?, at: Int64) {
            self.offset = offset
            self.kind = kind
            self.exit = exit
            self.command = command
            self.at = at
        }
    }

    public struct AgentStatusRecord: Codable, Equatable, Sendable {
        public var report: String
        public var message: String?
        /// Epoch milliseconds.
        public var at: Int64

        public init(report: String, message: String?, at: Int64) {
            self.report = report
            self.message = message
            self.at = at
        }
    }

    public struct RecorderState: Codable, Equatable, Sendable {
        public var path: String
        /// Epoch milliseconds; cast timestamps are relative to it.
        public var startedAt: Int64

        public init(path: String, startedAt: Int64) {
            self.path = path
            self.startedAt = startedAt
        }
    }

    public struct LogStoreState: Codable, Equatable, Sendable {
        public var path: String
        public var fileBase: UInt64
        public var streamEnd: UInt64

        public init(path: String, fileBase: UInt64, streamEnd: UInt64) {
            self.path = path
            self.fileBase = fileBase
            self.streamEnd = streamEnd
        }
    }

    public struct SessionState: Codable, Equatable, Sendable {
        /// The PTY master, or nil for a session whose shell already exited
        /// and that is kept only for its records.
        public var fd: Int32?
        public var sessionID: UUID
        public var pid: Int32
        public var shellPath: String
        public var initialCwd: String
        public var profileName: String?
        public var labels: [String: String]
        public var name: String?
        public var note: String?
        public var spawnedByAPI: Bool
        public var cols: UInt16
        public var rows: UInt16
        public var lastPolledCwd: String?
        public var submittedCommand: String?
        public var terminated: Bool
        public var shellExitCode: Int32?
        public var exitNotified: Bool
        public var detachOffset: UInt64
        /// The ring's absolute head; the ring file holds `[head - size, head)`.
        public var logHead: UInt64
        /// File name under the takeover directory's `rings/` holding the
        /// retained ring bytes, oldest first.
        public var ringFile: String
        public var marks: [MarkRecord]
        public var droppedCommands: Int
        /// Epoch milliseconds.
        public var lastOutputAt: Int64?
        public var agentStatus: AgentStatusRecord?
        public var recorder: RecorderState?
        public var logStore: LogStoreState?
        /// Epoch milliseconds; when the linger clock first held the session
        /// because it was working (ADR 0002).
        public var heldSince: Int64?

        public init(
            fd: Int32?,
            sessionID: UUID,
            pid: Int32,
            shellPath: String,
            initialCwd: String,
            profileName: String?,
            labels: [String: String],
            name: String?,
            note: String?,
            spawnedByAPI: Bool,
            cols: UInt16,
            rows: UInt16,
            lastPolledCwd: String?,
            submittedCommand: String?,
            terminated: Bool,
            shellExitCode: Int32?,
            exitNotified: Bool,
            detachOffset: UInt64,
            logHead: UInt64,
            ringFile: String,
            marks: [MarkRecord],
            droppedCommands: Int,
            lastOutputAt: Int64?,
            agentStatus: AgentStatusRecord?,
            recorder: RecorderState?,
            logStore: LogStoreState?,
            heldSince: Int64?
        ) {
            self.fd = fd
            self.sessionID = sessionID
            self.pid = pid
            self.shellPath = shellPath
            self.initialCwd = initialCwd
            self.profileName = profileName
            self.labels = labels
            self.name = name
            self.note = note
            self.spawnedByAPI = spawnedByAPI
            self.cols = cols
            self.rows = rows
            self.lastPolledCwd = lastPolledCwd
            self.submittedCommand = submittedCommand
            self.terminated = terminated
            self.shellExitCode = shellExitCode
            self.exitNotified = exitNotified
            self.detachOffset = detachOffset
            self.logHead = logHead
            self.ringFile = ringFile
            self.marks = marks
            self.droppedCommands = droppedCommands
            self.lastOutputAt = lastOutputAt
            self.agentStatus = agentStatus
            self.recorder = recorder
            self.logStore = logStore
            self.heldSince = heldSince
        }
    }

    public enum LoadError: Error, LocalizedError, Equatable {
        /// The file names a layout this binary does not read. Carries the
        /// fds it listed, so the caller can close them before it boots clean.
        case unsupportedFormat(found: Int, fds: [Int32])
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let found, _):
                return "takeover state is format \(found); this build reads format \(TakeoverState.currentFormatVersion)"
            case .unreadable(let detail):
                return "takeover state is unreadable: \(detail)"
            }
        }
    }

    /// The two fields every format carries, read first so a version this
    /// build refuses still gives up its fds.
    private struct Envelope: Decodable {
        var formatVersion: Int
        var fds: [Int32]?
    }

    public static let stateFileName = "state.json"
    public static let ringsDirectoryName = "rings"

    public static func stateFile(in directory: URL) -> URL {
        directory.appendingPathComponent(stateFileName)
    }

    public static func ringsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(ringsDirectoryName, isDirectory: true)
    }

    public func ringFile(for session: SessionState, in directory: URL) -> URL {
        Self.ringsDirectory(in: directory).appendingPathComponent(session.ringFile)
    }

    /// Write `state.json` into `directory`, creating it. The rings are written
    /// by the caller beside it, one file per session, before this is called.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: Self.ringsDirectory(in: directory),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.stateFile(in: directory), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.stateFile(in: directory).path
        )
    }

    /// Read `state.json` from `directory`; refuse a layout this build does not
    /// know. Unknown fields are ignored, which is what lets an older writer
    /// hand off to a newer reader.
    public static func load(from directory: URL) throws -> TakeoverState {
        let data: Data
        do {
            data = try Data(contentsOf: stateFile(in: directory))
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> TakeoverState {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        guard envelope.formatVersion == currentFormatVersion else {
            throw LoadError.unsupportedFormat(
                found: envelope.formatVersion,
                fds: envelope.fds ?? []
            )
        }
        do {
            return try decoder.decode(TakeoverState.self, from: data)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
    }
}

extension TakeoverState.EventRecord {
    init(_ event: DaemonEvent) {
        self.init(
            seq: event.seq,
            at: Int64(event.at.timeIntervalSince1970 * 1000),
            type: event.type,
            session: event.session,
            data: event.data
        )
    }

    var event: DaemonEvent {
        DaemonEvent(
            seq: seq,
            at: Date(timeIntervalSince1970: Double(at) / 1000),
            type: type,
            session: session,
            data: data
        )
    }
}

extension TakeoverState.MarkRecord {
    init(_ mark: SessionMark) {
        self.init(
            offset: mark.offset,
            kind: mark.kind.rawValue,
            exit: mark.exit,
            command: mark.command,
            at: Int64(mark.at.timeIntervalSince1970 * 1000)
        )
    }

    /// Nil for a kind this build does not know.
    var mark: SessionMark? {
        guard let kind = MarkKind(rawValue: kind) else { return nil }
        return SessionMark(
            offset: offset,
            kind: kind,
            exit: exit,
            command: command,
            at: Date(timeIntervalSince1970: Double(at) / 1000)
        )
    }
}

extension TakeoverState.AgentStatusRecord {
    init(_ status: AgentStatus) {
        self.init(
            report: status.report.rawValue,
            message: status.message,
            at: Int64(status.at.timeIntervalSince1970 * 1000)
        )
    }

    var status: AgentStatus? {
        guard let report = AgentReport(rawValue: report) else { return nil }
        return AgentStatus(
            report: report,
            message: message,
            at: Date(timeIntervalSince1970: Double(at) / 1000)
        )
    }
}
