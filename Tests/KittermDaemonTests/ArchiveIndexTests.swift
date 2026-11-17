import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import KittermDaemon

/// `GET /api/archives` answers from the list the daemon keeps
/// (`fleet-first-paint`, round 3; `goal.md` condition 4): an `ETag`, a 304
/// for a matching `If-None-Match`, and no second read of the archive
/// directory for a list that did not change. The archives are files the
/// test writes, so no session is spawned.
final class ArchiveIndexTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var channel: Channel!
    private var port: Int!
    private var stateDir: URL!
    private var eventLog: EventLog!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitterm-archive-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        setenv("KITTERM_STATE_DIR", stateDir.path, 1)

        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLog = EventLog()
        let registry = SessionRegistry()
        let eventLog = self.eventLog!
        let projects = ProjectStore(url: stateDir.appendingPathComponent("projects.json"))
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPAPIHandler(
                            registry: registry,
                            policy: .loopbackOnly,
                            agentControl: true,
                            eventLog: eventLog,
                            staticRoot: nil,
                            projects: projects
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = channel.localAddress?.port
    }

    override func tearDown() async throws {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
        unsetenv("KITTERM_STATE_DIR")
        try? FileManager.default.removeItem(at: stateDir)
    }

    // MARK: - Fixtures

    private var archiveDirectory: URL { DaemonPaths.archiveDirectory }

    /// Write one archive as an outside writer does: files, no daemon call.
    @discardableResult
    private func writeArchive(name: String, archivedAt: Int) throws -> UUID {
        let id = UUID()
        let dir = archiveDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "version": SessionArchive.formatVersion, "id": id.uuidString, "name": name,
            "cwd": "/nowhere/\(name)", "shell": "/bin/sh", "archivedAt": archivedAt,
            "commands": [], "marks": [],
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: dir.appendingPathComponent("archive.json"))
        return id
    }

    /// Move the directory's modification time to `secondsAgo` in the past,
    /// so a read of it is settled (`ArchiveIndex.settleSeconds`).
    private func ageDirectory(secondsAgo: TimeInterval = 60) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)],
            ofItemAtPath: archiveDirectory.path
        )
    }

    private struct Answer {
        let status: Int
        let etag: String?
        let data: Data

        func names() throws -> [String] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try XCTUnwrap(json["archives"] as? [[String: Any]])
            return rows.compactMap { $0["name"] as? String }
        }
    }

    private func request(_ method: String, _ path: String, ifNoneMatch: String? = nil) async throws -> Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return Answer(status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"), data: data)
    }

    private func reads() -> Int { SessionArchive.index.directoryReads }

    // MARK: - The ETag

    func testListCarriesAnETagAndAnswers304ToAMatch() async throws {
        try writeArchive(name: "old", archivedAt: 1000)
        try writeArchive(name: "new", archivedAt: 2000)
        try ageDirectory()

        let first = try await request("GET", "/api/archives")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try first.names(), ["new", "old"], "newest first")
        let etag = try XCTUnwrap(first.etag)

        let same = try await request("GET", "/api/archives", ifNoneMatch: etag)
        XCTAssertEqual(same.status, 304)
        XCTAssertEqual(same.etag, etag)
        XCTAssertTrue(same.data.isEmpty, "a 304 costs no body")

        let other = try await request("GET", "/api/archives", ifNoneMatch: "\"another\"")
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(other.data, first.data, "the same list gives the same bytes")
    }

    func testTheETagMovesWhenTheListChanges() async throws {
        try writeArchive(name: "one", archivedAt: 1000)
        try ageDirectory()
        let unchanged = try await request("GET", "/api/archives")
        let before = try XCTUnwrap(unchanged.etag)

        try writeArchive(name: "two", archivedAt: 2000)
        try ageDirectory(secondsAgo: 30)
        let after = try await request("GET", "/api/archives", ifNoneMatch: before)
        XCTAssertEqual(after.status, 200)
        XCTAssertNotEqual(after.etag, before)
        XCTAssertEqual(try after.names(), ["two", "one"])
    }

    // MARK: - The directory read

    func testAnUnchangedListIsNotReadFromTheDirectoryAgain() async throws {
        try writeArchive(name: "one", archivedAt: 1000)
        try ageDirectory()
        _ = try await request("GET", "/api/archives")
        let after = reads()

        for _ in 0..<3 { _ = try await request("GET", "/api/archives") }
        _ = try await request("GET", "/api/archives?project=nothing-here")
        XCTAssertEqual(reads(), after, "four more requests, no directory read")
    }

    func testAnArchiveWrittenThroughTheDaemonIsReadAgain() async throws {
        try writeArchive(name: "one", archivedAt: 1000)
        try ageDirectory()
        _ = try await request("GET", "/api/archives")
        let before = reads()

        let id = UUID()
        let metadata = try JSONSerialization.data(withJSONObject: [
            "version": 1, "id": id.uuidString, "name": "written", "cwd": "/nowhere", "shell": "/bin/sh",
            "archivedAt": 3000,
        ] as [String: Any])
        let wrote = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SessionArchive.write(id: id, metadata: metadata, output: Data()) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(wrote)
        // The write moved the directory's time to now; the invalidation
        // alone must be enough, so put the time back where it was read.
        try ageDirectory()

        let listed = try await request("GET", "/api/archives")
        XCTAssertEqual(try listed.names(), ["written", "one"])
        XCTAssertEqual(reads(), before + 1)
    }

    func testADeleteIsReadAgainAndSaysSoOnTheEventFeed() async throws {
        let gone = try writeArchive(name: "gone", archivedAt: 2000)
        try writeArchive(name: "kept", archivedAt: 1000)
        try ageDirectory()
        let both = try await request("GET", "/api/archives")
        XCTAssertEqual(try both.names(), ["gone", "kept"])
        let before = reads()

        let deleted = try await request("DELETE", "/api/archives/\(gone.uuidString)")
        XCTAssertEqual(deleted.status, 200)
        try ageDirectory()
        let listed = try await request("GET", "/api/archives")
        XCTAssertEqual(try listed.names(), ["kept"])
        XCTAssertEqual(reads(), before + 1)

        let removed = eventLog.snapshot(since: 0, session: nil).events.filter { $0.type == "archive.removed" }
        XCTAssertEqual(removed.map(\.session), [gone], "one event, with the archive's id")
        XCTAssertEqual(removed.first?.data, [:])

        // An archive that is not there removes nothing and says nothing.
        let missing = try await request("DELETE", "/api/archives/\(gone.uuidString)")
        XCTAssertEqual(missing.status, 404)
        let again = eventLog.snapshot(since: 0, session: nil).events.filter { $0.type == "archive.removed" }
        XCTAssertEqual(again.count, 1)
    }

    func testAChangeOutsideTheDaemonIsReadAgain() async throws {
        let gone = try writeArchive(name: "gone", archivedAt: 2000)
        try writeArchive(name: "kept", archivedAt: 1000)
        try ageDirectory()
        _ = try await request("GET", "/api/archives")
        let before = reads()

        // No daemon call: the directory's own time is what the daemon sees.
        try FileManager.default.removeItem(at: archiveDirectory.appendingPathComponent(gone.uuidString))
        try ageDirectory(secondsAgo: 30)
        let listed = try await request("GET", "/api/archives")
        XCTAssertEqual(try listed.names(), ["kept"])
        XCTAssertEqual(reads(), before + 1)
        _ = try await request("GET", "/api/archives")
        XCTAssertEqual(reads(), before + 1, "the new state is kept")
    }

    /// An outside writer makes the directory before `archive.json`, and the
    /// second step does not move the parent's time: a read just after the
    /// directory changed is not kept.
    func testAReadJustAfterTheDirectoryChangedIsNotKept() async throws {
        try writeArchive(name: "one", archivedAt: 1000)
        _ = try await request("GET", "/api/archives")
        let before = reads()
        _ = try await request("GET", "/api/archives")
        XCTAssertEqual(reads(), before + 1)
    }
}
