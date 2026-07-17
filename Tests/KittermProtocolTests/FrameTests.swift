import XCTest
@testable import KittermProtocol

final class FrameTests: XCTestCase {
    func testClientInputRoundTrip() throws {
        let payload = Data("hello".utf8)
        let frame = ClientFrame.input(payload)
        let encoded = frame.encode()
        XCTAssertEqual(encoded.first, ClientOpcode.input.rawValue)
        let decoded = try ClientFrame.decode(encoded)
        XCTAssertEqual(decoded, frame)
    }

    func testClientResizeRoundTrip() throws {
        let frame = ClientFrame.resize(cols: 120, rows: 40)
        let encoded = frame.encode()
        XCTAssertEqual(encoded, Data([1, 0, 120, 0, 40]))
        XCTAssertEqual(try ClientFrame.decode(encoded), frame)
    }

    func testClientPauseResume() throws {
        XCTAssertEqual(try ClientFrame.decode(Data([2])), .pause)
        XCTAssertEqual(try ClientFrame.decode(Data([3])), .resume)
        XCTAssertEqual(ClientFrame.pause.encode(), Data([2]))
        XCTAssertEqual(ClientFrame.resume.encode(), Data([3]))
    }

    func testServerOutputRoundTrip() throws {
        let frame = ServerFrame.output(Data([0x1b, 0x5b, 0x48]))
        let encoded = try frame.encode()
        XCTAssertEqual(try ServerFrame.decode(encoded), frame)
    }

    func testServerSessionIdRoundTrip() throws {
        let id = "6B29FC40-CA47-1067-B31D-00DD010662DA"
        let encoded = try ServerFrame.sessionId(id).encode()
        XCTAssertEqual(encoded.first, ServerOpcode.sessionId.rawValue)
        XCTAssertEqual(try ServerFrame.decode(encoded), .sessionId(id))
    }

    func testServerTitleAndCwd() throws {
        let title = try ServerFrame.title("vim — file.swift").encode()
        XCTAssertEqual(try ServerFrame.decode(title), .title("vim — file.swift"))

        let cwd = try ServerFrame.cwd("/Users/me/proj").encode()
        XCTAssertEqual(try ServerFrame.decode(cwd), .cwd("/Users/me/proj"))
    }

    func testServerExitRoundTrip() throws {
        for code: Int32 in [0, 1, -1, 127, Int32.min, Int32.max] {
            let frame = ServerFrame.exit(code)
            let encoded = try frame.encode()
            XCTAssertEqual(encoded.count, 5)
            XCTAssertEqual(try ServerFrame.decode(encoded), frame)
        }
    }

    func testSessionMetaRoundTrip() throws {
        let meta = SessionMeta(shell: "/bin/zsh", pid: 4242, cwd: "/tmp/work")
        let frame = ServerFrame.sessionMeta(meta)
        let encoded = try frame.encode()
        XCTAssertEqual(try ServerFrame.decode(encoded), frame)
    }

    func testUnknownOpcode() {
        XCTAssertThrowsError(try ClientFrame.decode(Data([99]))) { error in
            XCTAssertEqual(error as? FrameError, .unknownOpcode(99))
        }
    }

    func testEmptyFrame() {
        XCTAssertThrowsError(try ClientFrame.decode(Data())) { error in
            XCTAssertEqual(error as? FrameError, .empty)
        }
    }

    func testInvalidResizeLength() {
        XCTAssertThrowsError(try ClientFrame.decode(Data([1, 0, 1]))) { error in
            XCTAssertEqual(error as? FrameError, .invalidResizePayload)
        }
    }
}
