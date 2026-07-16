import Foundation

/// Client → server frame types (first byte of binary WS message).
public enum ClientOpcode: UInt8, Sendable {
    case input = 0
    case resize = 1
    case pause = 2
    case resume = 3
}

/// Server → client frame types.
public enum ServerOpcode: UInt8, Sendable {
    case output = 0
    case title = 1
    case sessionMeta = 2
    case cwd = 3
    case exit = 4
}

public enum FrameError: Error, Equatable, Sendable {
    case empty
    case unknownOpcode(UInt8)
    case truncatedPayload
    case invalidUTF8
    case invalidResizePayload
    case invalidExitPayload
    case invalidSessionMeta
}

public enum ClientFrame: Equatable, Sendable {
    case input(Data)
    case resize(cols: UInt16, rows: UInt16)
    case pause
    case resume

    public static func decode(_ data: Data) throws -> ClientFrame {
        guard let opcodeByte = data.first else {
            throw FrameError.empty
        }
        guard let opcode = ClientOpcode(rawValue: opcodeByte) else {
            throw FrameError.unknownOpcode(opcodeByte)
        }
        let payload = data.dropFirst()
        switch opcode {
        case .input:
            return .input(Data(payload))
        case .resize:
            guard payload.count == 4 else {
                throw FrameError.invalidResizePayload
            }
            let cols = UInt16(payload[payload.startIndex]) << 8
                | UInt16(payload[payload.startIndex + 1])
            let rows = UInt16(payload[payload.startIndex + 2]) << 8
                | UInt16(payload[payload.startIndex + 3])
            return .resize(cols: cols, rows: rows)
        case .pause:
            guard payload.isEmpty else { throw FrameError.truncatedPayload }
            return .pause
        case .resume:
            guard payload.isEmpty else { throw FrameError.truncatedPayload }
            return .resume
        }
    }

    public func encode() -> Data {
        switch self {
        case .input(let bytes):
            var out = Data([ClientOpcode.input.rawValue])
            out.append(bytes)
            return out
        case .resize(let cols, let rows):
            return Data([
                ClientOpcode.resize.rawValue,
                UInt8(cols >> 8), UInt8(cols & 0xff),
                UInt8(rows >> 8), UInt8(rows & 0xff),
            ])
        case .pause:
            return Data([ClientOpcode.pause.rawValue])
        case .resume:
            return Data([ClientOpcode.resume.rawValue])
        }
    }
}

public struct SessionMeta: Equatable, Sendable {
    public var shell: String
    public var pid: Int32
    public var cwd: String

    public init(shell: String, pid: Int32, cwd: String) {
        self.shell = shell
        self.pid = pid
        self.cwd = cwd
    }

    /// Layout: shell u16be len + utf8 | pid i32be | cwd u16be len + utf8
    public func encode() throws -> Data {
        var data = Data()
        try Self.appendLengthPrefixedString(shell, to: &data)
        var bePid = pid.bigEndian
        withUnsafeBytes(of: &bePid) { data.append(contentsOf: $0) }
        try Self.appendLengthPrefixedString(cwd, to: &data)
        return data
    }

    public static func decode(_ data: Data) throws -> SessionMeta {
        var offset = data.startIndex
        let shell = try readLengthPrefixedString(from: data, offset: &offset)
        guard offset + 4 <= data.endIndex else {
            throw FrameError.invalidSessionMeta
        }
        let pid: Int32 =
            (Int32(data[offset]) << 24)
            | (Int32(data[offset + 1]) << 16)
            | (Int32(data[offset + 2]) << 8)
            | Int32(data[offset + 3])
        offset += 4
        let cwd = try readLengthPrefixedString(from: data, offset: &offset)
        guard offset == data.endIndex else {
            throw FrameError.invalidSessionMeta
        }
        return SessionMeta(shell: shell, pid: pid, cwd: cwd)
    }

    private static func appendLengthPrefixedString(_ string: String, to data: inout Data) throws {
        let utf8 = Array(string.utf8)
        guard utf8.count <= Int(UInt16.max) else {
            throw FrameError.invalidSessionMeta
        }
        let len = UInt16(utf8.count)
        data.append(UInt8(len >> 8))
        data.append(UInt8(len & 0xff))
        data.append(contentsOf: utf8)
    }

    private static func readLengthPrefixedString(from data: Data, offset: inout Data.Index) throws -> String {
        guard offset + 2 <= data.endIndex else {
            throw FrameError.invalidSessionMeta
        }
        let len = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
        offset += 2
        guard offset + len <= data.endIndex else {
            throw FrameError.invalidSessionMeta
        }
        let slice = data[offset..<(offset + len)]
        offset += len
        guard let string = String(data: Data(slice), encoding: .utf8) else {
            throw FrameError.invalidUTF8
        }
        return string
    }
}

public enum ServerFrame: Equatable, Sendable {
    case output(Data)
    case title(String)
    case sessionMeta(SessionMeta)
    case cwd(String)
    case exit(Int32)

    public static func decode(_ data: Data) throws -> ServerFrame {
        guard let opcodeByte = data.first else {
            throw FrameError.empty
        }
        guard let opcode = ServerOpcode(rawValue: opcodeByte) else {
            throw FrameError.unknownOpcode(opcodeByte)
        }
        let payload = data.dropFirst()
        switch opcode {
        case .output:
            return .output(Data(payload))
        case .title:
            guard let title = String(data: Data(payload), encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            return .title(title)
        case .sessionMeta:
            return .sessionMeta(try SessionMeta.decode(Data(payload)))
        case .cwd:
            guard let cwd = String(data: Data(payload), encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            return .cwd(cwd)
        case .exit:
            guard payload.count == 4 else {
                throw FrameError.invalidExitPayload
            }
            let code: Int32 =
                (Int32(payload[payload.startIndex]) << 24)
                | (Int32(payload[payload.startIndex + 1]) << 16)
                | (Int32(payload[payload.startIndex + 2]) << 8)
                | Int32(payload[payload.startIndex + 3])
            return .exit(code)
        }
    }

    public func encode() throws -> Data {
        switch self {
        case .output(let bytes):
            var out = Data([ServerOpcode.output.rawValue])
            out.append(bytes)
            return out
        case .title(let title):
            var out = Data([ServerOpcode.title.rawValue])
            out.append(contentsOf: title.utf8)
            return out
        case .sessionMeta(let meta):
            var out = Data([ServerOpcode.sessionMeta.rawValue])
            out.append(try meta.encode())
            return out
        case .cwd(let cwd):
            var out = Data([ServerOpcode.cwd.rawValue])
            out.append(contentsOf: cwd.utf8)
            return out
        case .exit(let code):
            var out = Data([ServerOpcode.exit.rawValue])
            var be = code.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            return out
        }
    }
}
