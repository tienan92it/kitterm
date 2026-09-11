import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// The browser's half of Web Push, for a test: the P-256 pair and the
/// `auth` secret a real `pushManager.subscribe` would mint, and the RFC 8291
/// decryption that a real browser does before it hands the payload to the
/// service worker. A message the test can read is a message a phone can.
struct FakeBrowser {
    let privateKey = P256.KeyAgreement.PrivateKey()
    let authSecret = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })

    var p256dh: String { WebPush.base64URL(privateKey.publicKey.x963Representation) }
    var auth: String { WebPush.base64URL(authSecret) }

    func subscription(endpoint: String) -> PushSubscription {
        PushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth, createdAt: 0)
    }

    /// The body a page posts to `POST /api/push/subscriptions`.
    func subscriptionJSON(endpoint: String) -> String {
        #"{"endpoint":"\#(endpoint)","expirationTime":null,"keys":{"p256dh":"\#(p256dh)","auth":"\#(auth)"}}"#
    }

    /// RFC 8188 header, then RFC 8291 key derivation, then AES-128-GCM.
    func decrypt(_ body: Data) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count > 21 else { throw Failure("body too short: \(bytes.count)") }
        let salt = Data(bytes[0 ..< 16])
        let recordSize = UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
        let keyLength = Int(bytes[20])
        guard keyLength == 65, bytes.count >= 21 + keyLength + 16 else {
            throw Failure("keyid length \(keyLength), body \(bytes.count)")
        }
        let senderPublicRaw = Data(bytes[21 ..< 21 + keyLength])
        let sealedBytes = Data(bytes[(21 + keyLength)...])
        guard sealedBytes.count <= Int(recordSize) else { throw Failure("record over rs=\(recordSize)") }
        let senderPublic = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicRaw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: senderPublic)
        var keyInfo = Data("WebPush: info\u{0}".utf8)
        keyInfo.append(privateKey.publicKey.x963Representation)
        keyInfo.append(senderPublicRaw)
        let inputKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32
        )
        let contentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey, salt: salt,
            info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey, salt: salt,
            info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12
        )
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })
        let ciphertext = sealedBytes.dropLast(16)
        let tag = sealedBytes.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        var record = try AES.GCM.open(box, using: contentKey)
        // Strip the padding: the last record ends in 0x02, after any zeros.
        while let last = record.last, last == 0 { record.removeLast() }
        guard record.last == 0x02 else { throw Failure("no last-record delimiter") }
        record.removeLast()
        return record
    }

    /// The decrypted payload as the service worker would read it.
    func payload(_ body: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try decrypt(body)) as? [String: Any])
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The push service's side, over real HTTP on loopback: records every POST
/// and answers with the status configured for that path, so one fake can
/// play a phone that is reachable and one whose subscription is gone.
final class FakePushService: @unchecked Sendable {
    struct Received: Sendable {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel!
    private let lock = NSLock()
    private var received: [Received] = []
    private var statusByPath: [String: Int] = [:]

    var port: Int { channel.localAddress!.port! }
    var origin: String { "http://127.0.0.1:\(port)" }

    func start() throws {
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Handler(service: self))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    func stop() async {
        try? channel?.close().wait()
        try? await group.shutdownGracefully()
    }

    /// What the service answers a POST to `path`; 201 unless set.
    func answer(_ path: String, with status: Int) {
        lock.withLock { statusByPath[path] = status }
    }

    var requests: [Received] { lock.withLock { received } }

    func requests(to path: String) -> [Received] { requests.filter { $0.path == path } }

    fileprivate func record(_ request: Received) -> Int {
        lock.withLock {
            received.append(request)
            return statusByPath[request.path] ?? 201
        }
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let service: FakePushService
        private var head: HTTPRequestHead?
        private var body = Data()

        init(service: FakePushService) { self.service = service }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body.removeAll()
            case .body(let buffer):
                body.append(contentsOf: buffer.readableBytesView)
            case .end:
                guard let head else { return }
                var headers: [String: String] = [:]
                for (name, value) in head.headers { headers[name.lowercased()] = value }
                let status = service.record(Received(path: head.uri, headers: headers, body: body))
                var responseHead = HTTPResponseHead(version: head.version, status: .init(statusCode: status))
                responseHead.headers.add(name: "content-length", value: "0")
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                self.head = nil
            }
        }
    }
}
