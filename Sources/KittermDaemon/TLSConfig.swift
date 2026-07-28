import Foundation
import NIOSSL

/// User-supplied certificate and key for the external listener.
///
/// kitterm never generates certificates. A self-signed one would train users
/// to click through warnings, and iOS refuses `wss://` to an untrusted cert
/// even after the page itself is accepted — so a phone, the whole point of
/// remote access, would silently fail to connect. Bring a real one instead:
///
///     tailscale cert mac.tailnet.ts.net    # publicly trusted, free, no CA to install
///
/// or terminate TLS at a reverse proxy and use `--trusted-host`.
public struct TLSConfig: Sendable {
    public let certificatePath: String
    public let privateKeyPath: String
    /// Port for the encrypted external listener. Separate from the plain
    /// loopback port so local use keeps working exactly as before — and so
    /// enabling TLS *removes* plaintext from the network rather than adding a
    /// second door.
    public let port: Int

    public init(certificatePath: String, privateKeyPath: String, port: Int) {
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.port = port
    }

    /// Load and validate at startup, so a bad path fails the launch loudly
    /// instead of every connection quietly. Runs before the loop serves
    /// traffic, so the blocking reads are free.
    public func makeSSLContext() throws -> NIOSSLContext {
        let fm = FileManager.default
        for path in [certificatePath, privateKeyPath] {
            guard fm.fileExists(atPath: path) else {
                throw TLSConfigError.missingFile(path)
            }
            guard fm.isReadableFile(atPath: path) else {
                throw TLSConfigError.unreadableFile(path)
            }
        }
        // A private key other users can read is the whole security of this
        // listener; say so rather than starting silently.
        if let mode = try? fm.attributesOfItem(atPath: privateKeyPath)[.posixPermissions],
           let perms = (mode as? NSNumber)?.int16Value,
           perms & 0o077 != 0 {
            FileHandle.standardError.write(
                Data("kitterm: warning: \(privateKeyPath) is readable by other users (chmod 600 it)\n".utf8)
            )
        }

        do {
            let chain = try NIOSSLCertificate.fromPEMFile(certificatePath)
            let key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: chain.map { .certificate($0) },
                privateKey: .privateKey(key)
            )
            // The client is a browser; let it pick HTTP/1.1 explicitly so the
            // upgrade path is unambiguous. kitterm speaks no HTTP/2.
            config.applicationProtocols = ["http/1.1"]
            return try NIOSSLContext(configuration: config)
        } catch let error as TLSConfigError {
            throw error
        } catch {
            throw TLSConfigError.invalidMaterial(String(describing: error))
        }
    }
}

public enum TLSConfigError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case unreadableFile(String)
    case invalidMaterial(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "TLS file not found: \(path)"
        case .unreadableFile(let path):
            return "TLS file not readable: \(path)"
        case .invalidMaterial(let detail):
            return "could not load the TLS certificate or key — \(detail)"
        }
    }
}
