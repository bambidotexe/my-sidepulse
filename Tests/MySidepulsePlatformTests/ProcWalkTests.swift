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

    /// Copilot's executable is `copilot` wherever it lives; OpenCode's server
    /// runs `opencode`, `opencode-cli` or `.opencode`. A path is theirs by its
    /// last component only: a `copilot` folder holds other programs.
    func testCopilotAndOpenCodePathsAreKnownByTheirExecutable() {
        XCTAssertTrue(ProcWalk.isCopilotPath("/Users/u/.local/bin/copilot"))
        XCTAssertTrue(ProcWalk.isCopilotPath("/Users/u/Library/Caches/github-copilot-sdk/cli/1.0.87-0/copilot"))
        XCTAssertFalse(ProcWalk.isCopilotPath("/Applications/GitHub Copilot.app/Contents/MacOS/github"))
        XCTAssertFalse(ProcWalk.isCopilotPath("/Users/u/Library/Caches/copilot/pkg/darwin-arm64/1.0.88/rg"))
        XCTAssertTrue(ProcWalk.isOpencodePath("/Users/u/.opencode/bin/opencode"))
        XCTAssertTrue(ProcWalk.isOpencodePath("/Applications/OpenCode.app/Contents/Resources/opencode-cli"))
        XCTAssertTrue(ProcWalk.isOpencodePath("/usr/local/lib/node_modules/@opencode/cli/bin/.opencode"))
        XCTAssertFalse(ProcWalk.isOpencodePath("/Users/u/.opencode/bin/opencode2"), "the sh launcher execs the real one")
        XCTAssertFalse(ProcWalk.isOpencodePath("/Applications/OpenCode.app/Contents/MacOS/OpenCode"))

        func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path)
        }
        XCTAssertEqual(ProcWalk.classify([proc(500, 1, "copilot-1.0.88", "/opt/homebrew/bin/copilot")]).agent, .copilot,
                       "by the path when the name says otherwise")
        XCTAssertEqual(ProcWalk.classify([proc(500, 1, "bun", "/Users/u/.opencode/bin/opencode")]).agent, .opencode)
        let app = [
            proc(600, 500, "copilot", "/Users/u/Library/Caches/github-copilot-sdk/cli/1.0.87-0/copilot"),
            proc(500, 1, "github", "/Applications/GitHub Copilot.app/Contents/MacOS/github"),
        ]
        XCTAssertEqual(ProcWalk.classify(app).agentPid, 600)
        XCTAssertEqual(ProcWalk.classify(app).hostBundlePath, "/Applications/GitHub Copilot.app")
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

    /// Codex's managed daemon (`codex app-server --listen unix:// --managed-daemon`,
    /// run from `~/.codex/packages/app-server-daemon/…/bin/codex`) hosts every
    /// TUI session's hooks, so its pid is what they record. It is told apart
    /// by its arguments, or by its install folder when they cannot be read.
    func testTheManagedDaemonIsRecognisedByItsArguments() throws {
        let stand = Process()
        stand.executableURL = URL(fileURLWithPath: "/bin/sh")
        stand.arguments = ["-c", "sleep 30; :", "app-server", "--listen", "unix://", "--managed-daemon"]
        try stand.run()
        addTeardownBlock { stand.terminate() }
        let info = try XCTUnwrap(ProcWalk.info(for: stand.processIdentifier))
        XCTAssertEqual(ProcWalk.arguments(for: stand.processIdentifier)?.contains("app-server"), true)
        XCTAssertTrue(ProcWalk.isCodexDaemon(info))

        let me = try XCTUnwrap(ProcWalk.info(for: getpid()))
        XCTAssertFalse(ProcWalk.isCodexDaemon(me))

        func gone(_ path: String) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: 999_999, ppid: 1, name: "codex", path: path)
        }
        XCTAssertTrue(ProcWalk.isCodexDaemon(gone(
            "/Users/u/.codex/packages/app-server-daemon/releases/0.157.0-aarch64-apple-darwin/bin/codex")))
        XCTAssertFalse(ProcWalk.isCodexDaemon(gone(
            "/Users/u/.codex/packages/standalone/releases/0.157.0-aarch64-apple-darwin/bin/codex")))
        XCTAssertFalse(ProcWalk.isCodexDaemon(gone("/Applications/ChatGPT.app/Contents/Resources/codex")))
    }

    /// Only the managed daemon's own threads are asked about at its control
    /// socket: the ChatGPT app's `codex app-server` is a shared app-server
    /// too, but its threads are not the daemon's, which would call a live one
    /// `notLoaded`.
    func testOnlyTheManagedDaemonIsTheOneWithAControlSocket() throws {
        func stand(_ args: [String]) throws -> ProcWalk.ProcInfo {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 30; :"] + args
            try process.run()
            addTeardownBlock { process.terminate() }
            return try XCTUnwrap(ProcWalk.info(for: process.processIdentifier))
        }
        let managed = try stand(["app-server", "--listen", "unix://", "--managed-daemon"])
        XCTAssertTrue(ProcWalk.isManagedCodexDaemon(managed))
        let desktop = try stand(["-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"])
        XCTAssertTrue(ProcWalk.isCodexDaemon(desktop), "the desktop app's codex is a shared app-server")
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(desktop), "but not the managed daemon")
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(try XCTUnwrap(ProcWalk.info(for: getpid()))))

        func gone(_ path: String) -> ProcWalk.ProcInfo {
            ProcWalk.ProcInfo(pid: 999_999, ppid: 1, name: "codex", path: path)
        }
        XCTAssertTrue(ProcWalk.isManagedCodexDaemon(gone(
            "/Users/u/.codex/packages/app-server-daemon/releases/0.157.0-aarch64-apple-darwin/bin/codex")),
            "by its install folder when the arguments cannot be read")
        XCTAssertFalse(ProcWalk.isManagedCodexDaemon(gone("/Applications/ChatGPT.app/Contents/Resources/codex")))
    }

    /// A job's shell exec'd into its program is no longer a shell: its
    /// `p_comm` is the program's. A login shell's starts with a dash.
    func testShellNamesAreRecognisedWithALoginDash() {
        for name in ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "dash", "ksh", "tcsh", "-tcsh"] {
            XCTAssertTrue(ProcWalk.ProcInfo(pid: 1, ppid: 0, name: name, path: nil).isShell, name)
        }
        for name in ["make", "sleep", "claude", "zshx", "-", "", "--zsh", "ssh", "mysidepulse"] {
            XCTAssertFalse(ProcWalk.ProcInfo(pid: 1, ppid: 0, name: name, path: nil).isShell, name)
        }
    }

    /// The process group, its terminal's foreground group, the fork time, and
    /// each child's fork time, read from the same `kinfo_proc`.
    func testTheProcessGroupStartAndChildrenAreRead() throws {
        let own = try XCTUnwrap(ProcWalk.info(for: getpid()))
        XCTAssertEqual(own.pgid, getpgrp())
        let started = try XCTUnwrap(own.startedAt)
        XCTAssertLessThan(started, Date())
        XCTAssertGreaterThan(started, Date().addingTimeInterval(-24 * 3600))
        let before = Date().addingTimeInterval(-1)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let childStart = try XCTUnwrap(ProcWalk.info(for: child.processIdentifier)?.startedAt)
        XCTAssertGreaterThan(childStart, before)
        XCTAssertTrue(ProcWalk.childStartTimes(pid: getpid()).contains(childStart), "the child is listed with its start")
        XCTAssertEqual(ProcWalk.childStartTimes(pid: child.processIdentifier), [])
        XCTAssertEqual(ProcWalk.childStartTimes(pid: 2_000_000), [])
        XCTAssertNil(ProcWalk.info(for: 2_000_000))
    }

    func testBootDateIsPast() throws {
        let boot = try XCTUnwrap(BootTime.bootDate())
        XCTAssertLessThan(boot, Date())
        XCTAssertGreaterThan(boot, Date(timeIntervalSinceNow: -365 * 24 * 3600))
    }

    // MARK: a shell under an agent

    /// Pids no process holds, so the classification decides on the name and
    /// path alone.
    func shell(under parents: [(name: String, path: String?)]) -> [ProcWalk.ProcInfo] {
        var chain = [ProcWalk.ProcInfo(pid: 999_900, ppid: 999_901, name: "zsh", path: "/bin/zsh")]
        for (i, parent) in parents.enumerated() {
            chain.append(ProcWalk.ProcInfo(pid: 999_901 + Int32(i), ppid: 999_902 + Int32(i),
                                           name: parent.name, path: parent.path))
        }
        return chain
    }

    /// An agent's tool shell, or a shell a script it started opened, runs the
    /// agent's own work: the shells seen under OpenCode's server and Codex's
    /// app-server daemon, and under Claude Code and Copilot.
    func testAShellUnderAnAgentIsThatAgents() {
        let launchd = (name: "launchd", path: Optional("/sbin/launchd"))
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [
            ("opencode", "/Users/u/.opencode/bin/opencode"), launchd])), .opencode)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [
            ("codex", "/Users/u/.codex/packages/app-server-daemon/releases/0.157.1-aarch64-apple-darwin/bin/codex"),
            launchd])), .codex)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [
            ("2.1.90", "/Users/u/.local/share/claude/versions/2.1.90"), ("zsh", "/bin/zsh"),
            ("login", "/usr/bin/login")])), .claude)
        XCTAssertEqual(ProcWalk.hostingAgent(in: shell(under: [
            ("copilot", "/Users/u/.local/bin/copilot"), ("zsh", "/bin/zsh")])), .copilot)
    }

    /// A shell in a terminal, an editor or a desktop app's own window is the
    /// user's.
    func testAShellInATerminalOrAnAppIsNoAgents() {
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [
            ("login", "/usr/bin/login"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [
            ("Code Helper", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [
            ("Claude", "/Applications/Claude.app/Contents/MacOS/Claude"),
            ("Codex", "/Applications/Codex.app/Contents/MacOS/Codex")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: shell(under: [
            ("tmux", "/opt/homebrew/bin/tmux"), ("launchd", "/sbin/launchd")])))
        XCTAssertNil(ProcWalk.hostingAgent(in: []))
    }
}
