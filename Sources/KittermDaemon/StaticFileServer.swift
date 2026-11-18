import Foundation

/// Resolves and reads built web assets from `Web/terminal/dist` (or KITTERM_WEB_ROOT).
public enum StaticFileServer: Sendable {
    /// The root cannot change during the process lifetime, and `resolveRoot()`
    /// stats every candidate — cache it so per-connection handler construction
    /// doesn't repeat blocking filesystem calls on the event loop.
    ///
    /// Symlinks are resolved here, once, and that is load-bearing: an installed
    /// `share/kitterm/web` is a symlink to a versioned directory, and a deferred
    /// upgrade flips it to the new bundle while this daemon is still serving.
    /// Pinning the resolved target keeps a live daemon on the UI that matches
    /// its own API until it restarts. `runDaemon` forces this before the flip
    /// can happen.
    public static let cachedRoot: URL? = resolveRoot()?.resolvingSymlinksInPath()

    public static func resolveRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["KITTERM_WEB_ROOT"], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) {
                return url
            }
        }

        let candidates = candidateRoots()
        for root in candidates {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) {
                return root
            }
        }
        return nil
    }

    public static func file(for path: String, root: URL) -> (url: URL, contentType: String)? {
        let relative = normalizedRelativePath(path)
        let candidate = root.appendingPathComponent(relative)
        let resolved = candidate.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard resolved.path.hasPrefix(rootPath) else {
            return nil
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue {
            return (resolved, mimeType(for: resolved.pathExtension))
        }
        // SPA / directory fallback → index.html
        if relative == "index.html" || path == "/" || path.isEmpty {
            let index = root.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                return (index, "text/html; charset=utf-8")
            }
        }
        return nil
    }

    /// A content coding the build writes a sibling for (`vite.config.ts`,
    /// the `precompress` plugin): `main-abc.js.br` beside `main-abc.js`.
    public enum ContentCoding: String, Sendable, CaseIterable {
        case br
        case gzip

        /// The extension the sibling adds to the name of the original.
        public var fileExtension: String {
            switch self {
            case .br: return "br"
            case .gzip: return "gz"
            }
        }
    }

    /// The codings the request's `Accept-Encoding` allows, in the order the
    /// daemon prefers them: `br`, then `gzip`. A coding with `q=0` is
    /// refused. `*` stands for each coding the header does not name.
    public static func acceptedCodings(_ acceptEncoding: [String]) -> [ContentCoding] {
        var weights: [String: Double] = [:]
        for value in acceptEncoding {
            for item in value.split(separator: ",") {
                let parts = item.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = parts.first?.lowercased(), !name.isEmpty else { continue }
                var weight = 1.0
                for parameter in parts.dropFirst() {
                    let pair = parameter.split(separator: "=", maxSplits: 1)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if pair.count == 2, pair[0].lowercased() == "q" {
                        // A weight that does not parse refuses the coding.
                        weight = Double(pair[1]) ?? 0
                    }
                }
                weights[name] = weight
            }
        }
        return ContentCoding.allCases.filter { (weights[$0.rawValue] ?? weights["*"] ?? 0) > 0 }
    }

    /// Whether the build writes `.br` and `.gz` siblings for this extension.
    /// The list is the one in `vite.config.ts`; images and `.map` are not in it.
    public static func isCompressible(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case "js", "mjs", "css", "html", "svg", "json", "webmanifest": return true
        default: return false
        }
    }

    /// Whether the request path names a sibling itself. The daemon serves a
    /// sibling only as the encoding of its original, never by its own name.
    public static func isPrecompressedSibling(_ path: String) -> Bool {
        let relative = normalizedRelativePath(path).lowercased()
        return ContentCoding.allCases.contains { relative.hasSuffix("." + $0.fileExtension) }
    }

    /// Whether `file` is `<root>/assets/<stem>-<hash>.<ext>`: a name Vite
    /// derives from the content, eight characters of `[A-Za-z0-9_-]` after
    /// the last `-` of the stem. Such a name never gets other content, so
    /// the answer can be `immutable`.
    public static func isHashedAsset(_ file: URL, root: URL) -> Bool {
        let assets = root.standardizedFileURL.appendingPathComponent("assets", isDirectory: true).path + "/"
        guard file.standardizedFileURL.path.hasPrefix(assets) else { return false }
        let name = file.lastPathComponent
        guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return false }
        let stem = name[..<dot].utf8
        guard stem.count > 9 else { return false }
        let tail = stem.suffix(9)
        guard tail.first == UInt8(ascii: "-") else { return false }
        return tail.dropFirst().allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static func candidateRoots() -> [URL] {
        var roots: [URL] = []
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("Web/terminal/dist", isDirectory: true))

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let execDir = executable.deletingLastPathComponent()
        // .build/debug/kitterm → repo root via ../../..
        roots.append(
            execDir
                .appendingPathComponent("../../..", isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("Web/terminal/dist", isDirectory: true)
        )
        roots.append(execDir.appendingPathComponent("web", isDirectory: true))
        roots.append(execDir.appendingPathComponent("Web/terminal/dist", isDirectory: true))
        // Installed layout: <prefix>/lib/kitterm/kitterm → <prefix>/share/kitterm/web
        roots.append(
            execDir
                .appendingPathComponent("../../share/kitterm/web", isDirectory: true)
                .standardizedFileURL
        )
        return roots
    }

    private static func normalizedRelativePath(_ path: String) -> String {
        var p = path
        if let q = p.firstIndex(of: "?") {
            p = String(p[..<q])
        }
        if let h = p.firstIndex(of: "#") {
            p = String(p[..<h])
        }
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        if p.isEmpty {
            return "index.html"
        }
        // Reject path traversal tokens early.
        let parts = p.split(separator: "/").filter { $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "map": return "application/json"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
