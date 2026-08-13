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
            writeJSON(
                status: .forbidden,
                body: #"{"ok":false,"error":"\#(reason)"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
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
        case (.DELETE, _) where path.hasPrefix("/api/sessions/"):
            serveDelete(path: path, grade: grade, head: head, context: context)
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
        case (.POST, "/api/hooks"):
            serveHook(
                body: body,
                bodyOverflow: bodyOverflow,
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
            let items: [[String: Any]] = summaries.map { summary in
                let derived = DerivedSessionState.derive(from: summary.marks)
                var item: [String: Any] = [
                    "id": summary.id.uuidString,
                    "shell": summary.shell,
                    "cwd": summary.cwd,
                    "pid": summary.pid,
                    "attached": summary.attached,
                    "observers": summary.observerCount,
                    "state": derived.state.rawValue,
                    "marks": summary.marks.count,
                ]
                if let command = derived.lastCommand { item["lastCommand"] = command }
                if let exit = derived.lastExit { item["lastExit"] = exit }
                if let profile = summary.profile { item["profile"] = profile }
                if !summary.labels.isEmpty { item["labels"] = summary.labels }
                if summary.exited {
                    // Kept only so its records can still be read.
                    item["exited"] = true
                    if let code = summary.exitCode { item["exitCode"] = Int(code) }
                }
                return item
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

    // MARK: - Agent hooks and approvals

    /// Receive a Claude Code hook event.
    ///
    /// Configured as `"type": "http"` in settings.json, so the agent POSTs the
    /// event here and reads its verdict from *this response body* — status
    /// codes cannot block a tool call, only the JSON can. Schema per the hooks
    /// reference as of 2026-08 (`PreToolUse` blocks; `Notification` is
    /// informational and its output is discarded).
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
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
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

        guard name == "PreToolUse" else {
            // Accepted so one hook config can cover both events, and answered
            // at once because nothing waits on these. `Notification` is not
            // rendered anywhere yet — that is the next piece, not a promise
            // this route already keeps.
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

    /// The verdict in the shape Claude Code reads. No decision is an empty
    /// object on purpose: the agent then runs its normal permission flow and
    /// asks in its own pane, which is what should happen when nobody answered.
    static func hookResponse(for decision: ApprovalStore.Decision?) -> String {
        guard let decision else { return "{}" }
        let permission: String
        let reason: String?
        switch decision {
        case .allow(let why): permission = "allow"; reason = why
        case .deny(let why): permission = "deny"; reason = why
        }
        var specific: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": permission,
        ]
        if let reason, !reason.isEmpty {
            specific["permissionDecisionReason"] = reason
        }
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
        guard !body.isEmpty else {
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
