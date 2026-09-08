import Foundation
import XCTest

@testable import KittermDaemon

/// `ProjectStore`: the resolution of a working directory to a project, the
/// `project:` label override, the id rules, and the reload of
/// `projects.json` on an mtime change.
final class ProjectStoreTests: XCTestCase {
    private var root: URL!
    private var file: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        // Created first, then made real (`/private/var/…`), the form the
        // kernel reports a shell's cwd in and the form roots are stored in.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kitterm-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ProjectStore.canonicalRoot(scratch.path), isDirectory: true)
        file = root.appendingPathComponent("projects.json")
        store = ProjectStore(url: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func register(_ projects: [Project]) throws {
        try ProjectStore.save(projects, to: file)
    }

    // MARK: - resolution table

    /// A registered root wins over a nested `.git` below it.
    func testRegisteredRootWins() throws {
        let alpha = try dir("alpha")
        _ = try dir("alpha/vendor/.git")
        try register([Project(id: "alpha", name: "Alpha", root: alpha)])

        let resolved = store.resolve(cwd: alpha + "/vendor/src")
        XCTAssertEqual(
            resolved,
            ResolvedProject(id: "alpha", name: "Alpha", root: alpha, registered: true, knowledge: "docs/goals")
        )
    }

    func testLongestRegisteredRootWins() throws {
        let outer = try dir("outer")
        let inner = try dir("outer/inner")
        try register([
            Project(id: "outer", name: "outer", root: outer),
            Project(id: "inner", name: "inner", root: inner),
        ])
        XCTAssertEqual(store.resolve(cwd: inner + "/deep")?.id, "inner")
        XCTAssertEqual(store.resolve(cwd: outer + "/other")?.id, "outer")
        // A sibling that only shares a string prefix is not inside the root.
        _ = try dir("outer-2")
        XCTAssertNil(store.resolve(cwd: root.path + "/outer-2"))
    }

    /// Outside every registered root the nearest `.git` names the project.
    func testGitWalkDiscoversARepository() throws {
        let repo = try dir("repo")
        _ = try dir("repo/.git")
        let cwd = try dir("repo/src/deep")

        let resolved = store.resolve(cwd: cwd)
        XCTAssertEqual(
            resolved,
            ResolvedProject(id: "repo", name: "repo", root: repo, registered: false, knowledge: "docs/goals")
        )
        XCTAssertEqual(store.resolve(cwd: repo)?.root, repo, "the repository root itself resolves")
    }

    /// A worktree's `.git` file names `<main>/.git/worktrees/<name>`; the
    /// project is the main checkout.
    func testWorktreeResolvesToTheMainCheckout() throws {
        let main = try dir("main")
        _ = try dir("main/.git/worktrees/feature")
        let worktree = try dir("elsewhere/feature")
        try "gitdir: \(main)/.git/worktrees/feature\n".write(
            toFile: worktree + "/.git", atomically: true, encoding: .utf8
        )

        let resolved = store.resolve(cwd: worktree + "/Sources")
        XCTAssertEqual(resolved?.root, main)
        XCTAssertEqual(resolved?.id, "main")
        XCTAssertEqual(resolved?.registered, false)
    }

    /// The same, with a relative `gitdir:` as a submodule writes it.
    func testRelativeGitdirResolvesAgainstTheWorktree() throws {
        let main = try dir("host")
        _ = try dir("host/.git/modules/lib")
        let module = try dir("host-modules/lib")
        try "gitdir: ../../host/.git/modules/lib".write(
            toFile: module + "/.git", atomically: true, encoding: .utf8
        )
        XCTAssertEqual(store.resolve(cwd: module)?.root, main)
    }

    /// A worktree kept outside a registered root still belongs to it.
    func testWorktreeOfARegisteredProjectIsRegistered() throws {
        let main = try dir("kitterm")
        _ = try dir("kitterm/.git/worktrees/wt")
        let worktree = try dir("wt")
        try "gitdir: \(main)/.git/worktrees/wt\n".write(
            toFile: worktree + "/.git", atomically: true, encoding: .utf8
        )
        try register([Project(id: "kitterm", name: "kitterm", root: main)])

        let resolved = store.resolve(cwd: worktree)
        XCTAssertEqual(resolved?.id, "kitterm")
        XCTAssertEqual(resolved?.registered, true)
    }

    func testNoProjectOutsideEveryRepository() throws {
        let plain = try dir("plain/dir")
        XCTAssertNil(store.resolve(cwd: plain))
    }

    /// The walk stops after 32 levels rather than scanning to `/`.
    func testTheWalkIsBounded() throws {
        _ = try dir("deep/.git")
        let within = try dir("deep/" + (1...30).map(String.init).joined(separator: "/"))
        let beyond = try dir("deep/" + (1...40).map(String.init).joined(separator: "/"))
        XCTAssertEqual(store.resolve(cwd: within)?.id, "deep")
        XCTAssertNil(store.resolve(cwd: beyond))
    }

    /// Two discovered repositories with one folder name get distinct ids.
    func testDiscoveredIDsAreUniqueWithinARun() throws {
        let first = try dir("a/app")
        _ = try dir("a/app/.git")
        let second = try dir("b/app")
        _ = try dir("b/app/.git")
        XCTAssertEqual(store.resolve(cwd: first)?.id, "app")
        XCTAssertEqual(store.resolve(cwd: second)?.id, "app-2")
        XCTAssertEqual(store.resolve(cwd: first)?.id, "app", "a root keeps its id")
    }

    // MARK: - label override

    func testProjectLabelOverridesTheResolution() throws {
        let alpha = try dir("alpha")
        try register([Project(id: "alpha", name: "Alpha", root: alpha)])
        let discovered = ResolvedProject(
            id: "repo", name: "repo", root: "/x/repo", registered: false, knowledge: "docs/goals"
        )

        // A registered id carries the registered project.
        let registered = store.project(labels: ["project": "alpha"], resolved: discovered)
        XCTAssertEqual(registered?.id, "alpha")
        XCTAssertEqual(registered?.registered, true)
        XCTAssertEqual(registered?.root, alpha)

        // An unknown id is reported as itself, with the resolved root.
        let unknown = store.project(labels: ["project": "other"], resolved: discovered)
        XCTAssertEqual(unknown?.id, "other")
        XCTAssertEqual(unknown?.name, "other")
        XCTAssertEqual(unknown?.registered, false)
        XCTAssertEqual(unknown?.root, "/x/repo")
        XCTAssertNil(store.project(labels: ["project": "other"], resolved: nil)?.root)

        // A malformed value is ignored; other labels change nothing.
        XCTAssertEqual(store.project(labels: ["project": "Not/An/Id"], resolved: discovered), discovered)
        XCTAssertEqual(store.project(labels: ["crew": "alpha"], resolved: discovered), discovered)
        XCTAssertNil(store.project(labels: [:], resolved: nil))
    }

    // MARK: - ids

    func testSlugAndUniqueID() {
        XCTAssertEqual(ProjectStore.slug("My Project!"), "my-project")
        XCTAssertEqual(ProjectStore.slug("kitterm"), "kitterm")
        XCTAssertEqual(ProjectStore.slug("--weird__name--"), "weird-name")
        XCTAssertEqual(ProjectStore.slug("日本"), "project")
        XCTAssertEqual(ProjectStore.slug(String(repeating: "a", count: 100)).count, ProjectStore.maxIDLength)
        XCTAssertEqual(ProjectStore.uniqueID(for: "app", taken: []), "app")
        XCTAssertEqual(ProjectStore.uniqueID(for: "app", taken: ["app"]), "app-2")
        XCTAssertEqual(ProjectStore.uniqueID(for: "app", taken: ["app", "app-2"]), "app-3")
    }

    func testIDValidation() {
        XCTAssertTrue(ProjectStore.isValidID("kitterm"))
        XCTAssertTrue(ProjectStore.isValidID("app-2"))
        XCTAssertFalse(ProjectStore.isValidID(""))
        XCTAssertFalse(ProjectStore.isValidID("Kitterm"))
        XCTAssertFalse(ProjectStore.isValidID("-app"))
        XCTAssertFalse(ProjectStore.isValidID("app-"))
        XCTAssertFalse(ProjectStore.isValidID("a/b"))
        XCTAssertFalse(ProjectStore.isValidID(String(repeating: "a", count: 65)))
    }

    // MARK: - file

    func testReloadsWhenTheFileChanges() throws {
        let alpha = try dir("alpha")
        let beta = try dir("beta")
        try register([Project(id: "alpha", name: "alpha", root: alpha)])
        XCTAssertEqual(store.resolve(cwd: alpha)?.id, "alpha")
        XCTAssertNil(store.resolve(cwd: beta))
        let generation = store.generation

        try register([Project(id: "beta", name: "beta", root: beta)])
        // Two writes inside one mtime tick look unchanged; move the clock.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path
        )
        XCTAssertEqual(store.resolve(cwd: beta)?.id, "beta")
        XCTAssertNil(store.resolve(cwd: alpha))
        XCTAssertGreaterThan(store.generation, generation)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.registered(), [])
        XCTAssertNil(store.resolve(cwd: beta))
    }

    func testLoadSkipsMalformedEntriesAndRefusesAnUnknownVersion() throws {
        let alpha = try dir("alpha")
        try """
        { "version": 1, "projects": [
          { "id": "Bad Id", "name": "x", "root": "\(alpha)" },
          { "id": "relative", "name": "x", "root": "relative/path" },
          { "id": "escape", "name": "x", "root": "\(alpha)", "knowledge": "../secrets" },
          { "id": "alpha", "root": "\(alpha)/" },
          { "id": "alpha", "name": "dup", "root": "\(alpha)" }
        ] }
        """.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ProjectStore.load(from: file),
            [Project(id: "alpha", name: "alpha", root: alpha, knowledge: "docs/goals")],
            "one valid entry survives; the name defaults to the folder; the trailing slash is dropped"
        )

        try #"{ "version": 2, "projects": [] }"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectStore.load(from: file), [])
        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectStore.load(from: file), [])
    }

    func testSaveRoundTrips() throws {
        let alpha = try dir("alpha")
        let projects = [Project(id: "alpha", name: "Alpha", root: alpha, knowledge: "notes")]
        try ProjectStore.save(projects, to: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(ProjectStore.load(from: file), projects)
    }
}
