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

    func testLetsTheCrewWork() {
        for command in [
            "git push origin goal/x",
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
    }

    // MARK: - the hook's exit codes

    private func run(_ args: [String], _ input: String) -> (code: Int32, out: [String], err: [String]) {
        var out: [String] = [], err: [String] = []
        let code = RoundGuard.run(
            args, input: Data(input.utf8), git: Self.git(current: "goal/x"),
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
}
