import Foundation

/// Client → server frame types (first byte of binary WS message).
public enum ClientOpcode: UInt8, Sendable {
    case input = 0
    case resize = 1
    case pause = 2
    case resume = 3
    case mark = 4
}

/// Shell-integration mark kinds (OSC 133 / OSC 633 letters), parsed by the
/// client's terminal emulator and reported to the daemon — the daemon itself
/// never parses ANSI.
public enum MarkKind: UInt8, Sendable {
    /// OSC 133;A — prompt start.
    case promptStart = 0
    /// OSC 133;B — prompt end, user input begins.
    case commandStart = 1
    /// OSC 133;C — command executed, output begins.
    case preExec = 2
    /// OSC 133;D — command finished (carries the exit code).
    case commandEnd = 3
}

/// Server → client frame types.
public enum ServerOpcode: UInt8, Sendable {
    case output = 0
    case title = 1
    case sessionMeta = 2
    case cwd = 3
    case exit = 4
    case sessionId = 5
    case resize = 6
    case role = 7
    case logState = 8
}

/// Client's relationship to a session (observer mode).
public enum SessionRole: UInt8, Sendable {
    case controller = 0
    case observer = 1
}

public enum FrameError: Error, Equatable, Sendable {
    case empty
    case unknownOpcode(UInt8)
    case truncatedPayload
    case invalidUTF8
    case invalidResizePayload
    case invalidExitPayload
    case invalidSessionMeta
    case invalidMarkPayload
}

public enum ClientFrame: Equatable, Sendable {
    case input(Data)
    case resize(cols: UInt16, rows: UInt16)
    case pause
    case resume
    /// A shell-integration mark the client's emulator parsed from the output
    /// stream. `offset` is the client's absolute session-log offset at parse
    /// time; `exit` is nil except on `.commandEnd`; `command` carries the
    /// OSC 633;E command line when the shell reports one (≤ 2KiB).
    case mark(kind: MarkKind, exit: Int32?, offset: UInt64, command: String?)

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
        case .mark:
            // kind u8 | exit i32be (Int32.min = absent) | offset u64be | cmdline utf8
            guard payload.count >= 13 else {
                throw FrameError.invalidMarkPayload
            }
            guard let kind = MarkKind(rawValue: payload[payload.startIndex]) else {
                throw FrameError.invalidMarkPayload
            }
            var exitRaw: Int32 = 0
            for i in 0..<4 {
                exitRaw = exitRaw << 8 | Int32(payload[payload.startIndex + 1 + i])
            }
            var offset: UInt64 = 0
            for i in 0..<8 {
                offset = offset << 8 | UInt64(payload[payload.startIndex + 5 + i])
            }
            let commandBytes = payload.dropFirst(13)
            guard commandBytes.count <= KittermConstants.maxMarkCommandBytes else {
                throw FrameError.invalidMarkPayload
            }
            var command: String?
            if !commandBytes.isEmpty {
                guard let text = String(data: Data(commandBytes), encoding: .utf8) else {
                    throw FrameError.invalidUTF8
                }
                command = text
            }
            return .mark(
                kind: kind,
                exit: exitRaw == Int32.min ? nil : exitRaw,
                offset: offset,
                command: command
            )
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
        case .mark(let kind, let exit, let offset, let command):
            var out = Data([ClientOpcode.mark.rawValue, kind.rawValue])
            var beExit = (exit ?? Int32.min).bigEndian
            withUnsafeBytes(of: &beExit) { out.append(contentsOf: $0) }
            var beOffset = offset.bigEndian
            withUnsafeBytes(of: &beOffset) { out.append(contentsOf: $0) }
            if let command {
                out.append(contentsOf: command.utf8)
            }
            return out
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
    case sessionId(String)
    case resize(cols: UInt16, rows: UInt16)
    case role(SessionRole)
    /// Sent once per attach, before any replayed output. `offset` is the
    /// absolute stream offset of the next output byte; `replayLen` bytes of
    /// replay precede live output (0 = none). `resync` means the client's
    /// screen state is stale (offset pruned, or a tail replay) and must be
    /// reset before parsing what follows.
    case logState(resync: Bool, offset: UInt64, replayLen: UInt64)

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
        case .sessionId:
            guard let id = String(data: Data(payload), encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            return .sessionId(id)
        case .resize:
            guard payload.count == 4 else {
                throw FrameError.invalidResizePayload
            }
            let cols = UInt16(payload[payload.startIndex]) << 8
                | UInt16(payload[payload.startIndex + 1])
            let rows = UInt16(payload[payload.startIndex + 2]) << 8
                | UInt16(payload[payload.startIndex + 3])
            return .resize(cols: cols, rows: rows)
        case .role:
            guard payload.count == 1,
                  let role = SessionRole(rawValue: payload[payload.startIndex])
            else {
                throw FrameError.truncatedPayload
            }
            return .role(role)
        case .logState:
            guard payload.count == 17 else {
                throw FrameError.truncatedPayload
            }
            let resync = payload[payload.startIndex] & 0x01 != 0
            func u64(at start: Data.Index) -> UInt64 {
                var value: UInt64 = 0
                for i in 0..<8 {
                    value = value << 8 | UInt64(payload[start + i])
                }
                return value
            }
            let offset = u64(at: payload.startIndex + 1)
            let replayLen = u64(at: payload.startIndex + 9)
            return .logState(resync: resync, offset: offset, replayLen: replayLen)
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
        case .sessionId(let id):
            var out = Data([ServerOpcode.sessionId.rawValue])
            out.append(contentsOf: id.utf8)
            return out
        case .resize(let cols, let rows):
            return Data([
                ServerOpcode.resize.rawValue,
                UInt8(cols >> 8), UInt8(cols & 0xff),
                UInt8(rows >> 8), UInt8(rows & 0xff),
            ])
        case .role(let role):
            return Data([ServerOpcode.role.rawValue, role.rawValue])
        case .logState(let resync, let offset, let replayLen):
            var out = Data([ServerOpcode.logState.rawValue, resync ? 1 : 0])
            var beOffset = offset.bigEndian
            withUnsafeBytes(of: &beOffset) { out.append(contentsOf: $0) }
            var beLen = replayLen.bigEndian
            withUnsafeBytes(of: &beLen) { out.append(contentsOf: $0) }
            return out
        }
    }
}
