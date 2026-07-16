import Foundation
import KittermProtocol
import NIOCore
import NIOHTTP1

final class HTTPAPIHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let registry: SessionRegistry
    private let staticRoot: URL?
    private var pendingHead: HTTPRequestHead?

    init(registry: SessionRegistry, staticRoot: URL? = StaticFileServer.resolveRoot()) {
        self.registry = registry
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
        let (host, origin) = LoopbackSecurity.hostAndOrigin(from: head.headers)
        if let reason = LoopbackSecurity.rejectionReason(hostHeader: host, originHeader: origin) {
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
        case (.GET, _) where path.hasPrefix("/api/"):
            writeJSON(
                status: .notFound,
                body: #"{"ok":false,"error":"not found"}"#,
                context: context,
                version: head.version,
                keepAlive: false
            )
        case (.GET, _):
            serveStatic(path: path, head: head, context: context)
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

    private func serveStatic(path: String, head: HTTPRequestHead, context: ChannelHandlerContext) {
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
