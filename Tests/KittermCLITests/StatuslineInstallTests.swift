import Foundation
import XCTest

@testable import KittermCLI

/// `kitterm statusline install --dir <tmp>`: the wrapper it writes, the
/// `settings.json` it points at the wrapper, the previous statusline it
/// keeps, and the wrapper run for real with a statusline render on stdin
/// against a listener on a free port.
final class StatuslineInstallTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-statusline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var wrapper: URL { dir.appendingPathComponent(StatuslineCommand.wrapperName) }
    private var settings: URL { dir.appendingPathComponent("settings.json") }

    @discardableResult
    private func run(_ args: [String]) throws -> [String] {
        var lines: [String] = []
        try StatuslineCommand.run(args) { lines.append($0) }
        return lines
    }

    private func settingsObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    /// The object a render is given, cut to the fields the wrapper reads
    /// plus the ones the previous statusline would.
    private static let render = #"""
        {"model":{"display_name":"Fable"},"cost":{"total_cost_usd":0.42},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1789000000},"seven_day":{"used_percentage":41.2,"resets_at":1789400000}}}
        """#

    // MARK: - The files

    func testInstallWithNoSettingsWritesBothAndPrintsNothingAfterThePost() throws {
        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(lines, [
            "wrote \(wrapper.path)",
            "wrote \(settings.path)",
            "no statusline was configured before; the wrapper posts rate_limits and prints nothing",
        ])
        let object = try settingsObject()
        XCTAssertEqual(object["statusLine"] as? [String: String], ["type": "command", "command": wrapper.path])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: wrapper.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o111, 0o111, "the wrapper is executable")
        let text = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#!/usr/bin/env bash\n"))
        XCTAssertTrue(text.contains("/api/usage/limits"))
        XCTAssertFalse(text.contains(StatuslineCommand.innerMarker))
        XCTAssertNil(StatuslineCommand.innerOf(text))
    }

    /// The human's own statusline stays theirs: its file is not opened, its
    /// command is the wrapper's last line, and every other setting is kept.
    func testInstallKeepsThePreviousStatuslineAndEveryOtherSetting() throws {
        try #"""
            {"model":"opus","hooks":{"Stop":[]},"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":0}}
            """#.write(to: settings, atomically: true, encoding: .utf8)

        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(lines, [
            "wrote \(wrapper.path)",
            "updated \(settings.path)",
            "the wrapper posts rate_limits, then hands stdin to: ~/.claude/statusline.sh",
        ])
        let object = try settingsObject()
        XCTAssertEqual(object["model"] as? String, "opus")
        XCTAssertEqual((object["hooks"] as? [String: Any])?.keys.sorted(), ["Stop"])
        let statusLine = try XCTUnwrap(object["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, wrapper.path)
        XCTAssertEqual(statusLine["padding"] as? Int, 0)
        let text = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\(StatuslineCommand.innerMarker)\nprintf '%s' \"$input\" | ~/.claude/statusline.sh\n"))
        XCTAssertEqual(StatuslineCommand.innerOf(text), "~/.claude/statusline.sh")
    }

    /// A second run reads the previous command back from the wrapper, so it
    /// is not lost, and rewrites nothing.
    func testSecondRunIsUnchangedAndKeepsTheInner() throws {
        try #"{"statusLine":{"type":"command","command":"npx ccstatusline@latest"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try run(["install", "--dir", dir.path])
        let wrapperBefore = try Data(contentsOf: wrapper)
        let settingsBefore = try Data(contentsOf: settings)

        let lines = try run(["install", "--dir", dir.path])
        XCTAssertEqual(lines, [
            "unchanged \(wrapper.path)",
            "unchanged \(settings.path)",
            "the wrapper posts rate_limits, then hands stdin to: npx ccstatusline@latest",
        ])
        XCTAssertEqual(try Data(contentsOf: wrapper), wrapperBefore)
        XCTAssertEqual(try Data(contentsOf: settings), settingsBefore)
    }

    func testASettingsFileThatIsNotAnObjectIsRefused() throws {
        try "[1, 2]".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try run(["install", "--dir", dir.path])) { error in
            XCTAssertTrue("\(error)".contains("not a JSON object"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path), "nothing is written on a refusal")
    }

    func testPrintIsTheWrapperWithNoInner() throws {
        let lines = try run(["print"])
        XCTAssertEqual(lines, [StatuslineCommand.wrapper(inner: nil)])
        XCTAssertThrowsError(try run(["frobnicate"]))
    }

    // MARK: - The wrapper, run

    /// The whole point, end to end: a render on stdin reaches the daemon as
    /// the `rate_limits` object alone, the previous statusline gets the same
    /// stdin, and the wrapper is back before the post lands. A second render
    /// with the same object posts nothing.
    func testTheWrapperPostsTheObjectOnceAndHandsStdinOn() throws {
        let seen = dir.appendingPathComponent("seen.json")
        try #"{"statusLine":{"type":"command","command":"cat > \#(seen.path)"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try run(["install", "--dir", dir.path])

        let listener = try Listener()
        let state = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try "\(listener.port)\n".write(to: state.appendingPathComponent("port"), atomically: true, encoding: .utf8)

        let first = try runWrapper(stdin: Self.render, stateDir: state)
        XCTAssertEqual(first.status, 0)
        XCTAssertEqual(first.stdout, "", "the previous statusline here prints nothing")
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), Self.render, "the previous statusline gets the same stdin")

        let request = try listener.accept(deadline: 5)
        XCTAssertTrue(request.hasPrefix("POST /api/usage/limits HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.lowercased().contains("content-type: application/json"), request)
        let body = try XCTUnwrap(request.components(separatedBy: "\r\n\r\n").last)
        let posted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(Set(posted.keys), ["five_hour", "seven_day"])
        XCTAssertEqual((posted["five_hour"] as? [String: Any])?["used_percentage"] as? Double, 23.5)

        // The same object again, within the minute: no second post.
        let second = try runWrapper(stdin: Self.render, stateDir: state)
        XCTAssertEqual(second.status, 0)
        XCTAssertNil(try? listener.accept(deadline: 1), "an unchanged object within a minute is not posted again")

        // A changed object posts.
        let changed = Self.render.replacingOccurrences(of: "23.5", with: "24.0")
        _ = try runWrapper(stdin: changed, stateDir: state)
        let again = try listener.accept(deadline: 5)
        XCTAssertTrue(again.contains("24"), again)
    }

    /// No daemon: the port file names a closed port, or there is no port
    /// file, or the render carries no `rate_limits`. Each time the previous
    /// statusline runs and the wrapper is back at once.
    func testTheWrapperIsQuickAndQuietWithoutADaemon() throws {
        try #"{"statusLine":{"type":"command","command":"printf 'inner ran'"}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try run(["install", "--dir", dir.path])
        let state = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

        // A port nothing listens on: bind one, read it, close it.
        let closed = try Listener()
        let port = closed.port
        closed.close()
        try "\(port)\n".write(to: state.appendingPathComponent("port"), atomically: true, encoding: .utf8)

        let started = Date()
        let down = try runWrapper(stdin: Self.render, stateDir: state)
        XCTAssertEqual(down.status, 0)
        XCTAssertEqual(down.stdout, "inner ran")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "a dead daemon costs no wait")

        try FileManager.default.removeItem(at: state.appendingPathComponent("port"))
        let noPort = try runWrapper(stdin: Self.render, stateDir: state)
        XCTAssertEqual(noPort.stdout, "inner ran")

        let noLimits = try runWrapper(stdin: #"{"model":{"display_name":"Fable"}}"#, stateDir: state)
        XCTAssertEqual(noLimits.stdout, "inner ran")
    }

    // MARK: - Helpers

    /// Run the installed wrapper as Claude Code would: the render on stdin,
    /// `KITTERM_STATE_DIR` naming the port file's directory, `TMPDIR` inside
    /// the scratch directory so the dedupe cache is this test's own.
    private func runWrapper(stdin: String, stateDir: URL) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [wrapper.path]
        var env = ProcessInfo.processInfo.environment
        env["KITTERM_STATE_DIR"] = stateDir.path
        env["TMPDIR"] = dir.path
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        waitForExit(of: process, output: text)
        return (process.terminationStatus, text)
    }

    /// A TCP listener on a free loopback port that answers one request with
    /// a 200 and hands the request text back.
    private final class Listener {
        let fd: Int32
        let port: Int

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            self.fd = fd
            self.port = Int(UInt16(bigEndian: actual.sin_port))
        }

        struct Timeout: Error {}

        /// One connection within `deadline` seconds: read until the headers
        /// and `Content-Length` bytes of body are in, answer 200, return the
        /// request. Throws `Timeout` when nobody connects.
        func accept(deadline: TimeInterval) throws -> String {
            var set = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&set, 1, Int32(deadline * 1000)) > 0 else { throw Timeout() }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { throw NSError(domain: "accept", code: Int(errno)) }
            defer { Darwin.close(client) }
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(client, &buffer, buffer.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: buffer[0..<n])
                let text = String(decoding: received, as: UTF8.self)
                guard let split = text.range(of: "\r\n\r\n") else { continue }
                let head = text[..<split.lowerBound].lowercased()
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if text[split.upperBound...].utf8.count >= length { break }
            }
            let answer = Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}".utf8)
            answer.withUnsafeBytes { _ = send(client, $0.baseAddress, $0.count, 0) }
            return String(decoding: received, as: UTF8.self)
        }

        func close() { Darwin.close(fd) }
    }
}
