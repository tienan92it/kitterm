import Foundation

/// Resolves and reads built web assets from `Web/terminal/dist` (or KITTERM_WEB_ROOT).
public enum StaticFileServer: Sendable {
    /// The root cannot change during the process lifetime, and `resolveRoot()`
    /// stats every candidate — cache it so per-connection handler construction
    /// doesn't repeat blocking filesystem calls on the event loop.
    public static let cachedRoot: URL? = resolveRoot()

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
