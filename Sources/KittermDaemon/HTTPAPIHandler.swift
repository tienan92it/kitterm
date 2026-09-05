import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1

final class HTTPAPIHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let registry: SessionRegistry
    private let staticRoot: URL?
    private let policy: AccessPolicy
    private let port: Int
    /// Whether the write route (`POST /api/sessions/<id>/input`) is enabled.
    /// Off unless the daemon was started with `--agent-control`.
    private let agentControl: Bool
    /// Tool calls waiting on a human. Shared across connections — the hook that
    /// registers one and the phone that answers it are different requests.
    private let approvals: ApprovalStore
    /// The shared spawn path, so `POST /api/sessions` creates sessions through
    /// exactly the steps a browser tab does.
    private let spawnService: SessionSpawnService
    /// The daemon-wide event feed behind `GET /api/events`. Handler call sites
    /// append status/approval/rename/note events here.
    private let eventLog: EventLog
    /// This connection arrived on the TLS listener, so auth cookies may carry
    /// `Secure`.
    private let connectionIsTLS: Bool
    /// Port of the TLS listener, when one is running — used to build the
    /// external URL that share links are made from.
    private let tlsPort: Int?
    /// The WebSocket upgrader, so that a session can still be opened on a
    /// connection that has already served an API request. See
    /// `restoreUpgradeHandler(context:)`.
    private let webSocketUpgrader: (any HTTPServerProtocolUpgrader)?
    private var pendingHead: HTTPRequestHead?
    /// Accumulated request body, capped at `maxInputBytes`; only the input
    /// route reads it. `bodyOverflow` trips once the cap is exceeded so a large
    /// upload can't grow this unbounded — the route then answers 413.
    private var pendingBody: [UInt8] = []
    private var bodyOverflow = false
    /// How much body this request may carry. Input is a command line; a drop is
    /// a file, so the cap is set per route once the head names one.
    private var bodyLimit = KittermConstants.maxInputBytes

    init(
        registry: SessionRegistry,
        policy: AccessPolicy = .loopbackOnly,
        port: Int = KittermConstants.defaultPort,
        agentControl: Bool = false,
        approvals: ApprovalStore = ApprovalStore(),
        spawnService: SessionSpawnService? = nil,
        eventLog: EventLog = EventLog(),
        connectionIsTLS: Bool = false,
        tlsPort: Int? = nil,
        staticRoot: URL? = StaticFileServer.cachedRoot,
        webSocketUpgrader: (any HTTPServerProtocolUpgrader)? = nil
    ) {
        self.registry = registry
        self.policy = policy
        self.port = port
        self.agentControl = agentControl
        self.approvals = approvals
        self.spawnService = spawnService ?? SessionSpawnService(registry: registry)
        self.eventLog = eventLog
        self.connectionIsTLS = connectionIsTLS
        self.tlsPort = tlsPort
        self.staticRoot = staticRoot
        self.webSocketUpgrader = webSocketUpgrader
    }

    /// Put a fresh upgrade handler back in front of us so the *next* request on
    /// this connection can still open a session.
    ///
    /// `HTTPServerUpgradeHandler` is one-shot: the first non-upgrade request
    /// removes it for good. Browsers never notice, since a WebSocket gets its
    /// own socket — but a client pooling one connection for both the REST API
    /// and `/ws` (Node's `fetch` and `WebSocket` share a pool) then 404s on
    /// every session after the first. The handshake still runs through NIO's
    /// own code; this only decides when an upgrader is present.
    ///
    /// Best-effort: if the pipeline is not the shape
    /// `configureHTTPServerPipeline` builds, leave it alone. The cost of doing
    /// nothing is the 404 we had before.
    private func restoreUpgradeHandler(context: ChannelHandlerContext) {
        guard let upgrader = webSocketUpgrader else { return }
        let sync = context.pipeline.syncOperations
        // Nothing has displaced it yet.
        guard (try? sync.handler(type: HTTPServerUpgradeHandler.self)) == nil else { return }
        guard let encoder = try? sync.handler(type: HTTPResponseEncoder.self),
              let decoder = try? sync.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
        else { return }
        // Every HTTP handler but the encoder must come out before frames flow,
        // or it will parse WebSocket bytes as HTTP. Same set
        // `configureHTTPServerPipeline` hands the upgrader.
        let optionalHandlers: [RemovableChannelHandler?] = [
            try? sync.handler(type: HTTPServerPipelineHandler.self),
            try? sync.handler(type: NIOHTTPResponseHeadersValidator.self),
            try? sync.handler(type: HTTPServerProtocolErrorHandler.self),
        ]
        let extraHTTPHandlers: [RemovableChannelHandler] = [decoder] + optionalHandlers.compactMap { $0 }
        let fresh = HTTPServerUpgradeHandler(
            upgraders: [upgrader],
            httpEncoder: encoder,
            extraHTTPHandlers: extraHTTPHandlers,
            upgradeCompletionHandler: { [weak self] upgradeContext in
                guard let self else { return }
                _ = upgradeContext.pipeline.removeHandler(self)
            }
        )
        try? sync.addHandler(fresh, position: .before(self))
    }

    /// `POST /api/sessions/<uuid>/files` — the one route whose body is a file.
    private static func isDropUpload(_ head: HTTPRequestHead) -> Bool {
        guard head.method == .POST else { return false }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        return path.hasPrefix("/api/sessions/") && path.hasSuffix("/files")
    }

    /// Whether an auth cookie set on this request may carry `Secure`.
    ///
    /// True on the TLS listener. Also true when a trusted proxy reports it
    /// terminated TLS: `X-Forwarded-Proto` is honoured *only* for this, only
    /// from a loopback peer, and only when public hosts are configured — the
    /// worst a forged header can do is make a cookie stricter, and it never
    /// touches an access decision.
    private func cookiesMayBeSecure(head: HTTPRequestHead, context: ChannelHandlerContext) -> Bool {
        if connectionIsTLS { return true }
        guard !policy.trustedHosts.isEmpty,
              AccessPolicy.isLoopback(context.channel.remoteAddress),
              let proto = head.headers["x-forwarded-proto"].first
        else {
            return false
        }
        return proto.split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() == "https"
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
            pendingBody.removeAll(keepingCapacity: true)
            bodyOverflow = false
            bodyLimit = Self.isDropUpload(head) ? KittermConstants.maxDropBytes
                                               : KittermConstants.maxInputBytes
        case .body(let buffer):
            guard !bodyOverflow else { break }
            if pendingBody.count + buffer.readableBytes > bodyLimit {
                bodyOverflow = true
                pendingBody.removeAll(keepingCapacity: false)
                break
            }
            pendingBody.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head = pendingHead else { return }
            pendingHead = nil
            let body = Data(pendingBody)
            let overflow = bodyOverflow
            pendingBody.removeAll(keepingCapacity: true)
            bodyOverflow = false
            // Before serving, so a client pipelining `/ws` behind this request
            // finds an upgrader waiting.
            restoreUpgradeHandler(context: context)
            handle(head: head, body: body, bodyOverflow: overflow, context: context)
        }
    }

    private func handle(
        head: HTTPRequestHead,
        body: Data,
        bodyOverflow: Bool,
        context: ChannelHandlerContext
    ) {
        let grade: TokenGrade
        var authCookie: String?
        switch policy.decide(
            remote: context.channel.remoteAddress,
            headers: head.headers,
            uri: head.uri
        ) {
        case .allow(let allowed):
            grade = allowed
        case .allowSettingCookie(let allowed, let cookie):
            grade = allowed
            authCookie = cookie
        case .reject(let reason):
            // A browser navigation gets a page it can act on; everything else
            // keeps the JSON contract. An installed app has no address bar, so
            // a JSON body is a dead end there — this form is the only way back
            // in once its cookie has lapsed or was never set.
            if Self.wantsHTML(head.headers) {
                writeHTML(
                    status: .forbidden,
                    body: Self.tokenPromptPage(reason: reason),
                    context: context,
                    version: head.version
                )
            } else {
                writeJSON(
                    status: .forbidden,
                    body: #"{"ok":false,"error":"\#(reason)"}"#,
                    context: context,
                    version: head.version,
                    keepAlive: false
                )
            }
            return
        }

        let path = uriPath(head.uri)

        switch (head.method, path) {
        case (.GET, "/api/health"):
            let promise = context.eventLoop.makePromise(of: Int.self)
            promise.completeWithTask {
                await self.registry.count
            }
            promise.futureResult.whenComplete { result in
                let sessions: Int
                switch result {
                case .success(let count):
                    sessions = count
                case .failure:
                    sessions = -1
                }
                let body = #"{"ok":true,"sessions":\#(sessions)}"#
                self.writeJSON(
                    status: .ok,
                    body: body,
                    context: context,
                    version: head.version,
                    keepAlive: head.isKeepAlive
                )
            }
        case (.GET, "/api/version"):
            // `running` is this process; `installed` is what a restart would
            // pick up. They differ after `kitterm upgrade`, which stages a new
            // build without stopping the daemon so live panes survive.
            let running = BuildVersion.running
            let installed = BuildVersion.onDisk()
            let payload: [String: Any] = [
                "ok": true,
                "running": running,
                "installed": installed,
                "updatePending": installed != running,
            ]
            let body: String
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = #"{"ok":false,"error":"encoding failed"}"#
            }
            writeJSON(
                status: .ok,
                body: body,
                context: context,
                version: head.version,
                keepAlive: head.isKeepAlive
            )
        case (.GET, "/api/lan"):
            // Share-link support: the LAN base URL, plus the token — but only
            // for loopback callers (the machine's own user).
            let body: String
            // Where another device should reach this daemon, in preference
            // order: the public name over TLS (a cert never matches a bare
            // IP), then a public name behind a proxy, then the plaintext LAN
            // IP. The share and watch buttons build their links from this, so
            // getting it right here is what keeps them correct everywhere.
            if let external = externalBase() {
                let isLocal = AccessPolicy.isLoopback(context.channel.remoteAddress)
                var tokenField = ""
                if isLocal, let token = policy.token {
                    tokenField += #","token":"\#(token)""#
                }
                if isLocal, let watch = policy.watchToken {
                    tokenField += #","watchToken":"\#(watch)""#
                }
                body = #"{"ok":true,"enabled":true,"url":"\#(external)"\#(tokenField)}"#
            } else if policy.lanEnabled, let ip = NetworkInterfaces.primaryLANIPv4() {
                // Tokens only for loopback callers (the machine's own user):
                // the full token for control links, the watch token for
                // read-only share links.
                let isLocal = AccessPolicy.isLoopback(context.channel.remoteAddress)
                var tokenField = ""
                if isLocal, let token = policy.token {
                    tokenField += #","token":"\#(token)""#
                }
                if isLocal, let watch = policy.watchToken {
                    tokenField += #","watchToken":"\#(watch)""#
                }
                body = #"{"ok":true,"enabled":true,"url":"http://\#(ip):\#(port)"\#(tokenField)}"#
            } else {
                body = #"{"ok":true,"enabled":false}"#
            }
            writeJSON(
                status: .ok,
                body: body,
                context: context,
                version: head.version,
                keepAlive: head.isKeepAlive
            )
        case (.GET, "/api/sessions"):
            serveSessions(head: head, context: context)
        case (.POST, "/api/sessions"):
            serveSpawn(
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.GET, "/api/profiles"):
            // Full grade only. Profiles are connect commands (ssh hosts,
            // docker invocations) a watch client could never run anyway —
            // serving them would leak infrastructure for no benefit, and the
            // 403 is what tells the fleet page to hide the launcher.
            guard grade == .full else {
                writeJSON(
                    status: .forbidden,
                    body: #"{"ok":false,"error":"watch-only token"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            serveProfiles(head: head, context: context)
        case (.POST, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/archive"):
            serveArchive(path: path, grade: grade, head: head, context: context)
        case (.GET, "/api/archives"):
            serveArchiveList(head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/archives/") && path.hasSuffix("/output"):
            serveArchiveOutput(path: path, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/archives/"):
            serveArchiveDetail(path: path, head: head, context: context)
        case (.DELETE, _) where path.hasPrefix("/api/archives/"):
            serveArchiveDelete(path: path, grade: grade, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/marks"):
            serveMarks(path: path, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/commands"):
            serveCommands(path: path, head: head, context: context)
        case (.GET, _)
            where path.hasPrefix("/api/sessions/") && path.contains("/commands/")
                && path.hasSuffix("/wait"):
            serveCommandWait(path: path, head: head, context: context)
        case (.GET, _)
            where path.hasPrefix("/api/sessions/") && path.contains("/commands/")
                && path.hasSuffix("/output"):
            serveCommandOutput(path: path, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/sessions/"):
            // After every suffixed sessions route, so this only catches the
            // bare `/api/sessions/<id>` — one session's listing row.
            serveSessionDetail(path: path, head: head, context: context)
        case (.DELETE, _) where path.hasPrefix("/api/sessions/"):
            serveDelete(path: path, grade: grade, head: head, context: context)
        case (.PATCH, _) where path.hasPrefix("/api/sessions/"):
            serveSessionPatch(
                path: path,
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.POST, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/input"):
            serveInput(
                path: path,
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.POST, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/files"):
            serveDrop(
                path: path,
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.GET, "/api/events"):
            serveEvents(head: head, context: context)
        case (.POST, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/events"):
            serveNote(
                path: path,
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.POST, "/api/hooks"):
            serveHook(
                body: body,
                bodyOverflow: bodyOverflow,
                grade: grade,
                head: head,
                context: context
            )
        case (.GET, "/api/approvals"):
            serveApprovals(head: head, context: context)
        case (.POST, _) where path.hasPrefix("/api/approvals/"):
            serveApprovalDecision(
                path: path,
                body: body,
                grade: grade,
                head: head,
                context: context
            )
        case (.GET, "/api/files"):
            serveFileListing(grade: grade, head: head, context: context)
        case (.GET, "/api/files/stat"):
            serveFileStat(grade: grade, head: head, context: context)
        case (.GET, "/api/files/content"):
            serveFileContent(grade: grade, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/"):
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
        case (.GET, "/sessions"):
            // The fleet view is a distinct page; `/` stays "open a tab, get a
            // shell". Extensionless URL, static file behind it.
            serveStatic(path: "/sessions.html", head: head, context: context, authCookie: authCookie,
                        secureCookie: cookiesMayBeSecure(head: head, context: context))
        case (.GET, _):
            serveStatic(path: path, head: head, context: context, authCookie: authCookie,
                        secureCookie: cookiesMayBeSecure(head: head, context: context))
        default:
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
        }
    }

    /// The base URL other devices should use, when a public name is
    /// configured. Prefers TLS; nil when only the plaintext LAN path exists
    /// (the caller then falls back to the IP).
    private func externalBase() -> String? {
        guard let host = policy.trustedHosts.sorted().first else { return nil }
        if let tls = tlsPort {
            return tls == 443 ? "https://\(host)" : "https://\(host):\(tls)"
        }
        if policy.lanEnabled {
            // Bound externally with no certificate: the name resolves straight
            // to this daemon, so the honest link is plain HTTP on our own
            // port. Claiming https here would hand out links that cannot
            // connect.
            return port == 80 ? "http://\(host)" : "http://\(host):\(port)"
        }
        // Loopback-bound but answering to a public name: something fronts us,
        // and it owns the scheme and port. The bare name is all we can say.
        return "https://\(host)"
    }

    /// `GET /api/sessions` — every live session with its mark-derived state.
    /// The supervision surface: which shells are running, idle, or waiting,
    /// and what each last ran. Read-only.
    private func serveSessions(head: HTTPRequestHead, context: ChannelHandlerContext) {
        // `?label=run:abc` narrows the listing to one graph run — the same
        // syntax sessions are created with, so a caller filters with the string
        // it already has.
        let filter = DaemonServer.queryValue("label", fromRequestURI: head.uri)
        // An empty list would be indistinguishable from "no sessions matched".
        if let filter, !SessionLabels.isValidFilter(filter) {
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"label filter must be key:value"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let promise = context.eventLoop.makePromise(of: [SessionRegistry.SessionSummary].self)
        promise.completeWithTask {
            await self.registry.summaries()
        }
        promise.futureResult.whenComplete { result in
            var summaries = (try? result.get()) ?? []
            if let filter {
                summaries = summaries.filter { SessionLabels($0.labels).matches(filter: filter) }
            }
            // The approval store is loop-confined; this whenComplete runs on the loop.
            let approvalSessions = Set(self.approvals.snapshot().compactMap(\.sessionID))
            let items: [[String: Any]] = summaries.map { summary in
                Self.sessionItem(summary, pendingApproval: approvalSessions.contains(summary.id))
            }
            let body: String
            if let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "sessions": items]),
               let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = #"{"ok":false,"error":"encoding failed"}"#
            }
            self.writeJSON(
                status: .ok,
                body: body,
                context: context,
                version: head.version,
                keepAlive: head.isKeepAlive
            )
        }
    }

    /// One session's listing row. Shared by the list and the single-session
    /// route so the two can never drift apart. `pendingApproval` (whether a
    /// tool call is blocked on a human) is joined here, beside the session's
    /// own hook report, so a foreman reads one typed status per row instead of
    /// correlating three endpoints itself.
    private static func sessionItem(
        _ summary: SessionRegistry.SessionSummary,
        pendingApproval: Bool
    ) -> [String: Any] {
        let agent = summary.agentStatus
        let derived = DerivedSessionState.derive(from: summary.marks)
        let merged = MergedSessionState.merge(
            derived: derived,
            agent: agent,
            pendingApproval: pendingApproval,
            exited: summary.exited
        )
        var item: [String: Any] = [
            "id": summary.id.uuidString,
            "shell": summary.shell,
            "cwd": summary.cwd,
            "pid": summary.pid,
            "attached": summary.attached,
            "observers": summary.observerCount,
            // The mark-only state stays, so anything reading `running|idle|
            // unknown` keeps working; `mergedState` is the richer view.
            "state": derived.state.rawValue,
            "mergedState": merged.rawValue,
            "marks": summary.marks.count,
        ]
        if let command = derived.lastCommand { item["lastCommand"] = command }
        if let exit = derived.lastExit { item["lastExit"] = exit }
        if let profile = summary.profile { item["profile"] = profile }
        if let name = summary.name { item["name"] = name }
        if let note = summary.note { item["note"] = note }
        if !summary.labels.isEmpty { item["labels"] = summary.labels }
        if pendingApproval { item["pendingApproval"] = true }
        if let at = summary.lastOutputAt {
            item["lastOutputAt"] = Int(at.timeIntervalSince1970 * 1000)
        }
        if let agent {
            var status: [String: Any] = [
                "status": agent.report.rawValue,
                "at": Int(agent.at.timeIntervalSince1970 * 1000),
            ]
            if let message = agent.message { status["message"] = message }
            item["agent"] = status
        }
        if summary.exited {
            // Kept only so its records can still be read.
            item["exited"] = true
            if let code = summary.exitCode { item["exitCode"] = Int(code) }
        }
        return item
    }

    /// `GET /api/sessions/<uuid>` — one session's listing row. What the MCP
    /// bridge and a foreman's deep-read want without fetching the whole fleet.
    private func serveSessionDetail(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>"]
        guard components.count == 3, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let promise = context.eventLoop.makePromise(of: SessionRegistry.SessionSummary?.self)
        promise.completeWithTask {
            await self.registry.summary(id)
        }
        promise.futureResult.whenComplete { result in
            guard case .success(.some(let summary)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            let pendingApproval = self.approvals.snapshot().contains { $0.sessionID == summary.id }
            var payload = Self.sessionItem(summary, pendingApproval: pendingApproval)
            payload["ok"] = true
            let body: String
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = #"{"ok":false,"error":"encoding failed"}"#
            }
            self.writeJSON(
                status: .ok,
                body: body,
                context: context, version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// A request field that failed validation, with the reason for the 400.
    private struct ValidationError: Error {
        let reason: String
    }

    /// Fields a spawn or a patch may carry. Parsed strictly: a program that
    /// misnames a session should hear so, not get a silently unnamed one.
    private struct SessionMetadataFields {
        /// Two-level optionals: outer = "was the key present", inner = the
        /// value ("null clears").
        var name: String??
        var note: String??
        var labels: SessionLabels?

        static func parse(_ json: [String: Any]) -> Result<SessionMetadataFields, ValidationError> {
            var fields = SessionMetadataFields()
            if let raw = json["name"] {
                if raw is NSNull {
                    fields.name = .some(nil)
                } else if let text = raw as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count <= KittermConstants.maxSessionNameLength else {
                        return .failure(ValidationError(
                            reason: "name exceeds \(KittermConstants.maxSessionNameLength) characters"
                        ))
                    }
                    guard !trimmed.unicodeScalars.contains(where: {
                        $0.value < 0x20 || $0.value == 0x7F
                    }) else {
                        return .failure(ValidationError(reason: "name contains control characters"))
                    }
                    fields.name = .some(trimmed.isEmpty ? nil : trimmed)
                } else {
                    return .failure(ValidationError(reason: "name must be a string"))
                }
            }
            if let raw = json["note"] {
                if raw is NSNull {
                    fields.note = .some(nil)
                } else if let text = raw as? String {
                    guard text.count <= KittermConstants.maxSessionNoteLength else {
                        return .failure(ValidationError(
                            reason: "note exceeds \(KittermConstants.maxSessionNoteLength) characters"
                        ))
                    }
                    fields.note = .some(text.isEmpty ? nil : text)
                } else {
                    return .failure(ValidationError(reason: "note must be a string"))
                }
            }
            if let raw = json["labels"] {
                guard let dict = raw as? [String: Any] else {
                    return .failure(ValidationError(reason: "labels must be an object of string values"))
                }
                guard dict.count <= SessionLabels.maxCount else {
                    return .failure(ValidationError(reason: "more than \(SessionLabels.maxCount) labels"))
                }
                var values: [String: String] = [:]
                for (rawKey, rawValue) in dict {
                    let key = rawKey.lowercased()
                    guard let value = rawValue as? String,
                          SessionLabels.isValidKey(key),
                          SessionLabels.isValidValue(value)
                    else {
                        return .failure(ValidationError(reason: "invalid label \(rawKey)"))
                    }
                    values[key] = value
                }
                fields.labels = SessionLabels(values)
            }
            return .success(fields)
        }
    }

    /// `POST /api/sessions` — spawn a session from JSON, the programmatic
    /// counterpart of opening a tab. The one route that creates a shell from a
    /// request body, so it sits behind `--agent-control` + full grade like the
    /// input route: strictly more powerful than typing into an existing shell.
    private func serveSpawn(
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard agentControl else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        if bodyOverflow {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"body exceeds \#(KittermConstants.maxInputBytes) bytes"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let json: [String: Any]
        if body.isEmpty {
            json = [:]
        } else if let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            json = parsed
        } else {
            badRequest("body must be a JSON object", head: head, context: context)
            return
        }

        let fields: SessionMetadataFields
        switch SessionMetadataFields.parse(json) {
        case .success(let parsed): fields = parsed
        case .failure(let error):
            badRequest(error.reason, head: head, context: context)
            return
        }
        // A program that names a directory wants the error, not a silent
        // fallback to home — unlike a browser deep link, which degrades.
        var cwd: String?
        if let raw = json["cwd"] {
            guard let text = raw as? String, let valid = SessionSpawnService.validatedCwd(text) else {
                badRequest("cwd is not an existing directory", head: head, context: context)
                return
            }
            cwd = valid
        }
        var initialInput: Data?
        if let raw = json["input"] {
            guard let text = raw as? String, !text.isEmpty else {
                badRequest("input must be a non-empty string", head: head, context: context)
                return
            }
            initialInput = Data(text.utf8)
        }
        let profileName = json["profile"] as? String
        let cols = (json["cols"] as? Int).map { UInt16(clamping: $0) }
        let rows = (json["rows"] as? Int).map { UInt16(clamping: $0) }

        let session: PtySession
        do {
            session = try spawnService.prepare(
                SessionSpawnService.Request(
                    cwd: cwd,
                    profileName: profileName,
                    labels: fields.labels ?? SessionLabels(),
                    name: fields.name ?? nil,
                    note: fields.note ?? nil,
                    cols: cols ?? KittermConstants.defaultCols,
                    rows: rows ?? KittermConstants.defaultRows,
                    initialInput: initialInput,
                    spawnedByAPI: true
                )
            )
        } catch SessionSpawnService.SpawnFailure.unknownProfile(let name) {
            badRequest("unknown profile: \(name)", head: head, context: context)
            return
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "pty spawn failed"
            writeJSON(
                status: .internalServerError,
                body: Self.errorBody(reason),
                context: context, version: head.version, keepAlive: false
            )
            return
        }

        spawnService.activate(session, attached: false, eventLoop: context.eventLoop)
            .whenComplete { result in
                switch result {
                case .success(let id):
                    var payload: [String: Any] = [
                        "ok": true,
                        "id": id.uuidString,
                        // Paths, not URLs: `/api/lan` owns external-URL
                        // construction, and a duplicated rule is a stale link.
                        "wsPath": "/ws?session=\(id.uuidString)",
                        "pagePath": "/?session=\(id.uuidString)",
                    ]
                    if let name = session.name { payload["name"] = name }
                    let body = (try? JSONSerialization.data(withJSONObject: payload))
                        .flatMap { String(data: $0, encoding: .utf8) }
                        ?? #"{"ok":false,"error":"encoding failed"}"#
                    self.writeJSON(
                        status: .created,
                        body: body,
                        context: context, version: head.version, keepAlive: head.isKeepAlive
                    )
                case .failure(let error):
                    let atCapacity: Bool
                    if case SessionSpawnService.SpawnFailure.atCapacity = error {
                        atCapacity = true
                    } else {
                        atCapacity = false
                    }
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.writeJSON(
                        status: atCapacity ? .serviceUnavailable : .internalServerError,
                        body: Self.errorBody(reason),
                        context: context, version: head.version, keepAlive: false
                    )
                }
            }
    }

    /// `PATCH /api/sessions/<uuid>` — update name, note, or labels. Metadata
    /// only, so full grade suffices without `--agent-control`: nothing here
    /// drives a shell, same reasoning that keeps approval decisions outside
    /// the flag.
    private func serveSessionPatch(
        path: String,
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>"]
        guard components.count == 3, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        if bodyOverflow {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"body exceeds \#(KittermConstants.maxInputBytes) bytes"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              !json.isEmpty
        else {
            badRequest("body must be a JSON object with name, note, or labels",
                       head: head, context: context)
            return
        }
        let fields: SessionMetadataFields
        switch SessionMetadataFields.parse(json) {
        case .success(let parsed): fields = parsed
        case .failure(let error):
            badRequest(error.reason, head: head, context: context)
            return
        }
        struct PatchOutcome { let found: Bool; let newName: String? }
        let promise = context.eventLoop.makePromise(of: PatchOutcome.self)
        promise.completeWithTask {
            guard let session = await self.registry.session(id) else {
                return PatchOutcome(found: false, newName: nil)
            }
            if let name = fields.name {
                session.setName(name)
                await self.registry.nameChanged(id)
            }
            if let note = fields.note { session.setNote(note) }
            if let labels = fields.labels {
                session.updateLabels(labels)
                // The linger window follows the labels; an armed clock must
                // be re-armed with the new one.
                await self.registry.labelsChanged(id)
            }
            return PatchOutcome(found: true, newName: fields.name ?? nil)
        }
        promise.futureResult.whenComplete { result in
            let outcome = (try? result.get()) ?? PatchOutcome(found: false, newName: nil)
            let existed = outcome.found
            if existed, let name = outcome.newName {
                self.eventLog.append(type: "session.renamed", session: id, data: ["name": name])
            }
            self.writeJSON(
                status: existed ? .ok : .notFound,
                body: existed
                    ? #"{"ok":true}"#
                    : #"{"ok":false,"error":"no such session"}"#,
                context: context, version: head.version, keepAlive: existed && head.isKeepAlive
            )
        }
    }

    /// A 400 whose reason is a plain string (no user data needing escaping).
    private func badRequest(_ reason: String, head: HTTPRequestHead, context: ChannelHandlerContext) {
        writeJSON(
            status: .badRequest,
            body: Self.errorBody(reason),
            context: context, version: head.version, keepAlive: false
        )
    }

    /// `{"ok":false,"error":…}` with the reason JSON-escaped — reasons can
    /// carry user strings (a profile name, a label key).
    private static func errorBody(_ reason: String) -> String {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": reason]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"ok":false,"error":"encoding failed"}"#
    }

    /// `DELETE /api/sessions/<uuid>` — end a session and its shell now.
    ///
    /// The counterpart to the long detach window a labelled session gets: a
    /// caller that finished with a node says so, instead of leaving it to time
    /// out. Destructive, so it needs `--agent-control` and a full-grade token
    /// exactly like the input route.
    private func serveDelete(
        path: String,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard agentControl else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>"]
        guard components.count == 3, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let promise = context.eventLoop.makePromise(of: Bool.self)
        promise.completeWithTask {
            guard await self.registry.session(id) != nil else { return false }
            await self.registry.remove(id)
            return true
        }
        promise.futureResult.whenComplete { result in
            let existed = (try? result.get()) ?? false
            self.writeJSON(
                status: existed ? .ok : .notFound,
                body: existed
                    ? #"{"ok":true}"#
                    : #"{"ok":false,"error":"no such session"}"#,
                context: context, version: head.version, keepAlive: existed && head.isKeepAlive
            )
        }
    }

    // MARK: - Archive

    /// `POST /api/sessions/<uuid>/archive` — persist a finished session's
    /// evidence (metadata, commands, marks, output) to disk, then end it. The
    /// counterpart to the linger window for a session whose work is done but
    /// worth keeping. Destructive to the live session, so `--agent-control` +
    /// full grade, like `DELETE`.
    ///
    /// Honest scope: this preserves what the session *did*, not what it *was*.
    /// "Resume" is a foreman convention — spawn a new session with the archived
    /// name and cwd and a `resumed-from:<id>` label — not a process restore.
    private func serveArchive(
        path: String,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard agentControl else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "archive"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }

        enum Outcome { case ok; case noSession; case failed }
        let promise = context.eventLoop.makePromise(of: Outcome.self)
        promise.completeWithTask {
            guard let session = await self.registry.session(id) else { return .noSession }
            // Build the metadata JSON here (before any await): everything that
            // crosses onto the archive queue below is `Data`, which is
            // Sendable, so the [String: Any] arrays never leave this scope.
            // Read the captured output first (ring, or the retained log when
            // older than the ring), bounded to the retained-log ceiling. Its
            // `start` is where `output.log` begins in the absolute stream —
            // the commands' offsets are absolute, so the archive must say so.
            let range = await withCheckedContinuation { continuation in
                session.outputRange(
                    from: 0, to: .max,
                    maxBytes: KittermConstants.retainedLogBytes
                ) { continuation.resume(returning: $0) }
            }
            // The `outputUrl` a live row carries points at a route that 404s
            // the moment this session is removed; an archive reader slices
            // `output.log` by offset instead.
            let commands = session.commandsSnapshot().map { command -> [String: Any] in
                var item = self.commandJSON(command, sessionID: id)
                item.removeValue(forKey: "outputUrl")
                return item
            }
            let marks = session.marksSnapshot().map { Self.markJSON($0) }
            let record = SessionArchive.Record(
                id: id,
                name: session.name,
                note: session.note,
                labels: session.labels.values,
                cwd: session.liveCwd,
                shell: session.shellPath,
                profile: session.profileName,
                exitCode: session.exitCode,
                archivedAt: Date(),
                commands: commands,
                marks: marks,
                outputBase: range.start,
                outputPruned: range.pruned,
                outputBytes: range.data.count
            )
            // Serialize before the next await: only `Data` crosses onto the
            // archive queue, so the [String: Any] arrays never leave here.
            guard let metadata = try? JSONSerialization.data(
                withJSONObject: record.asJSON(), options: [.sortedKeys]
            ) else { return .failed }
            let output = range.data
            let wrote = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SessionArchive.write(id: id, metadata: metadata, output: output) {
                    continuation.resume(returning: $0)
                }
            }
            guard wrote else { return .failed }
            // The evidence is safe on disk; end the live session now.
            await self.registry.remove(id)
            self.eventLog.append(type: "session.archived", session: id, data: [:])
            return .ok
        }
        promise.futureResult.whenComplete { result in
            switch (try? result.get()) ?? .failed {
            case .ok:
                self.writeJSON(
                    status: .ok,
                    body: #"{"ok":true,"id":"\#(id.uuidString)"}"#,
                    context: context, version: head.version, keepAlive: head.isKeepAlive
                )
            case .noSession:
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
            case .failed:
                self.writeJSON(
                    status: .internalServerError,
                    body: #"{"ok":false,"error":"could not write the archive"}"#,
                    context: context, version: head.version, keepAlive: false
                )
            }
        }
    }

    /// `GET /api/archives` — every archived session's metadata, newest first.
    /// Read-only; a small local-file read like `/api/profiles`.
    private func serveArchiveList(head: HTTPRequestHead, context: ChannelHandlerContext) {
        // Directory scan + a file read per archive: off the loop, like every
        // other file I/O, then hop back with the encoded bytes.
        let loop = context.eventLoop
        let bound = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: Data.self)
        SessionArchive.list { promise.succeed($0) }
        promise.futureResult.whenSuccess { data in
            self.writeJSON(
                status: .ok, body: String(decoding: data, as: UTF8.self),
                context: bound.value, version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// `GET /api/archives/<uuid>` — one archive's full metadata.
    private func serveArchiveDetail(path: String, head: HTTPRequestHead, context: ChannelHandlerContext) {
        let components = path.split(separator: "/")
        // ["api", "archives", "<uuid>"]
        guard components.count == 3, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let loop = context.eventLoop
        let bound = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: Data?.self)
        SessionArchive.read(id) { promise.succeed($0) }
        promise.futureResult.whenSuccess { data in
            let context = bound.value
            guard let data, var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.notFound(context: context, version: head.version)
                return
            }
            json["ok"] = true
            let body = (try? JSONSerialization.data(withJSONObject: json))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"ok":false,"error":"encoding failed"}"#
            self.writeJSON(status: .ok, body: body, context: context, version: head.version, keepAlive: head.isKeepAlive)
        }
    }

    /// `GET /api/archives/<uuid>/output` — the archived output bytes.
    private func serveArchiveOutput(path: String, head: HTTPRequestHead, context: ChannelHandlerContext) {
        let components = path.split(separator: "/")
        // ["api", "archives", "<uuid>", "output"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let loop = context.eventLoop
        let bound = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: Data?.self)
        SessionArchive.output(id) { promise.succeed($0) }
        promise.futureResult.whenSuccess { data in
            let context = bound.value
            guard let data else {
                self.notFound(context: context, version: head.version)
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            headers.add(name: "Content-Length", value: "\(data.count)")
            headers.add(name: "Connection", value: head.isKeepAlive ? "keep-alive" : "close")
            let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                if !head.isKeepAlive { context.close(promise: nil) }
            }
        }
    }

    /// `DELETE /api/archives/<uuid>` — remove an archive permanently.
    /// Destructive, so `--agent-control` + full grade.
    private func serveArchiveDelete(
        path: String, grade: TokenGrade, head: HTTPRequestHead, context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard agentControl else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        guard components.count == 3, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let loop = context.eventLoop
        let bound = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: Bool.self)
        SessionArchive.delete(id) { promise.succeed($0) }
        promise.futureResult.whenSuccess { existed in
            self.writeJSON(
                status: existed ? .ok : .notFound,
                body: existed ? #"{"ok":true}"# : #"{"ok":false,"error":"no such archive"}"#,
                context: bound.value, version: head.version, keepAlive: existed && head.isKeepAlive
            )
        }
    }

    /// One mark as JSON, the same shape `/marks` serves.
    private static func markJSON(_ mark: SessionMark) -> [String: Any] {
        var item: [String: Any] = [
            "offset": mark.offset,
            "kind": markKindName(mark.kind),
            "at": Int(mark.at.timeIntervalSince1970 * 1000),
        ]
        if let exit = mark.exit { item["exit"] = exit }
        if let command = mark.command { item["command"] = command }
        return item
    }

    /// `GET /api/sessions/<uuid>/marks` — the session's shell-integration
    /// marks as JSON. Read-only; agents and tooling consume this to answer
    /// "what ran, what did it exit with" without parsing ANSI.
    ///
    /// Serialization runs on the event loop; that is safe only because the
    /// store is hard-capped at `sessionMarkCap` (1000) tiny entries.
    private func serveMarks(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "marks"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
            return
        }
        let promise = context.eventLoop.makePromise(of: [SessionMark]?.self)
        promise.completeWithTask {
            await self.registry.session(id)?.marksSnapshot()
        }
        promise.futureResult.whenComplete { result in
            guard case .success(.some(let marks)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context,
                    version: head.version,
                    keepAlive: false
                )
                return
            }
            let items: [[String: Any]] = marks.map { mark in
                var item: [String: Any] = [
                    "offset": mark.offset,
                    "kind": Self.markKindName(mark.kind),
                    "at": Int(mark.at.timeIntervalSince1970 * 1000),
                ]
                if let exit = mark.exit { item["exit"] = exit }
                if let command = mark.command { item["command"] = command }
                return item
            }
            let body: String
            if let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "marks": items]),
               let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = #"{"ok":false,"error":"encoding failed"}"#
            }
            self.writeJSON(
                status: .ok,
                body: body,
                context: context,
                version: head.version,
                keepAlive: head.isKeepAlive
            )
        }
    }

    /// `GET /api/files?path=<dir>&session=<uuid>` — list a directory so a
    /// caller can pick a file or folder and insert its real path.
    ///
    /// Full grade only, which is the whole of the access story: anyone who can
    /// reach this can already type `ls` into the session, and the daemon runs
    /// as the user, so the OS decides what is readable. Watch-only callers
    /// cannot type, so they must not be able to browse.
    private func serveFileListing(
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let requested = DaemonServer.queryValue("path", fromRequestURI: head.uri)
        let sessionID = DaemonServer.queryValue("session", fromRequestURI: head.uri)
            .flatMap(UUID.init(uuidString:))
        let showHidden = DaemonServer.queryValue("hidden", fromRequestURI: head.uri) == "1"

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: FileBrowser.Listing?.self)
        promise.completeWithTask {
            // Relative paths resolve against the session's own directory, which
            // is where a caller means when they say "src".
            var cwd: String?
            if let sessionID { cwd = await self.registry.session(sessionID)?.liveCwd }
            let directory = FileBrowser.resolve(requested, base: cwd)
            return try? await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result { try FileBrowser.list(directory, includeHidden: showHidden) }
                    )
                }
            }
        }
        promise.futureResult.whenComplete { result in
            let context = boundContext.value
            guard case .success(.some(let listing)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"cannot list that directory"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            var payload: [String: Any] = [
                "ok": true,
                "path": listing.path,
                "entries": listing.entries.map { entry -> [String: Any] in
                    var item: [String: Any] = ["name": entry.name, "dir": entry.isDirectory]
                    if let size = entry.size { item["size"] = size }
                    return item
                },
            ]
            if let parent = listing.parent { payload["parent"] = parent }
            let text = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"ok":false,"error":"encoding failed"}"#
            self.writeJSON(
                status: .ok, body: text, context: context,
                version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// `POST /api/sessions/<uuid>/files` — save a file dropped into the
    /// session and answer with the path it landed at.
    ///
    /// A coding agent takes context as paths, so this is what turns "drag a
    /// screenshot onto the pane" into something the agent can read. The name
    /// comes from the `X-Kitterm-Filename` header rather than the URL, so it
    /// never has to survive path parsing.
    ///
    /// Full grade only. Unlike the input route this needs no `--agent-control`:
    /// that flag exists to stop a *program* driving your shell, and this is a
    /// person dropping a file into their own browser — nearer to paste. The
    /// bytes only ever land under kitterm's own drops directory, so it stays a
    /// write into a known place rather than a way to write anywhere.
    private func serveDrop(
        path: String,
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard !bodyOverflow else {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"file exceeds \#(KittermConstants.maxDropBytes) bytes"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "files"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        guard !body.isEmpty else {
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"empty file"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let rawName = head.headers["x-kitterm-filename"].first
            .flatMap { $0.removingPercentEncoding } ?? "dropped-file"

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: String?.self)
        promise.completeWithTask {
            guard await self.registry.session(id) != nil else { return nil }
            // Writing bytes is blocking work, so it does not run on the loop.
            return try? await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        with: Result { try SessionDrops.store(
                            data: body, filename: rawName, sessionID: id
                        ).path }
                    )
                }
            }
        }
        promise.futureResult.whenComplete { result in
            let context = boundContext.value
            guard case .success(.some(let saved)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session, or the file could not be saved"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            let payload: [String: Any] = [
                "ok": true,
                "path": saved,
                "name": (saved as NSString).lastPathComponent,
                "bytes": body.count,
            ]
            let text = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"ok":false,"error":"encoding failed"}"#
            self.writeJSON(
                status: .ok, body: text, context: context,
                version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// `GET /api/sessions/<uuid>/commands` — the session's commands as JSON,
    /// each with its output byte range and exit code (derived from marks). An
    /// agent reads this to find a command, then fetches its output below.
    private func serveCommands(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "commands"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        let promise = context.eventLoop.makePromise(of: [SessionCommand]?.self)
        promise.completeWithTask { await self.registry.session(id)?.commandsSnapshot() }
        promise.futureResult.whenComplete { result in
            guard case .success(.some(let commands)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            let items = commands.map { self.commandJSON($0, sessionID: id) }
            let body: String
            if let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "commands": items]),
               let text = String(data: data, encoding: .utf8) {
                body = text
            } else {
                body = #"{"ok":false,"error":"encoding failed"}"#
            }
            self.writeJSON(
                status: .ok, body: body, context: context,
                version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// `GET /api/sessions/<uuid>/commands/<n>/wait?timeout=<seconds>` — hold the
    /// response until command `n` finishes.
    ///
    /// This is what turns kitterm into an `execute()` backend: write a command
    /// with `POST …/input`, block here for its exit code, then read
    /// `…/output`. Read-only, so unlike the input route it needs no
    /// `--agent-control`.
    ///
    /// Waiting for a command that has not started is legitimate — a caller
    /// writes input and immediately waits on the command it just created. A
    /// timeout is not an error: the response says `running: true` and the
    /// caller may ask again, which keeps a slow node from looking like a
    /// failure.
    private func serveCommandWait(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "commands", "<n>", "wait"]
        guard components.count == 6,
              let id = UUID(uuidString: String(components[2])),
              let index = Int(components[4]), index >= 1
        else {
            notFound(context: context, version: head.version)
            return
        }
        let requested = DaemonServer.queryValue("timeout", fromRequestURI: head.uri)
            .flatMap(Int.init) ?? KittermConstants.commandWaitDefaultSeconds
        let timeout = max(1, min(requested, KittermConstants.commandWaitMaxSeconds))

        // The lookup promise, the timeout task and the waiter all complete on
        // this connection's loop, but NIO's closures are `@Sendable` and a
        // `ChannelHandlerContext` is not — so state the affinity rather than
        // capture it bare, which Swift 6.0 rejects outright.
        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let lookup = loop.makePromise(of: PtySession?.self)
        lookup.completeWithTask { await self.registry.session(id) }
        lookup.futureResult.whenComplete { result in
            let context = boundContext.value
            guard case .success(.some(let session)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            // An aged-out index will never be closed by anything, so waiting on
            // it would block to the deadline and then report it still running.
            guard index >= session.firstRetainedCommandIndex else {
                self.writeCommandMissing(gone: true, context: context, version: head.version)
                return
            }
            // The shell is gone, so nothing will ever close a command here.
            // Answer from the record rather than blocking to the deadline.
            guard session.isRunning else {
                self.respondWithCommand(
                    index: index, session: session, id: id, head: head, context: context
                )
                return
            }
            let future: EventLoopFuture<Void>
            switch session.awaitCommandEnd(index: index, on: context.eventLoop) {
            case .tooManyWaiters:
                self.writeJSON(
                    status: .serviceUnavailable,
                    body: #"{"ok":false,"error":"too many waiters on this session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            case .finished:
                self.respondWithCommand(
                    index: index, session: session, id: id, head: head, context: context
                )
                return
            case .waiting(let registered):
                future = registered
            }
            // First of the two wins; the other is harmless. The flag is shared
            // by the timeout task and the waiter, both on this loop.
            let answered = NIOLoopBoundBox(false, eventLoop: loop)
            let answer: @Sendable (Bool) -> Void = { timedOut in
                let context = boundContext.value
                guard !answered.value else { return }
                answered.value = true
                if timedOut {
                    session.cancelCommandWait(future)
                    self.writeJSON(
                        status: .ok,
                        body: #"{"ok":true,"index":\#(index),"running":true,"timedOut":true}"#,
                        context: context, version: head.version, keepAlive: head.isKeepAlive
                    )
                } else {
                    self.respondWithCommand(
                        index: index, session: session, id: id, head: head, context: context
                    )
                }
            }
            let timeoutTask = loop.scheduleTask(in: .seconds(Int64(timeout))) {
                answer(true)
            }
            future.whenComplete { _ in
                timeoutTask.cancel()
                answer(false)
            }
        }
    }

    /// Answer a wait with the command's own record, or 404 if the shell died
    /// before it ever produced one.
    /// 410 when the index ran and aged out, 404 when it never existed.
    private func writeCommandMissing(
        gone: Bool,
        context: ChannelHandlerContext,
        version: HTTPVersion
    ) {
        writeJSON(
            status: gone ? .gone : .notFound,
            body: gone
                ? #"{"ok":false,"error":"command aged out of this session's history"}"#
                : #"{"ok":false,"error":"no such command"}"#,
            context: context, version: version, keepAlive: false
        )
    }

    private func respondWithCommand(
        index: Int,
        session: PtySession,
        id: UUID,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let commands = session.commandsSnapshot()
        guard let cmd = commands.first(where: { $0.index == index }) else {
            // A command can age out while its caller is still waiting on it.
            writeCommandMissing(
                gone: index < session.firstRetainedCommandIndex,
                context: context,
                version: head.version
            )
            return
        }
        var payload = commandJSON(cmd, sessionID: id)
        payload["ok"] = true
        let body = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"ok":false,"error":"encoding failed"}"#
        writeJSON(
            status: .ok, body: body, context: context,
            version: head.version, keepAlive: head.isKeepAlive
        )
    }

    /// One command as JSON.
    ///
    /// Carries what a caller needs to hang its own span on: exact byte range,
    /// exit code, real timings, and a stable URL for the raw output. kitterm
    /// emits no traces of its own — the caller owns the trace context, so the
    /// useful thing is to make these facts attachable to a span it already has.
    private func commandJSON(_ cmd: SessionCommand, sessionID: UUID) -> [String: Any] {
        var item: [String: Any] = [
            "index": cmd.index,
            "startOffset": cmd.startOffset,
            "running": cmd.running,
            "startedAt": Int(cmd.startedAt.timeIntervalSince1970 * 1000),
            "outputUrl": "/api/sessions/\(sessionID.uuidString)/commands/\(cmd.index)/output",
        ]
        if let command = cmd.command { item["command"] = command }
        if let exit = cmd.exit { item["exit"] = exit }
        if let end = cmd.endOffset { item["endOffset"] = end }
        if let endedAt = cmd.endedAt {
            item["endedAt"] = Int(endedAt.timeIntervalSince1970 * 1000)
        }
        if let durationMs = cmd.durationMs { item["durationMs"] = durationMs }
        return item
    }

    /// `GET /api/sessions/<uuid>/commands/<n>/output` — the raw output bytes of
    /// command `n` (1-based). Served as `application/octet-stream`, capped at
    /// `apiCommandOutputMaxBytes` (the tail is returned for a flood); response
    /// headers report the full size and whether bytes were dropped.
    private func serveCommandOutput(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "commands", "<n>", "output"]
        guard components.count == 6,
              let id = UUID(uuidString: String(components[2])),
              let index = Int(components[4]), index >= 1
        else {
            notFound(context: context, version: head.version)
            return
        }
        let cap = KittermConstants.apiCommandOutputMaxBytes
        let promise = context.eventLoop.makePromise(of: PtySession.OutputRange?.self)
        promise.completeWithTask {
            guard let session = await self.registry.session(id) else { return nil }
            // By index, not position: the two diverge once the window slides.
            guard let cmd = session.commandsSnapshot().first(where: { $0.index == index })
            else { return nil }
            // A running command has no end yet — read up to the current head.
            let end = cmd.endOffset ?? UInt64.max
            return await withCheckedContinuation { continuation in
                session.outputRange(from: cmd.startOffset, to: end, maxBytes: cap) { range in
                    continuation.resume(returning: range)
                }
            }
        }
        promise.futureResult.whenComplete { result in
            guard case .success(.some(let range)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session or command"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            headers.add(name: "Content-Length", value: "\(range.data.count)")
            headers.add(name: "X-Kitterm-Total-Bytes", value: "\(range.total)")
            headers.add(name: "X-Kitterm-Truncated", value: range.truncated ? "1" : "0")
            headers.add(name: "X-Kitterm-Pruned", value: range.pruned ? "1" : "0")
            headers.add(name: "Connection", value: head.isKeepAlive ? "keep-alive" : "close")
            let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: range.data.count)
            buffer.writeBytes(range.data)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                if !head.isKeepAlive { context.close(promise: nil) }
            }
        }
    }

    // MARK: - Event feed

    /// `GET /api/events?since=<seq>&epoch=<id>&timeout=<s>&session=<id>` —
    /// the daemon-wide control-plane feed. Returns events newer than `since`
    /// at once, or parks until one arrives (the `/commands/<n>/wait` shape).
    /// One parked request replaces a foreman polling `/api/sessions` for every
    /// crew session. Read-only, so any grade: seeing what an agent is doing is
    /// observation.
    ///
    /// Every answer carries the daemon's `epoch`. A `since` from another epoch
    /// (the caller says so with `epoch=`, or the seq is past this daemon's
    /// head) answers `pruned: true` with this epoch's events from its
    /// `daemon.started` on, so a foreman learns of a restart from the feed it
    /// is already parked on, never from a connection error.
    private func serveEvents(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let since = DaemonServer.queryValue("since", fromRequestURI: head.uri)
            .flatMap(UInt64.init) ?? 0
        let epoch = DaemonServer.queryValue("epoch", fromRequestURI: head.uri)
            .flatMap { $0.isEmpty ? nil : $0 }
        let session = DaemonServer.queryValue("session", fromRequestURI: head.uri)
            .flatMap(UUID.init(uuidString:))
        let requested = DaemonServer.queryValue("timeout", fromRequestURI: head.uri)
            .flatMap(Int.init) ?? KittermConstants.eventWaitDefaultSeconds
        let timeout = max(1, min(requested, KittermConstants.eventWaitMaxSeconds))

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        // Read-or-park in one lock acquisition, so an event landing between
        // "nothing yet" and "park me" cannot be missed.
        let waiterID: UInt64
        let future: EventLoopFuture<Void>
        switch eventLog.poll(since: since, epoch: epoch, session: session, on: loop) {
        case .ready(let events, let next, let pruned):
            writeEvents(
                (events, next, pruned),
                context: context, version: head.version, keepAlive: head.isKeepAlive
            )
            return
        case .tooManyWaiters:
            writeJSON(
                status: .serviceUnavailable,
                body: #"{"ok":false,"error":"too many event waiters"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        case .waiting(let id, let parked):
            waiterID = id
            future = parked
        }
        let answered = NIOLoopBoundBox(false, eventLoop: loop)
        let answer: @Sendable (Bool) -> Void = { timedOut in
            guard !answered.value else { return }
            answered.value = true
            if timedOut { self.eventLog.expire(id: waiterID) }
            // Re-read whatever the wake found (empty on a pure timeout, which
            // is a fine answer — the caller polls again with the same cursor).
            let snapshot = self.eventLog.snapshot(since: since, epoch: epoch, session: session)
            self.writeEvents(
                snapshot,
                context: boundContext.value,
                version: head.version,
                keepAlive: head.isKeepAlive
            )
        }
        let timeoutTask = loop.scheduleTask(in: .seconds(Int64(timeout))) { answer(true) }
        future.whenComplete { _ in
            timeoutTask.cancel()
            answer(false)
        }
    }

    private func writeEvents(
        _ snapshot: (events: [DaemonEvent], next: UInt64, pruned: Bool),
        context: ChannelHandlerContext,
        version: HTTPVersion,
        keepAlive: Bool
    ) {
        let payload: [String: Any] = [
            "ok": true,
            "epoch": eventLog.epoch,
            "events": snapshot.events.map { $0.asJSON() },
            "next": snapshot.next,
            "pruned": snapshot.pruned,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"ok":false,"error":"encoding failed"}"#
        writeJSON(status: .ok, body: body, context: context, version: version, keepAlive: keepAlive)
    }

    /// Publish a hook-driven status change to the event feed, so a foreman
    /// parked on `/api/events` wakes the moment a crew agent needs it or
    /// finishes — not on the next 2s poll.
    private func emitAgentStatus(_ sessionID: UUID, report: AgentReport, message: String?) {
        var data = ["status": report.rawValue]
        if let message { data["message"] = message }
        eventLog.append(type: "agent.status", session: sessionID, data: data)
    }

    /// `POST /api/sessions/<id>/events` — a crew agent posts a structured note
    /// ("plan ready for review"). The counterpart to `/api/hooks`: an agent
    /// *reporting*, not driving, so full grade without `--agent-control`. The
    /// note lands as a `note` event and, in a foreman loop, wakes the parked
    /// `/api/events`.
    private func serveNote(
        path: String,
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "events"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        if bodyOverflow {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"body too large"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let message = json["message"] as? String, !message.isEmpty
        else {
            badRequest("body must be {message: string}", head: head, context: context)
            return
        }
        var data = ["message": String(message.prefix(KittermConstants.maxEventNoteLength))]
        if let extra = json["data"] as? [String: Any] {
            for (key, value) in extra where value is String {
                data[key] = (value as? String).map { String($0.prefix(KittermConstants.maxEventNoteLength)) }
            }
        }
        let promise = context.eventLoop.makePromise(of: Bool.self)
        promise.completeWithTask { await self.registry.session(id) != nil }
        promise.futureResult.whenComplete { result in
            guard (try? result.get()) == true else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            self.eventLog.append(type: "note", session: id, data: data)
            self.writeJSON(
                status: .ok,
                body: #"{"ok":true}"#,
                context: context, version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    // MARK: - Agent hooks and approvals

    /// Receive a Claude Code hook event.
    ///
    /// Configured as `"type": "http"` in settings.json, so the agent POSTs the
    /// event here and reads its verdict from *this response body* — status
    /// codes cannot block a tool call, only the JSON can. `PermissionRequest`
    /// is the held event — it fires only when a dialog would show;
    /// `PreToolUse`, `Notification` and `Stop` are informational and answered
    /// at once.
    ///
    /// Anything unrecognised answers 200 with an empty object, so an
    /// over-broad hook config costs nothing and a schema change degrades to
    /// "no opinion" rather than to a wedged agent.
    ///
    /// An agent killed mid-prompt leaves its question listed until the hold
    /// expires: NIO keeps the channel open while a response is outstanding, so
    /// neither `channelInactive` nor `closeFuture` fires (measured, not
    /// assumed). Deciding a dead one is harmless — it answers 404, which the
    /// fleet view treats as "too late" — so the hold's own deadline is left to
    /// clean it up rather than adding a handler ahead of the HTTP pipeline.
    private func serveHook(
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        // Full grade only. The hook config URL is always loopback (the agent
        // runs on the daemon's own machine), so this refuses nothing real —
        // but once these events drive a status the fleet view trusts, an
        // ungated route would let a watch caller spoof "completed" on any
        // session.
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard !bodyOverflow else {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"hook payload too large"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let event = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let name = event?["hook_event_name"] as? String

        // Which pane asked. The daemon exports KITTERM_SESSION_ID into every
        // shell it spawns; the hook config carries it back in this header.
        let sessionID = head.headers.first(name: "x-kitterm-session")
            .flatMap(UUID.init(uuidString:))

        // The status a hook reports lives on the session (its lifetime is the
        // session's), so resolve it first; the rest runs back on this loop.
        let lookupLoop = context.eventLoop
        let lookupContext = NIOLoopBound(context, eventLoop: lookupLoop)
        let lookup = lookupLoop.makePromise(of: PtySession?.self)
        lookup.completeWithTask {
            guard let sessionID else { return nil }
            return await self.registry.session(sessionID)
        }
        lookup.futureResult.whenComplete { result in
            self.handleHookEvent(
                name: name,
                event: event,
                sessionID: sessionID,
                session: (try? result.get()) ?? nil,
                head: head,
                context: lookupContext.value
            )
        }
    }

    /// The hook, once its session is known. Non-blocking events record and
    /// answer `{}`; `PermissionRequest` holds for a human.
    private func handleHookEvent(
        name: String?,
        event: [String: Any]?,
        sessionID: UUID?,
        session: PtySession?,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard name == "PermissionRequest" else {
            // A non-blocking event: record what it says about the agent, then
            // answer `{}` at once because nothing waits on it. `PreToolUse`
            // is the `working` edge — the agent is about to run a tool, which
            // clears a stale "needs input"; it fires for every tool call,
            // allowed or not, which is exactly why it must never be the held
            // one. `Notification` means the agent wants the human; `Stop`
            // means its turn finished. Anything else is noted by neither — an
            // unknown event degrades to "no opinion", as it always did.
            if let sessionID, let session {
                switch name {
                case "PreToolUse":
                    session.recordAgentStatus(.working, message: nil)
                    emitAgentStatus(sessionID, report: .working, message: nil)
                case "Notification":
                    let message = (event?["message"] as? String)
                        .map { String($0.prefix(KittermConstants.maxSessionNoteLength)) }
                    session.recordAgentStatus(.needsInput, message: message)
                    emitAgentStatus(sessionID, report: .needsInput, message: message)
                case "Stop":
                    session.recordAgentStatus(.completed, message: nil)
                    emitAgentStatus(sessionID, report: .completed, message: nil)
                default:
                    break
                }
            }
            writeJSON(
                status: .ok, body: "{}",
                context: context, version: head.version, keepAlive: head.isKeepAlive
            )
            return
        }

        let toolName = event?["tool_name"] as? String ?? "unknown"
        let toolInput = (event?["tool_input"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"

        // Claude would show a permission dialog now. It only fires for a tool
        // the session would actually have asked about — an auto-allowed one
        // never gets here — so the hold below slows nothing that would not
        // have waited on a human anyway. It never fires in `claude -p`, which
        // refuses instead of asking; a non-interactive crew wants
        // `--dangerously-skip-permissions` or `--allowedTools`, not a hold.
        let requested = DaemonServer.queryValue("timeout", fromRequestURI: head.uri)
            .flatMap(Int.init) ?? KittermConstants.approvalHoldDefaultSeconds
        let hold = max(1, min(requested, KittermConstants.approvalHoldMaxSeconds))

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let (id, decision) = approvals.register(
            sessionID: sessionID,
            toolName: toolName,
            toolInput: toolInput,
            on: loop
        )
        // A tool call is now blocked on a human — wake anyone parked on the
        // feed so "needs approval" reaches a foreman at once.
        if let sessionID {
            eventLog.append(
                type: "approval.pending",
                session: sessionID,
                data: ["tool": toolName]
            )
        }
        // The store is the mutual exclusion: resolve and expire both remove the
        // entry first, so exactly one of them completes the promise.
        let timeoutTask = loop.scheduleTask(in: .seconds(Int64(hold))) {
            self.approvals.expire(id: id)
        }
        decision.whenComplete { result in
            timeoutTask.cancel()
            let context = boundContext.value
            let verdict = (try? result.get()) ?? nil
            self.writeJSON(
                status: .ok,
                body: Self.hookResponse(for: verdict),
                context: context, version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// The verdict in the shape Claude Code reads for `PermissionRequest`
    /// (`hookSpecificOutput.decision {behavior, message}` — verified against
    /// 2.1.260: allow ran the tool, deny refused it with the message shown).
    /// No decision is an empty object on purpose: the agent then shows its own
    /// dialog in its pane, which is what should happen when nobody answered.
    static func hookResponse(for decision: ApprovalStore.Decision?) -> String {
        guard let decision else { return "{}" }
        var verdict: [String: Any]
        switch decision {
        case .allow:
            verdict = ["behavior": "allow"]
        case .deny(let why):
            verdict = ["behavior": "deny"]
            // Shown to the agent verbatim, so a reason is worth writing.
            if let why, !why.isEmpty { verdict["message"] = why }
        }
        let specific: [String: Any] = [
            "hookEventName": "PermissionRequest",
            "decision": verdict,
        ]
        let payload: [String: Any] = ["hookSpecificOutput": specific]
        return (try? JSONSerialization.data(withJSONObject: payload))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Everything waiting on a human, for the fleet view.
    private func serveApprovals(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let items: [[String: Any]] = approvals.snapshot().map { pending in
            var item: [String: Any] = [
                "id": pending.id,
                "tool": pending.toolName,
                "input": pending.toolInput,
                "waitingMs": Int(Date().timeIntervalSince(pending.createdAt) * 1000),
            ]
            if let sessionID = pending.sessionID {
                item["session"] = sessionID.uuidString
            }
            return item
        }
        let text = (try? JSONSerialization.data(withJSONObject: ["ok": true, "approvals": items]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok":true,"approvals":[]}"#
        writeJSON(
            status: .ok, body: text,
            context: context, version: head.version, keepAlive: head.isKeepAlive
        )
    }

    /// Answer one. Full grade only — deciding for an agent is a human
    /// privilege, and a watch token exists precisely to withhold it.
    private func serveApprovalDecision(
        path: String,
        body: Data,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "approvals", "<id>"]
        guard components.count == 3 else {
            notFound(context: context, version: head.version)
            return
        }
        let id = String(components[2])
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = payload?["reason"] as? String
        let decision: ApprovalStore.Decision
        switch payload?["decision"] as? String {
        case "allow": decision = .allow(reason: reason)
        case "deny": decision = .deny(reason: reason)
        default:
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"decision must be \"allow\" or \"deny\""}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        // The session behind this approval, read before it is resolved away, so
        // the resolved event can name it. Same loop, so no race.
        let approvalSession = approvals.snapshot().first { $0.id == id }?.sessionID
        guard approvals.resolve(id: id, decision: decision) else {
            // Unknown, already answered, or expired — indistinguishable from
            // out here, and all of them mean "too late".
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"no such pending approval"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let verdict: String
        switch decision {
        case .allow: verdict = "allow"
        case .deny: verdict = "deny"
        }
        eventLog.append(
            type: "approval.resolved",
            session: approvalSession,
            data: ["decision": verdict]
        )
        writeJSON(
            status: .ok, body: #"{"ok":true}"#,
            context: context, version: head.version, keepAlive: head.isKeepAlive
        )
    }

    /// `POST /api/sessions/<uuid>/input` — write the request body verbatim to
    /// the shell's input, as if typed. The body is raw bytes: include your own
    /// newline to submit a command, send `\x03` for Ctrl-C, etc. Capped at
    /// `maxInputBytes`.
    ///
    /// `?enter=1` presses Enter after the body, as whoever reads the terminal
    /// expects it: a line feed for the shell, a settled carriage return for a
    /// program that took the foreground (`PtySession.typeLine`). A caller
    /// that types into an interactive `claude` needs this — its prompt keeps
    /// a bare `\n` as text — and a foreman cannot tell from outside what is
    /// reading. The body may be empty then: Enter alone answers a dialog.
    ///
    /// This is the one write route. It is off unless the daemon was started
    /// with `--agent-control`, and even then sits behind the same access policy
    /// as every other route — a caller the policy admits can drive any shell as
    /// the invoking user. Input interleaves with whatever a human controller is
    /// typing; there is no separate role.
    private func serveInput(
        path: String,
        body: Data,
        bodyOverflow: Bool,
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        // The one write route: full grade only, on top of the opt-in flag.
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard agentControl else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"agent control disabled; start the daemon with --agent-control"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let components = path.split(separator: "/")
        // ["api", "sessions", "<uuid>", "input"]
        guard components.count == 4, let id = UUID(uuidString: String(components[2])) else {
            notFound(context: context, version: head.version)
            return
        }
        if bodyOverflow {
            writeJSON(
                status: .payloadTooLarge,
                body: #"{"ok":false,"error":"input exceeds \#(KittermConstants.maxInputBytes) bytes"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let pressEnter = DaemonServer.queryValue("enter", fromRequestURI: head.uri)
            .map { $0 == "1" || $0 == "true" } ?? false
        guard !body.isEmpty || pressEnter else {
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"empty body"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }

        enum Outcome { case ok(Int); case noSession; case closed }
        let promise = context.eventLoop.makePromise(of: Outcome.self)
        promise.completeWithTask {
            guard let session = await self.registry.session(id) else { return .noSession }
            do {
                if pressEnter { return .ok(try await session.typeLine(body)) }
                session.noteSubmittedCommand(body)
                try session.write(body)
                return .ok(body.count)
            } catch {
                return .closed
            }
        }
        promise.futureResult.whenComplete { result in
            switch (try? result.get()) ?? .closed {
            case .ok(let count):
                self.writeJSON(
                    status: .ok,
                    body: #"{"ok":true,"bytes":\#(count)}"#,
                    context: context, version: head.version, keepAlive: head.isKeepAlive
                )
            case .noSession:
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
            case .closed:
                self.writeJSON(
                    status: .conflict,
                    body: #"{"ok":false,"error":"session closed"}"#,
                    context: context, version: head.version, keepAlive: false
                )
            }
        }
    }

    /// Shared 404 JSON.
    private func notFound(context: ChannelHandlerContext, version: HTTPVersion) {
        writeJSON(
            status: .notFound,
            body: #"{"ok":false,"error":"not found"}"#,
            context: context, version: version, keepAlive: false
        )
    }

    /// `GET /api/profiles` — the user's named session profiles, so the fleet
    /// page can offer one-click "new session as <profile>" launchers. Same
    /// trust boundary as the session list: the file is the caller's own config
    /// (commands included), and the policy already gates who may ask.
    ///
    /// Synchronous read of a tiny local file on the event loop — the same
    /// class of I/O as static file serving, and only on explicit request.
    private func serveProfiles(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let items: [[String: Any]] = SessionProfiles.load().map { profile in
            var item: [String: Any] = [
                "name": profile.name,
                "command": profile.command,
            ]
            if let cwd = profile.cwd { item["cwd"] = cwd }
            return item
        }
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "profiles": items]),
           let text = String(data: data, encoding: .utf8) {
            body = text
        } else {
            body = #"{"ok":false,"error":"encoding failed"}"#
        }
        writeJSON(
            status: .ok,
            body: body,
            context: context,
            version: head.version,
            keepAlive: head.isKeepAlive
        )
    }

    private static func markKindName(_ kind: MarkKind) -> String {
        switch kind {
        case .promptStart: return "promptStart"
        case .commandStart: return "commandStart"
        case .preExec: return "preExec"
        case .commandEnd: return "commandEnd"
        }
    }

    private func serveStatic(
        path: String,
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        authCookie: String? = nil,
        secureCookie: Bool = false
    ) {
        guard let root = staticRoot else {
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"web client not built; run pnpm build in Web/terminal"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
            return
        }
        guard let file = StaticFileServer.file(for: path, root: root),
              let data = try? Data(contentsOf: file.url)
        else {
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: file.contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Cache-Control", value: path == "/" || path.hasSuffix(".html")
            ? "no-cache"
            : "public, max-age=3600")
        headers.add(name: "Connection", value: head.isKeepAlive ? "keep-alive" : "close")
        // The cookie carries exactly the token that was presented — a watch
        // token must never be upgraded to the control cookie.
        if let authCookie {
            headers.add(
                name: "Set-Cookie",
                value: AccessPolicy.setCookieHeaderValue(for: authCookie, secure: secureCookie)
            )
        }

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !head.isKeepAlive {
                context.close(promise: nil)
            }
        }
    }

    private func uriPath(_ uri: String) -> String {
        if let q = uri.firstIndex(of: "?") {
            return String(uri[..<q])
        }
        return uri
    }

    /// True when the client asked for a page rather than data — i.e. a browser
    /// navigation. Anything else (fetch, curl, the fleet page's polling) keeps
    /// the JSON error it has always had.
    static func wantsHTML(_ headers: HTTPHeaders) -> Bool {
        headers["accept"].contains { $0.contains("text/html") }
    }

    /// The 403 page: one field, submitted as a plain GET so the token arrives
    /// as `?token=` on the next request and the normal path sets the cookie.
    /// No script, because this page is what a locked-out client sees and it has
    /// to work before anything else does.
    static func tokenPromptPage(reason: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>kitterm — token required</title>
        <style>
          :root { color-scheme: dark }
          body { margin:0; min-height:100vh; display:flex; align-items:center;
                 justify-content:center; padding:24px;
                 background:#0d1117; color:#e6edf3;
                 font:16px/1.5 system-ui,-apple-system,sans-serif }
          main { width:min(100%,360px) }
          h1 { margin:0 0 6px; font-size:19px; font-weight:600 }
          p { margin:0 0 18px; color:#8b97a6; font-size:14px }
          form { display:flex; flex-direction:column; gap:10px }
          input { width:100%; box-sizing:border-box; padding:11px 12px;
                  border:1px solid #2b3440; border-radius:8px;
                  background:#161b22; color:#e6edf3;
                  /* 16px or iOS zooms the page when the field takes focus. */
                  font:16px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace }
          input:focus { outline:none; border-color:#58a6ff }
          button { padding:12px; border:0; border-radius:8px;
                   background:#58a6ff; color:#fff; font:600 15px/1 system-ui;
                   cursor:pointer }
        </style></head>
        <body><main>
          <h1>kitterm needs a token</h1>
          <p>\(escapeHTML(reason)). Paste an access token to continue &#8212; this device will stay signed in.</p>
          <form method="get" action="/">
            <input name="token" type="password" inputmode="text" autocomplete="off"
                   autocorrect="off" autocapitalize="off" spellcheck="false"
                   placeholder="access token" aria-label="Access token" autofocus>
            <button type="submit">Continue</button>
          </form>
        </main></body></html>
        """
    }

    /// Minimal escaping for the one interpolated string above.
    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writeHTML(
        status: HTTPResponseStatus,
        body: String,
        context: ChannelHandlerContext,
        version: HTTPVersion
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(
            version: version, status: status, headers: headers
        ))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Does each of these paths name anything?
    ///
    /// The client asks before it draws a path in output as a link, because a link
    /// that opens nothing is worse than plain text. It asks about a whole screen
    /// at once: a screen can name files in many directories, and confirming each
    /// through `/api/files` would ship those directories' contents across the wire
    /// just to underline a word.
    ///
    /// Same access story as the listing it sits beside — full grade, no allowlist,
    /// the OS decides what is visible — because this answers strictly less than
    /// the listing already does.
    private func serveFileStat(
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        // Repeated `path=` rather than one delimited value: a path may contain
        // any byte except NUL, so there is no separator left to split on.
        let requested = DaemonServer.queryValues("path", fromRequestURI: head.uri)
        guard !requested.isEmpty else {
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"no path given"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let capped = Array(requested.prefix(KittermConstants.maxStatBatch))
        let sessionID = DaemonServer.queryValue("session", fromRequestURI: head.uri)
            .flatMap(UUID.init(uuidString:))

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: [FileBrowser.Stat].self)
        promise.completeWithTask {
            // Bound to a `let` before the hop: a `var` captured by the closure
            // below is a data race, and only the stricter toolchain says so.
            let cwd: String? = sessionID == nil
                ? nil
                : await self.registry.session(sessionID!)?.liveCwd
            // Off the event loop: a stat can block on a stalled mount, and the
            // loop is shared with every session's output.
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: FileBrowser.stat(capped, base: cwd))
                }
            }
        }
        promise.futureResult.whenComplete { result in
            let context = boundContext.value
            guard case .success(let stats) = result else {
                self.writeJSON(
                    status: .internalServerError,
                    body: #"{"ok":false,"error":"stat failed"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            let payload: [String: Any] = [
                "ok": true,
                "paths": stats.map { stat -> [String: Any] in
                    var item: [String: Any] = ["path": stat.requested, "exists": stat.exists]
                    if stat.exists {
                        item["dir"] = stat.isDirectory
                        item["resolved"] = stat.resolved
                    }
                    return item
                },
            ]
            let text = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"ok":false,"error":"encoding failed"}"#
            self.writeJSON(
                status: .ok, body: text, context: context,
                version: head.version, keepAlive: head.isKeepAlive
            )
        }
    }

    /// A file's bytes, for previewing what a path in output points at.
    ///
    /// Reading is not the risk: a full token can already type `cat`. The risk is
    /// the browser, because this is served from kitterm's own origin — a file
    /// returned as `text/html` or `image/svg+xml` would run its script against
    /// the auth cookie. `FilePreview` therefore never honours a file's own type,
    /// and the headers here say so a second time: nothing is sniffed, nothing
    /// may load, and anything unrecognised is a download rather than a render.
    private func serveFileContent(
        grade: TokenGrade,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard grade == .full else {
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"watch-only token"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        guard let requested = DaemonServer.queryValue("path", fromRequestURI: head.uri) else {
            writeJSON(
                status: .badRequest,
                body: #"{"ok":false,"error":"no path given"}"#,
                context: context, version: head.version, keepAlive: false
            )
            return
        }
        let sessionID = DaemonServer.queryValue("session", fromRequestURI: head.uri)
            .flatMap(UUID.init(uuidString:))

        let loop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        let promise = loop.makePromise(of: FilePreview.Payload?.self)
        promise.completeWithTask {
            let cwd: String? = sessionID == nil
                ? nil
                : await self.registry.session(sessionID!)?.liveCwd
            let url = FileBrowser.resolve(requested, base: cwd)
            // Off the loop: reading a file blocks, and the loop carries every
            // session's output.
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: try? FilePreview.read(url))
                }
            }
        }
        promise.futureResult.whenComplete { result in
            let context = boundContext.value
            guard case .success(.some(let payload)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"cannot read that file"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: payload.contentType)
            headers.add(name: "Content-Length", value: String(payload.data.count))
            // Never guess past what we chose, never let the response fetch
            // anything, and never let it be framed.
            headers.add(name: "X-Content-Type-Options", value: "nosniff")
            headers.add(name: "Content-Security-Policy", value: "default-src 'none'; sandbox")
            headers.add(name: "Cache-Control", value: "no-store")
            let safeName = FilePreview.headerSafeName(payload.filename)
            headers.add(
                name: "Content-Disposition",
                value: (payload.attachment ? "attachment" : "inline") + "; filename=\"\(safeName)\""
            )
            // Same truncation contract as the command-output route.
            headers.add(name: "X-Kitterm-Total-Bytes", value: "\(payload.totalBytes)")
            headers.add(name: "X-Kitterm-Truncated", value: payload.truncated ? "1" : "0")
            headers.add(name: "X-Kitterm-Kind", value: payload.kind)

            context.write(self.wrapOutboundOut(.head(HTTPResponseHead(
                version: head.version, status: .ok, headers: headers
            ))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: payload.data.count)
            buffer.writeBytes(payload.data)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                if !head.isKeepAlive { context.close(promise: nil) }
            }
        }
    }

    private func writeJSON(
        status: HTTPResponseStatus,
        body: String,
        context: ChannelHandlerContext,
        version: HTTPVersion,
        keepAlive: Bool
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let head = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive {
                context.close(promise: nil)
            }
        }
    }
}
