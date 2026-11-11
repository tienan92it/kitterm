import Foundation
import XCTest

@testable import KittermCLI

/// `kitterm round guard`, the `PreToolUse` hook of a crew session: what it
/// refuses, what it lets run, and its exit codes.
final class RoundGuardTests: XCTestCase {
    /// A repository whose base is `main`, checked out on `goal/x`.
    private static func git(current: String?, originHead: String? = "origin/main") -> RoundGuard.Git {
        { args, _ in
            switch args {
            case ["symbolic-ref", "--short", "HEAD"]: return current
            case ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]: return originHead
            default: return nil
            }
        }
    }

    private func refusal(_ command: String, current: String? = "goal/x", originHead: String? = "origin/main") -> String? {
        RoundGuard.refusal(command: command, cwd: "/repo", git: Self.git(current: current, originHead: originHead))
    }

    func testRefusesAPushToTheBase() {
        for command in [
            "git push origin main",
            "git push origin HEAD:main",
            "git push origin goal/x:refs/heads/main",
            "git -C /repo push origin goal/x:main",
            "cd sub && git push origin main",
            "GIT_TRACE=1 git push origin main",
            "git push --all origin",
        ] {
            XCTAssertNotNil(refusal(command), command)
        }
        XCTAssertNotNil(refusal("git push", current: "main"), "a bare push from the base")
        XCTAssertNotNil(refusal("git push origin", current: "main"))
        XCTAssertNotNil(refusal("git push origin HEAD", current: "main"))
    }

    func testRefusesAForcePush() {
        for command in [
            "git push --force origin goal/x",
            "git push -f origin goal/x",
            "git push -uf origin goal/x",
            "git push --force-with-lease origin goal/x",
            "git push --force-with-lease=goal/x:abc origin goal/x",
            "git push --force-if-includes origin goal/x",
            "git push --mirror origin",
            "git push origin +goal/x",
            "echo ok; git push origin goal/x --force",
        ] {
            XCTAssertNotNil(refusal(command), command)
        }
    }

    func testRefusesTheDaemonVerbs() {
        for command in [
            "kitterm start", "kitterm stop", "kitterm restart --port 3419",
            "/usr/local/bin/kitterm stop", ".build/debug/kitterm restart",
            "swift run kitterm start", "swift run -c release kitterm stop",
            "env KITTERM_STATE_DIR=/tmp/x kitterm start",
        ] {
            XCTAssertNotNil(refusal(command), command)
        }
    }

    /// The fresh-context review of `c496542` (`one-rule-one-place` round 3,
    /// correction 1): each of these ran past the guard.
    func testRefusesThroughShellSyntaxWrappersAndNestedShells() {
        for command in [
            "if true; then git push origin main; fi",
            "for i in 1; do git push --force origin goal/x; done",
            "{ git push origin main; }",
            "! git push -f",
            "timeout 60 git push origin main",
            "timeout 30 kitterm restart",
            "sudo kitterm stop",
            "nohup kitterm start &",
            "git push origin $(git rev-parse HEAD):main",
            "bash -c \"git push origin main\"",
            "git --git-dir .git push origin main",
            // The same holes, in their other forms.
            "while true; do kitterm stop; done",
            "until false; do git push origin main; done",
            "if git push origin main; then echo ok; fi",
            "(git push origin main)",
            "timeout -s KILL 5 git push origin main",
            "sudo -u root kitterm restart",
            "env -i PATH=/bin kitterm stop",
            "nice -n 5 git push origin main",
            "time -p git push origin main",
            "exec git push --force origin goal/x",
            "echo main | xargs git push origin",
            "echo stop | xargs kitterm",
            "sh -lc 'kitterm stop'",
            "zsh -c 'cd sub && git push origin main'",
            "eval git push origin main",
            "git -c user.name=x --work-tree . push origin main",
            "echo `kitterm stop`",
            "echo \"$(kitterm stop)\"",
            "bash <<EOF\ngit push origin main\nEOF",
            "git commit -m \"$(cat <<'EOF'\nDon't stop.\nEOF\n)\"; git push origin main",
        ] {
            XCTAssertNotNil(refusal(command), command)
        }
    }

    /// A destination that a substitution or a variable builds cannot be
    /// known, so the push is refused with the reason.
    func testRefusesADestinationItCannotKnow() {
        for command in [
            "git push origin $(git branch --show-current)",
            "git push origin \"$BRANCH\"",
            "git push origin HEAD:`cat branch`",
        ] {
            let reason = refusal(command)
            XCTAssertTrue(reason?.contains("a substitution builds") == true, "\(command): \(reason ?? "nil")")
        }
        XCTAssertNil(refusal("git push origin $(git rev-parse HEAD):goal/x"), "a built source, a known destination")
    }

    /// A here-document's body is text unless a shell reads it.
    func testAHereDocumentBodyIsText() {
        for command in [
            "cat <<EOF > notes.md\nkitterm stop\ngit push origin main\nEOF",
            "cat <<-'END'\n\tkitterm stop\n\tEND\ngit status",
            "git commit -m \"$(cat <<'EOF'\nDon't run kitterm stop (or git push origin main).\nEOF\n)\"",
        ] {
            XCTAssertNil(refusal(command), command)
        }
    }

    func testLetsTheCrewWork() {
        for command in [
            "git push origin goal/x",
            "git status",
            "echo \"git push origin main\"",
            "timeout 60 git push origin goal/x",
            "bash -c \"git push origin goal/x\"",
            "if true; then git status; fi",
            "git push -u origin goal/x",
            "git push origin HEAD",
            "git push",
            "git push --follow-tags origin goal/x",
            "git push origin goal/maintenance",
            "git commit -m 'git push origin main'",
            "echo \"kitterm stop\"",
            "kitterm status",
            "kitterm round open . slug --task item",
            "swift run kitterm version",
            "gh pr view 217",
            "ls -la",
        ] {
            XCTAssertNil(refusal(command), command)
        }
    }

    /// The base comes from `origin/HEAD`, else `KnowledgeBase.baseBranch`'s
    /// fallback `main`.
    func testTheBaseFollowsOriginHead() {
        XCTAssertNotNil(refusal("git push origin dev", originHead: "origin/dev"))
        XCTAssertNil(refusal("git push origin main", originHead: "origin/dev"))
        XCTAssertNotNil(refusal("git push origin main", originHead: nil))
    }

    func testSimpleCommands() {
        XCTAssertEqual(
            RoundGuard.simpleCommands("a 'b c' \"d\\\"e\" && f|g; h\ni (j) k\\ l"),
            [["a", "b c", "d\"e"], ["f"], ["g"], ["h"], ["i"], ["j"], ["k l"]]
        )
        XCTAssertEqual(
            RoundGuard.simpleCommands("git push origin $(git rev-parse HEAD):main; ls"),
            [["git", "rev-parse", "HEAD"], ["git", "push", "origin", "$(…):main"], ["ls"]]
        )
    }

    // MARK: - the hook's exit codes

    private func run(_ args: [String], _ input: String) -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = [], err: [String] = []
        let code = RoundGuard.run(
            args, input: { Data(input.utf8) }, git: Self.git(current: "goal/x"),
            out: { out.append($0) }, err: { err.append($0) }
        )
        return (code, out, err)
    }

    private func hookInput(_ command: String, tool: String = "Bash") -> String {
        let object: [String: Any] = ["tool_name": tool, "tool_input": ["command": command], "cwd": "/repo"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testExitCodes() {
        let refused = run([], hookInput("git push --force origin goal/x"))
        XCTAssertEqual(refused.code, 2)
        XCTAssertEqual(refused.err, [
            "kitterm round guard refused: a force push (--force). A crew session never does this; "
                + "post a BLOCKER note if the round needs it.",
        ])
        XCTAssertEqual(run([], hookInput("git push origin goal/x")).code, 0)
        XCTAssertEqual(run([], hookInput("anything", tool: "Edit")).code, 0, "only Bash is the guard's")
    }

    /// Input the guard cannot read is refused, so a broken hook is loud.
    func testUnreadableInputIsRefused() {
        XCTAssertEqual(run([], "not json").code, 2)
        XCTAssertEqual(run([], "{}").code, 2)
        XCTAssertEqual(run([], #"{"tool_name":"Bash","tool_input":{}}"#).code, 2)
    }

    func testCheckAndUsage() {
        let check = run(["--check"], "")
        XCTAssertEqual(check.code, 0)
        XCTAssertEqual(check.out, ["kitterm round guard: ready"])
        XCTAssertEqual(run(["--bogus"], "").code, 2)
    }

    /// `--check` answers with stdin still open, as from a terminal: the
    /// binary reads stdin only on the hook path (`one-rule-one-place`
    /// round 3, correction 1). Before the fix it blocked until stdin closed.
    func testCheckDoesNotReadStdin() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("kitterm")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("no kitterm binary beside the test bundle at \(binary.path)")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["round", "guard", "--check"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer { try? stdin.fileHandleForWriting.close() }
        guard exited.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            return XCTFail("`kitterm round guard --check` still waits on stdin after 10 s")
        }
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text, "kitterm round guard: ready\n")
    }
}
