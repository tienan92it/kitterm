import XCTest

@testable import KittermDaemon

/// The two pure matchers of `PullNudge` (`sessions-workflow` round 8): which
/// command lines and which crew notes read a repository's pull requests at
/// once.
final class PullNudgeTests: XCTestCase {
    func testCommandsThatPushOrChangeAPullRequest() {
        for line in [
            "git push", "git push origin x", "git push -u origin goal/sessions-workflow",
            "gh pr create --draft --title t", "gh pr merge 12 --squash", "gh pr ready 196",
            "gh pr close 7", "gh pr edit 196 --add-label x", "gh pr review 12 --approve",
            "git commit -m x && git push", "git add -A; git commit -m x; git push origin HEAD",
            "GIT_SSH_COMMAND='ssh -i k' git push", "git push 2>&1 | tail -1", "  git push  ",
            "false || gh pr create", "gh pr create --title \"a; b\" --body 'x | y'",
        ] {
            XCTAssertTrue(PullNudge.commandNudges(line: line), line)
        }
    }

    func testCommandsThatDoNot() {
        for line in [
            "git pushd", "git pull", "git status", "echo gh pr create", "echo git push",
            "gh pr list", "gh pr view 196", "gh pr checks 196 --watch", "gh pr diff 12",
            "gh issue create", "gh run list", "mygit push", "git", "gh pr", "",
            "cat git push", "ls gh/pr/create", "FOO=git push", "git-push",
            "echo \"a; git push\"", "echo 'gh pr merge 1'", "grep 'git push' notes.md",
        ] {
            XCTAssertFalse(PullNudge.commandNudges(line: line), line)
        }
    }

    func testNotesThatFollowAPush() {
        XCTAssertTrue(PullNudge.noteNudges(message: "PROGRESS sessions-workflow r8: abc1234 pushed"))
        XCTAssertTrue(PullNudge.noteNudges(message: "DONE sessions-workflow r8: the shas\nmore lines"))
        XCTAssertTrue(PullNudge.noteNudges(message: "DONE 1/2 sessions-workflow r8: part one"))
        XCTAssertFalse(PullNudge.noteNudges(message: "PLAN sessions-workflow r8: first"))
        XCTAssertFalse(PullNudge.noteNudges(message: "BLOCKER sessions-workflow r8: need you"))
        XCTAssertFalse(PullNudge.noteNudges(message: "plan ready for review\nPROGRESS later"))
        XCTAssertFalse(PullNudge.noteNudges(message: "PROGRESSING"))
        XCTAssertFalse(PullNudge.noteNudges(message: "DONE"))
        XCTAssertFalse(PullNudge.noteNudges(message: ""))
    }
}
