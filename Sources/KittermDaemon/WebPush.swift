#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto: the same P256, HKDF and AES.GCM where the framework is absent.
import Crypto
#endif
import Foundation

/// The daemon's VAPID key pair (RFC 8292): the identity a push service holds
/// the daemon to. A phone subscribes with the public key, and every message
/// carries a token signed with the private one.
///
/// ## Its own file
///
/// The pair lives in `~/.kitterm/vapid.json` at `0600`, not in `push.json`.
/// A subscription's keys are the browser's own, and the file that holds them
/// deliberately holds nothing else. The VAPID private key is a daemon secret
/// of another class: whoever holds it can send to every phone that
/// subscribed with its public half.
///
/// ## Why it must persist
///
/// A browser binds its subscription to the `applicationServerKey` it was
/// given. A daemon that generated a fresh pair on every start would find
/// every push service answering `403` to every stored subscription after
/// the first restart, so the pair is generated once and reused, the way
/// `PersistedToken` keeps the LAN token. A file that is not owner-only is
/// replaced rather than trusted, and the replacement is logged, because it
/// invalidates every subscription on every phone.
public struct VAPIDKeys: Sendable {
    public static let formatVersion = 1
    /// What the signed token names as its contact (RFC 8292 §2.1).
    public static let subject = "mailto:kitterm@localhost"
    /// How long a signed token is good for. The RFC caps it at 24 hours.
    public static let tokenLifetimeSeconds: TimeInterval = 12 * 3600

    private struct FileShape: Codable {
        var version: Int
        /// The 32-byte private scalar, base64url.
        var privateKey: String
    }

    let privateKey: P256.Signing.PrivateKey

    public init() {
        self.privateKey = P256.Signing.PrivateKey()
    }

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// The uncompressed public point (65 bytes), base64url: what the page
    /// hands `pushManager.subscribe` as `applicationServerKey`, and what the
    /// `k=` parameter of every `Authorization` header carries.
    public var publicKeyBase64URL: String {
        WebPush.base64URL(privateKey.publicKey.x963Representation)
    }

    /// The pair stored at `url`, or a fresh one written there. Throws when
    /// the file cannot be written: a pair the next run will not find is
    /// worse than no push at all, because it would bind every phone to a key
    /// the daemon then loses.
    public static func loadOrCreate(at url: URL) throws -> VAPIDKeys {
        if let existing = read(from: url) { return existing }
        let fresh = VAPIDKeys()
        try fresh.write(to: url)
        return fresh
    }

    /// The pair in the file, or nil when the file is absent, not owner-only,
    /// a version this build was not built for, or not a P-256 key. Every
    /// refusal but absence is logged, because the caller then replaces a
    /// key every phone is bound to.
    static func read(from url: URL) -> VAPIDKeys? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard PersistedToken.isOwnerOnly(url) else {
            FileHandle.standardError.write(Data(
                "kitterm: replacing \(url.path): not owner-only; every push subscription must be made again\n".utf8
            ))
            return nil
        }
        do {
            let shape = try JSONDecoder().decode(FileShape.self, from: data)
            guard shape.version == formatVersion else {
                FileHandle.standardError.write(Data(
                    "kitterm: replacing \(url.path): format version \(shape.version), expected \(formatVersion)\n".utf8
                ))
                return nil
            }
            guard let raw = WebPush.base64URLDecode(shape.privateKey) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "privateKey is not base64url"))
            }
            return VAPIDKeys(privateKey: try P256.Signing.PrivateKey(rawRepresentation: raw))
        } catch {
            FileHandle.standardError.write(Data("kitterm: replacing \(url.path): \(error)\n".utf8))
            return nil
        }
    }

    /// Whole-file atomic replace, then owner-only: the order `push.json` and
    /// `tokens.json` use.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FileShape(
            version: Self.formatVersion, privateKey: WebPush.base64URL(privateKey.rawRepresentation)
        ))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The `Authorization` header for a message to `endpoint`: a JWT over
    /// the endpoint's origin, signed ES256, beside the public key the push
    /// service checks it with (RFC 8292 §3). Nil when the endpoint has no
    /// origin to name.
    public func authorization(for endpoint: URL, now: Date = Date()) -> String? {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { return nil }
        var audience = "\(scheme)://\(host)"
        if let port = endpoint.port { audience += ":\(port)" }
        let header = WebPush.base64URL(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
        let expiry = Int(now.addingTimeInterval(Self.tokenLifetimeSeconds).timeIntervalSince1970)
        // Hand-assembled so the key order is fixed and no serializer escapes
        // the slashes in the audience.
        let claims = WebPush.base64URL(Data(
            #"{"aud":"\#(audience)","exp":\#(expiry),"sub":"\#(Self.subject)"}"#.utf8
        ))
        let signingInput = Data("\(header).\(claims)".utf8)
        guard let signature = try? privateKey.signature(for: signingInput) else { return nil }
        let token = "\(header).\(claims).\(WebPush.base64URL(signature.rawRepresentation))"
        return "vapid t=\(token), k=\(publicKeyBase64URL)"
    }
}

/// The wire shape of one Web Push message: the body encrypted for one
/// browser (RFC 8291, `aes128gcm` from RFC 8188) and the headers the push
/// service reads. Pure functions; the sender assembles the request.
public enum WebPush {
    /// The single-record size written into the header. One message is a few
    /// hundred bytes, so the body is always one record.
    static let recordSize: UInt32 = 4096
    /// Padding the RFC requires between the plaintext and the record's end:
    /// a `0x02` delimiter marks the last record.
    private static let lastRecordDelimiter: UInt8 = 0x02

    public struct EncryptionFailure: Error, Equatable, Sendable {
        public let reason: String
    }

    /// `payload` sealed for the browser whose subscription carries `p256dh`
    /// and `auth`, as the request body: salt, record size, the daemon's
    /// ephemeral public key, then the ciphertext and its tag.
    ///
    /// One ephemeral key pair per message, as the RFC requires: the shared
    /// secret is derived from it and the browser's `p256dh`, then run through
    /// HKDF twice, once with `auth` for the input key and once with the salt
    /// for the content key and the nonce.
    public static func encrypt(_ payload: Data, p256dh: String, auth: String) throws -> Data {
        guard let receiverRaw = base64URLDecode(p256dh),
              let receiver = try? P256.KeyAgreement.PublicKey(x963Representation: receiverRaw)
        else {
            throw EncryptionFailure(reason: "p256dh is not an uncompressed P-256 point")
        }
        guard let authSecret = base64URLDecode(auth), authSecret.count == 16 else {
            throw EncryptionFailure(reason: "auth is not 16 bytes")
        }
        guard payload.count + 1 <= Int(recordSize) - 16 else {
            throw EncryptionFailure(reason: "payload over one record")
        }
        let sender = P256.KeyAgreement.PrivateKey()
        let senderPublic = sender.publicKey.x963Representation
        let shared: SharedSecret
        do {
            shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        } catch {
            throw EncryptionFailure(reason: "key agreement failed: \(error)")
        }
        // RFC 8291 §3.3: IKM = HKDF(auth, ecdh_secret, "WebPush: info" || 0x00 || ua_public || as_public, 32).
        var keyInfo = Data("WebPush: info\u{0}".utf8)
        keyInfo.append(receiverRaw)
        keyInfo.append(senderPublic)
        let inputKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32
        )
        // RFC 8188 §2.2: CEK and NONCE from the input key and a fresh salt.
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8.random(in: .min ... .max) }
        }
        let contentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey, salt: salt,
            info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16
        )
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey, salt: salt,
            info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12
        )
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })
        } catch {
            throw EncryptionFailure(reason: "nonce derivation failed: \(error)")
        }
        var record = payload
        record.append(lastRecordDelimiter)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(record, using: contentKey, nonce: nonce)
        } catch {
            throw EncryptionFailure(reason: "seal failed: \(error)")
        }
        // RFC 8188 §2.1 header: salt(16) rs(4) idlen(1) keyid(65), then the record.
        var body = salt
        var recordSizeBE = recordSize.bigEndian
        withUnsafeBytes(of: &recordSizeBE) { body.append(contentsOf: $0) }
        body.append(UInt8(senderPublic.count))
        body.append(senderPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// The headers every message carries beside `Authorization`. `TTL` is how
    /// long the push service holds the message for a phone that is off; a
    /// session that needed a human an hour ago most likely still does, and
    /// one that does not is a tap that opens a pane that has moved on.
    public static func headers(ttlSeconds: Int) -> [String: String] {
        [
            "Content-Encoding": "aes128gcm",
            "Content-Type": "application/octet-stream",
            "TTL": String(ttlSeconds),
            "Urgency": "high",
        ]
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The browser strips the padding; a hand-made client may keep it.
    static func base64URLDecode(_ text: String) -> Data? {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        let remainder = standard.count % 4
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}
