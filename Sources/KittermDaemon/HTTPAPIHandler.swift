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
    private var pendingHead: HTTPRequestHead?
    /// Accumulated request body, capped at `maxInputBytes`; only the input
    /// route reads it. `bodyOverflow` trips once the cap is exceeded so a large
    /// upload can't grow this unbounded — the route then answers 413.
    private var pendingBody: [UInt8] = []
    private var bodyOverflow = false

    init(
        registry: SessionRegistry,
        policy: AccessPolicy = .loopbackOnly,
        port: Int = KittermConstants.defaultPort,
        agentControl: Bool = false,
        staticRoot: URL? = StaticFileServer.cachedRoot
    ) {
        self.registry = registry
        self.policy = policy
        self.port = port
        self.agentControl = agentControl
        self.staticRoot = staticRoot
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
            pendingBody.removeAll(keepingCapacity: true)
            bodyOverflow = false
        case .body(let buffer):
            guard !bodyOverflow else { break }
            if pendingBody.count + buffer.readableBytes > KittermConstants.maxInputBytes {
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
            handle(head: head, body: body, bodyOverflow: overflow, context: context)
        }
    }

    private func handle(
        head: HTTPRequestHead,
        body: Data,
        bodyOverflow: Bool,
        context: ChannelHandlerContext
    ) {
        var setAuthCookie = false
        switch policy.decide(
            remote: context.channel.remoteAddress,
            headers: head.headers,
            uri: head.uri
        ) {
        case .allow:
            break
        case .allowSettingCookie:
            setAuthCookie = true
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
        case (.GET, "/api/lan"):
            // Share-link support: the LAN base URL, plus the token — but only
            // for loopback callers (the machine's own user).
            let body: String
            if policy.lanEnabled, let ip = NetworkInterfaces.primaryLANIPv4() {
                let isLocal = AccessPolicy.isLoopback(context.channel.remoteAddress)
                let tokenField = isLocal && policy.token != nil
                    ? #","token":"\#(policy.token!)""#
                    : ""
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
            serveProfiles(head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/marks"):
            serveMarks(path: path, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/commands"):
            serveCommands(path: path, head: head, context: context)
        case (.GET, _)
            where path.hasPrefix("/api/sessions/") && path.contains("/commands/")
                && path.hasSuffix("/output"):
            serveCommandOutput(path: path, head: head, context: context)
        case (.POST, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/input"):
            serveInput(
                path: path,
                body: body,
                bodyOverflow: bodyOverflow,
                head: head,
                context: context
            )
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
            serveStatic(path: "/sessions.html", head: head, context: context, setAuthCookie: setAuthCookie)
        case (.GET, _):
            serveStatic(path: path, head: head, context: context, setAuthCookie: setAuthCookie)
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

    /// `GET /api/sessions` — every live session with its mark-derived state.
    /// The supervision surface: which shells are running, idle, or waiting,
    /// and what each last ran. Read-only.
    private func serveSessions(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: [SessionRegistry.SessionSummary].self)
        promise.completeWithTask {
            await self.registry.summaries()
        }
        promise.futureResult.whenComplete { result in
            let summaries = (try? result.get()) ?? []
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
        let promise = context.eventLoop.makePromise(of: [SessionMark]?.self)
        promise.completeWithTask { await self.registry.session(id)?.marksSnapshot() }
        promise.futureResult.whenComplete { result in
            guard case .success(.some(let marks)) = result else {
                self.writeJSON(
                    status: .notFound,
                    body: #"{"ok":false,"error":"no such session"}"#,
                    context: context, version: head.version, keepAlive: false
                )
                return
            }
            let items: [[String: Any]] = SessionCommands.pair(from: marks).map { cmd in
                var item: [String: Any] = [
                    "index": cmd.index,
                    "startOffset": cmd.startOffset,
                    "running": cmd.running,
                ]
                if let command = cmd.command { item["command"] = command }
                if let exit = cmd.exit { item["exit"] = exit }
                if let end = cmd.endOffset { item["endOffset"] = end }
                return item
            }
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
            let commands = SessionCommands.pair(from: session.marksSnapshot())
            guard index <= commands.count else { return nil }
            let cmd = commands[index - 1]
            // A running command has no end yet — read up to the current head.
            let end = cmd.endOffset ?? UInt64.max
            return session.outputRange(from: cmd.startOffset, to: end, maxBytes: cap)
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
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
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
        setAuthCookie: Bool = false
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
        if setAuthCookie, let cookie = policy.setCookieHeaderValue {
            headers.add(name: "Set-Cookie", value: cookie)
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
