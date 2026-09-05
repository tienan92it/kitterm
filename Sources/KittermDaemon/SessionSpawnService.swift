import Foundation
import KittermProtocol
import NIOCore

/// The one spawn path, shared by the WebSocket handler (a browser tab) and the
/// HTTP route (`POST /api/sessions`, a program). Both go through the same
/// steps in the same order: resolve the profile, spawn the PTY, queue initial
/// input as type-ahead, attach the recorder, start the reader, admit to the
/// registry, attach the log store. Only the admission differs: a tab is
/// attached from birth, an API session starts detached with its linger clock
/// already running.
public final class SessionSpawnService: @unchecked Sendable {
    public struct Request {
        /// Requested working directory, raw. Validated here — an unknown or
        /// non-directory path falls back to the profile's cwd, then home.
        public var cwd: String?
        /// Per-pane history key (`?hist=`); browser panes only.
        public var histKey: String?
        /// Named session profile; unknown names fail the spawn loudly.
        public var profileName: String?
        public var labels: SessionLabels
        public var name: String?
        public var note: String?
        public var cols: UInt16
        public var rows: UInt16
        /// Bytes typed into the shell at its first read (after any profile
        /// command), so `{"input":"claude\n"}` spawns an agent in one call.
        public var initialInput: Data?
        /// True when this session was created over the HTTP API.
        public var spawnedByAPI: Bool

        public init(
            cwd: String? = nil,
            histKey: String? = nil,
            profileName: String? = nil,
            labels: SessionLabels = SessionLabels(),
            name: String? = nil,
            note: String? = nil,
            cols: UInt16 = KittermConstants.defaultCols,
            rows: UInt16 = KittermConstants.defaultRows,
            initialInput: Data? = nil,
            spawnedByAPI: Bool = false
        ) {
            self.cwd = cwd
            self.histKey = histKey
            self.profileName = profileName
            self.labels = labels
            self.name = name
            self.note = note
            self.cols = cols
            self.rows = rows
            self.initialInput = initialInput
            self.spawnedByAPI = spawnedByAPI
        }
    }

    public enum SpawnFailure: Error, LocalizedError {
        case unknownProfile(String)
        case atCapacity

        public var errorDescription: String? {
            switch self {
            case .unknownProfile(let name):
                return "unknown profile: \(name)"
            case .atCapacity:
                return """
                    too many sessions open \
                    (limit \(KittermConstants.maxConcurrentSessions)); \
                    close one or delete an idle session
                    """
            }
        }
    }

    private let registry: SessionRegistry
    private let recordSessions: Bool
    private let retainLogs: Bool

    public init(
        registry: SessionRegistry,
        recordSessions: Bool = false,
        retainLogs: Bool = false
    ) {
        self.registry = registry
        self.recordSessions = recordSessions
        self.retainLogs = retainLogs
    }

    /// Spawn the shell and queue its initial input. Synchronous and cheap; the
    /// session is not yet admitted — pass it to `activate`. Split so the
    /// WebSocket handler can hold the session (buffering client frames)
    /// while admission resolves, exactly as it did before the factoring.
    public func prepare(_ request: Request) throws -> PtySession {
        var profile: SessionProfile?
        if let profileName = request.profileName {
            guard let found = SessionProfiles.find(profileName) else {
                throw SpawnFailure.unknownProfile(profileName)
            }
            profile = found
        }
        let session = try PtySession.spawn(
            cols: min(max(request.cols, 1), KittermConstants.maxCols),
            rows: min(max(request.rows, 1), KittermConstants.maxRows),
            cwd: Self.validatedCwd(request.cwd) ?? Self.validatedCwd(profile?.cwd),
            histFile: Self.historyFile(for: request.histKey),
            profileName: profile?.name,
            labels: request.labels,
            name: request.name,
            note: request.note,
            spawnedByAPI: request.spawnedByAPI
        )
        // Queued as type-ahead: it flushes when the reader channel adopts the
        // PTY and the shell executes it at its first read — visible, echoed,
        // and in this pane's history like a typed command.
        if let profile {
            try? session.write(Data((profile.command + "\n").utf8))
        }
        if let input = request.initialInput, !input.isEmpty {
            session.noteSubmittedCommand(input)
            try? session.write(input)
        }
        if recordSessions,
           let recorder = SessionRecorder(
               directory: DaemonPaths.recordingsDirectory,
               cols: session.cols,
               rows: session.rows,
               shell: session.shellPath
           ) {
            session.attachRecorder(recorder)
        }
        return session
    }

    /// Start the reader and admit the session. Fails with `atCapacity` at the
    /// registry ceiling — the shell is already terminated when that happens,
    /// because spawning first is what makes the cap check atomic.
    ///
    /// `attached: false` (the API path) also wires exit reporting: with no
    /// controller to observe the exit, `detach(onExitWhileDetached:)` is the
    /// only path by which the registry hears the shell died.
    ///
    /// `respawnOf` is the id a pane held before a daemon restart, when this
    /// session replaces it; it rides on the `session.created` event.
    public func activate(
        _ session: PtySession,
        attached: Bool,
        respawnOf: UUID? = nil,
        eventLoop: EventLoop
    ) -> EventLoopFuture<UUID> {
        let registry = self.registry
        let retainLogs = self.retainLogs
        // The daemon runs one event loop; the loop itself serves as the
        // bootstrap group, so the service needs no group of its own.
        return session.makeReader(group: eventLoop, eventLoop: eventLoop)
            .flatMap { () -> EventLoopFuture<UUID> in
                let promise = eventLoop.makePromise(of: UUID.self)
                promise.completeWithTask {
                    let registered = attached
                        ? await registry.register(session, respawnOf: respawnOf)
                        : await registry.registerDetached(session)
                    guard let id = registered else {
                        session.terminate()
                        throw SpawnFailure.atCapacity
                    }
                    return id
                }
                return promise.futureResult
            }
            .map { id in
                if retainLogs {
                    session.attachLogStore { origin in
                        SessionLogStore(
                            directory: DaemonPaths.logsDirectory,
                            sessionID: id,
                            maxBytes: KittermConstants.retainedLogBytes,
                            origin: origin
                        )
                    }
                }
                if !attached {
                    // No controller will ever call `handlePtyExit`, so the
                    // shell's exit reaches the registry only through here.
                    // `terminate()` is what flips `isRunning`, so `exited`/
                    // `exitCode` read correctly; it no longer deletes retained
                    // output (that waits for the reap), so the records survive.
                    session.detach(onExitWhileDetached: { [weak session] _ in
                        session?.terminate()
                        Task { await registry.sessionDidExit(id) }
                    })
                }
                return id
            }
    }

    /// Deep-link cwd (`/?cwd=…`, `POST /api/sessions`): expand `~`, require an
    /// existing directory; anything else falls back to the default (home).
    public static func validatedCwd(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return resolved
    }

    /// Per-pane history file for `?hist=<key>`. The key is sanitized to a strict
    /// allowlist so it can never escape `~/.kitterm/history/`; anything invalid
    /// yields nil, and the shell falls back to its own default HISTFILE.
    public static func historyFile(for key: String?) -> String? {
        guard let key, !key.isEmpty, key.count <= 128 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard key.allSatisfy(allowed.contains) else { return nil }
        return DaemonPaths.historyDirectory.appendingPathComponent(key).path
    }
}
