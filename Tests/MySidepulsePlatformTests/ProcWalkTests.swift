import XCTest
@testable import MySidepulsePlatform

final class ProcWalkTests: XCTestCase {
    func testChainStartsAtSelfParentAndReachesInit() {
        let chain = ProcWalk.chain(from: getpid())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertEqual(chain.first?.pid, getpid())
        XCTAssertFalse(chain.first!.name.isEmpty)
    }

    /// The CLI ships INSIDE MySidepulse.app, so a chain that starts at the CLI
    /// itself resolves to MySidepulse's own bundle. `io.mysidepulse.app` is an
    /// LSUIElement with no windows and can never be frontmost, so a job
    /// tagged with it can never be acknowledged — it holds the strip for the
    /// full twenty minutes no matter what the user does. Callers must start
    /// the walk at the PARENT, which is what the hook already does.
    func testAWalkThatIncludesTheCliItselfResolvesToMySidepulseNotTheTerminal() {
        func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path)
        }
        let cli = proc(900, 800, "mysidepulse", "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse")
        let rest = [
            proc(800, 700, "zsh", "/bin/zsh"),
            proc(700, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        XCTAssertEqual(ProcWalk.classify([cli] + rest).hostBundlePath,
                       "/Applications/MySidepulse.app",
                       "including self swallows the terminal — this is the trap")
        XCTAssertEqual(ProcWalk.classify(rest).hostBundlePath,
                       "/System/Applications/Utilities/Terminal.app",
                       "starting at the parent finds the terminal the user actually focuses")
    }

    /// The live equivalent of the above, against this process's real ancestry.
    func testTheCallerHostWalkNeverReportsMySidepulseItself() {
        XCTAssertNotEqual(ProcWalk.callerHostBundleId(), "io.mysidepulse.app",
                          "a job tagged with MySidepulse's own bundle is unacknowledgeable")
    }

    func testClassifyFindsClaudeAndOutermostBundle() {
        func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path)
        }
        let chain = [
            proc(500, 400, "sh", "/bin/sh"),
            proc(400, 300, "claude", "/Users/u/.local/bin/claude"),
            proc(300, 200, "zsh", "/bin/zsh"),
            proc(200, 1, "ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ]
        let origin = ProcWalk.classify(chain)
        XCTAssertEqual(origin.agentPid, 400)
        XCTAssertEqual(origin.hostAppPid, 200)
        XCTAssertEqual(origin.hostBundlePath, "/Applications/Ghostty.app")

        let helper = [
            proc(500, 400, "claude", "/opt/claude"),
            proc(400, 1, "Code Helper", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
        ]
        XCTAssertEqual(ProcWalk.classify(helper).hostBundlePath, "/Applications/Visual Studio Code.app",
                       "outermost .app wins for nested helper bundles")

        let headless = [proc(500, 400, "claude", "/opt/claude"), proc(400, 1, "sshd", "/usr/sbin/sshd")]
        let h = ProcWalk.classify(headless)
        XCTAssertEqual(h.agentPid, 500)
        XCTAssertNil(h.hostBundlePath, "no host app over ssh/tmux — fields omitted")
    }

    func testClaudePathRecognisesBothRealInstallShapes() {
        // The symlink launcher, and the native installer's versioned target.
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/u/.local/bin/claude"))
        XCTAssertTrue(ProcWalk.isClaudePath("/Users/u/.local/share/claude/versions/2.1.238"))
        XCTAssertFalse(ProcWalk.isClaudePath("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
        XCTAssertFalse(ProcWalk.isClaudePath("/bin/zsh"))
        XCTAssertFalse(ProcWalk.isClaudePath("/Applications/MySidepulse.app/Contents/MacOS/mysidepulse"))
    }

    func testClassifyFindsClaudeFromAVersionedExecPath() {
        func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path)
        }
        // A real shape this daemon takes: p_comm is the version string and
        // proc_pidpath is the versioned target, not "claude".
        let chain = [
            proc(500, 400, "sh", "/bin/sh"),
            proc(400, 300, "2.1.238", "/Users/u/.local/share/claude/versions/2.1.238"),
            proc(300, 200, "zsh", "/bin/zsh"),
            proc(200, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        let origin = ProcWalk.classify(chain)
        XCTAssertEqual(origin.agentPid, 400)
        XCTAssertEqual(origin.hostAppPid, 200)
    }

    // MARK: - the tab a session is displayed in

    private func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?,
                      _ tty: String? = nil) -> ProcWalk.ProcInfo {
        ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path, tty: tty)
    }

    /// The real-tab shape: one tty holds all the way from Claude up to the
    /// login the terminal started.
    func testATabTTYIsTrustedWhenAShellUnderTheHostAppHoldsIt() {
        let chain = [
            proc(4317, 82789, "zsh", "/bin/zsh", nil),
            proc(82789, 82656, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys002"),
            proc(82656, 82655, "zsh", "/bin/zsh", "ttys002"),
            proc(82655, 5713, "login", "/usr/bin/login", "ttys002"),
            proc(5713, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", nil),
        ]
        let origin = ProcWalk.classify(chain)
        XCTAssertEqual(origin.agentPid, 82789)
        XCTAssertEqual(origin.tabTTY, "ttys002", "a tab the user can focus")
    }

    /// The Claude Code daemon allocates a pty of its own (`daemon run` →
    /// `bg-pty-host` → `bg-spare`) distinct from the tty the user actually
    /// watches. Recording that pty as a tab left a real green
    /// unacknowledgeable for 4 m 58 s in one recorded case, because the tty
    /// breaks at the first hop above Claude, which has no controlling
    /// terminal at all.
    func testADaemonPtyIsNotATabEvenWhenTheChainReachesTheTerminal() {
        let chain = [
            proc(25408, 25392, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys006"),
            proc(25392, 25069, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", nil),
            proc(25069, 7990, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", nil),
            proc(7990, 5715, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys000"),
            proc(5715, 5714, "zsh", "/bin/zsh", "ttys000"),
            proc(5714, 5713, "login", "/usr/bin/login", "ttys000"),
            proc(5713, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", nil),
        ]
        let origin = ProcWalk.classify(chain)
        XCTAssertEqual(origin.agentPid, 25408, "the process that ran the turn")
        XCTAssertEqual(origin.hostBundlePath,
                       "/System/Applications/Utilities/Terminal.app",
                       "the host still resolves — this is why the bundle gate passed")
        XCTAssertNil(origin.tabTTY, "ttys006 has no window behind it; no tab to name")
    }

    /// The same daemon after its Terminal ancestor exits: the chain ends at
    /// the daemon, so there is no host and no tab either.
    func testAnOrphanedDaemonHasNoTabAndNoHost() {
        let chain = [
            proc(84554, 84534, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys004"),
            proc(84534, 25069, "claude", "/Users/u/.local/share/claude/versions/2.1.270", nil),
            proc(25069, 1, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", nil),
        ]
        let origin = ProcWalk.classify(chain)
        XCTAssertNil(origin.hostBundlePath)
        XCTAssertNil(origin.tabTTY)
    }

    /// Two degenerate shapes that must not be read as a tab: Claude itself
    /// resolving to the host bundle (nothing in between to hold the tty), and
    /// a chain with no controlling terminal anywhere — where `devname` would
    /// otherwise hand every hop the same "??" and make them agree.
    func testNoShellBetweenClaudeAndTheHostIsNotATab() {
        let selfHosted = [
            proc(500, 400, "claude", "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", "ttys004"),
            proc(400, 1, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", nil),
        ]
        let origin = ProcWalk.classify(selfHosted)
        XCTAssertEqual(origin.hostAppPid, 500, "the bundle is Claude's own")
        XCTAssertNil(origin.tabTTY, "a bundle that is the claude process names no tab")

        let headless = [
            proc(500, 400, "claude", "/opt/claude", nil),
            proc(400, 300, "zsh", "/bin/zsh", nil),
            proc(300, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", nil),
        ]
        XCTAssertNil(ProcWalk.classify(headless).tabTTY, "no tty anywhere is no tab")
    }

    /// A helper agent under the main agent shares the user's tab, and must
    /// keep it: the tty is unbroken from the helper up to the login.
    func testAHelperClaudeUnderTheMainAgentKeepsTheTab() {
        let chain = [
            proc(600, 500, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys001"),
            proc(500, 400, "2.1.270", "/Users/u/.local/share/claude/versions/2.1.270", "ttys001"),
            proc(400, 300, "zsh", "/bin/zsh", "ttys001"),
            proc(300, 1, "iTerm2", "/Applications/iTerm.app/Contents/MacOS/iTerm2", "ttys001"),
        ]
        XCTAssertEqual(ProcWalk.classify(chain).tabTTY, "ttys001")
    }

    /// NODEV must read as "no terminal" whichever way `e_tdev` imports, or a
    /// daemon would be handed devname's "??" as its tab.
    func testNodevAndUnnamedDevicesAreNotTTYs() {
        XCTAssertNil(ProcWalk.ttyName(forDevice: 0))
        XCTAssertNil(ProcWalk.ttyName(forDevice: -1))
        XCTAssertNil(ProcWalk.ttyName(forDevice: UInt32.max))
    }

    func testBootDateIsPast() throws {
        let boot = try XCTUnwrap(BootTime.bootDate())
        XCTAssertLessThan(boot, Date())
        XCTAssertGreaterThan(boot, Date(timeIntervalSinceNow: -365 * 24 * 3600))
    }
}
