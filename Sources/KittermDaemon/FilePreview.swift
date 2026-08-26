import Foundation

import KittermProtocol

/**
 The rules for handing a file's bytes to a browser.

 Reading is not the risk here. Anyone who can reach this route holds a full
 token, and a full token can already type `cat`; the OS decides what is
 readable, which is the same story `/api/files` tells.

 The risk is what the browser does with the answer. kitterm serves this from its
 own origin, so a file returned as `text/html` or `image/svg+xml` runs its script
 with access to the auth cookie and every route that cookie reaches — and the
 file need not be one the user trusts. A downloaded page, an SVG in a
 dependency, anything an agent wrote.

 So the file's own type is never honoured. A small set of kinds that cannot
 execute are served as themselves; everything text-like is served as plain text,
 *including* HTML and SVG; and anything else is a download. Reading an SVG's
 source rather than seeing it drawn is the cost, and it is worth paying.
 */
enum FilePreview {
    /// How the client should present what came back.
    enum Kind: String {
        case image
        case pdf
        case text
        case binary
    }

    struct Payload: Sendable {
        let data: Data
        let contentType: String
        let kind: String
        let totalBytes: Int
        let truncated: Bool
        /// Offer as a download rather than render inline.
        let attachment: Bool
        let filename: String
    }

    enum PreviewError: Error {
        case notAFile
        case unreadable
    }

    /// Types that cannot carry script and are worth showing as themselves.
    ///
    /// SVG is deliberately absent. It is an image to a user and a document with
    /// scripting to a browser, and this route cannot tell a trusted one from a
    /// hostile one.
    private static let inlineTypes: [String: (String, Kind)] = [
        "png": ("image/png", .image),
        "jpg": ("image/jpeg", .image),
        "jpeg": ("image/jpeg", .image),
        "gif": ("image/gif", .image),
        "webp": ("image/webp", .image),
        "bmp": ("image/bmp", .image),
        "ico": ("image/x-icon", .image),
        "pdf": ("application/pdf", .pdf),
    ]

    /// Extensions shown as text. Anything not listed is judged by its bytes.
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "log", "csv", "tsv", "sql", "sh", "bash", "zsh", "fish", "py", "rb", "go", "rs", "swift",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "js", "mjs", "cjs", "ts",
        "tsx", "jsx", "css", "scss", "less", "html", "htm", "xml", "svg", "diff", "patch",
        "gitignore", "dockerfile", "makefile", "lock", "env", "properties", "gradle", "plist",
    ]

    /// Decide, read, and cap. Runs off the event loop: this touches the disk.
    static func read(_ url: URL, cap: Int = KittermConstants.apiCommandOutputMaxBytes) throws -> Payload {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw PreviewError.notAFile
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw PreviewError.unreadable
        }
        defer { try? handle.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        // One byte past the cap, so truncation is known without reading it all.
        let data = (try? handle.read(upToCount: cap + 1)) ?? Data()
        let truncated = data.count > cap
        let body = truncated ? data.prefix(cap) : data

        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        if let (type, kind) = inlineTypes[ext] {
            return Payload(
                data: Data(body), contentType: type, kind: kind.rawValue,
                totalBytes: total ?? body.count, truncated: truncated,
                attachment: false, filename: name
            )
        }

        let looksTextual = textExtensions.contains(ext)
            || textExtensions.contains(name.lowercased())
            || isProbablyText(body)
        if looksTextual {
            // Plain text even for HTML and SVG: see the note at the top.
            return Payload(
                data: Data(body), contentType: "text/plain; charset=utf-8", kind: Kind.text.rawValue,
                totalBytes: total ?? body.count, truncated: truncated,
                attachment: false, filename: name
            )
        }

        return Payload(
            data: Data(body), contentType: "application/octet-stream", kind: Kind.binary.rawValue,
            totalBytes: total ?? body.count, truncated: truncated,
            attachment: true, filename: name
        )
    }

    /// Whether bytes read as text.
    ///
    /// A NUL is the giveaway that a file is not text, and it is what `grep` and
    /// `file` lean on too. Only the head is examined, because the answer is
    /// needed before the whole file is read.
    static func isProbablyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let head = data.prefix(8000)
        if head.contains(0) { return false }
        // Valid UTF-8 settles it; otherwise fall back to counting control bytes,
        // so Latin-1 logs still read as text.
        if String(data: head, encoding: .utf8) != nil { return true }
        let controls = head.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return Double(controls) / Double(head.count) < 0.05
    }

    /// A filename safe to put in a header: quotes and control bytes removed, so
    /// a crafted name cannot break out of the `Content-Disposition` value.
    static func headerSafeName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\"" && scalar != "\\"
        }
        let result = String(String.UnicodeScalarView(cleaned))
        return result.isEmpty ? "file" : String(result.prefix(200))
    }
}
