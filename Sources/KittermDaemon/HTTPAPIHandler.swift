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
    private var pendingHead: HTTPRequestHead?

    init(
        registry: SessionRegistry,
        policy: AccessPolicy = .loopbackOnly,
        port: Int = KittermConstants.defaultPort,
        staticRoot: URL? = StaticFileServer.cachedRoot
    ) {
        self.registry = registry
        self.policy = policy
        self.port = port
        self.staticRoot = staticRoot
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
        case .body:
            break
        case .end:
            guard let head = pendingHead else { return }
            pendingHead = nil
            handle(head: head, context: context)
        }
    }

    private func handle(head: HTTPRequestHead, context: ChannelHandlerContext) {
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
        case (.GET, _) where path.hasPrefix("/api/sessions/") && path.hasSuffix("/marks"):
            serveMarks(path: path, head: head, context: context)
        case (.GET, _) where path.hasPrefix("/api/"):
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
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
