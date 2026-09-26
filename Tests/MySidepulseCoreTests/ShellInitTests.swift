import XCTest
@testable import MySidepulseCore

/// The zsh snippet is a contract with something no compiler checks, so it is
/// exercised in a real interactive zsh against a stub CLI rather than compared
/// as a string to itself.
final class ShellInitTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mysidepulse-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try write("bin/mysidepulse", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$MYSIDEPULSE_LOG\"\n")
        try write("bin/vim", "#!/bin/sh\nexit 0\n")
        // Stand-ins for the prefixes and logins that must never run for real
        // in a test.
        for name in ["sudo", "caffeinate", "bash", "su", "login"] {
            try write("bin/\(name)", "#!/bin/sh\nexit 0\n")
        }
        try snippet.write(to: dir.appendingPathComponent("init.zsh"),
                          atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Generated against the stub's absolute path, which is the point: the
    /// snippet must not depend on PATH resolution. On this machine `mysidepulse`
    /// on PATH resolved to a different program entirely.
    var snippet: String {
        ShellInit.zsh(mysidepulsePath: dir.appendingPathComponent("bin/mysidepulse").path)
    }

    /// The threshold was written twice — once here, once as a literal in the
    /// snippet — so the two could drift apart silently. The snippet now
    /// carries whatever the constant says.
    func testTheSnippetCarriesTheShellShowAfterConstant() {
        let text = ShellInit.zsh(mysidepulsePath: "/bin/true")
        XCTAssertTrue(text.contains(": ${MYSIDEPULSE_SHOW_AFTER:=\(Int(K.shellShowAfterDefaultSeconds))}"),
                      "the default must come from K, not a literal:\n\(text)")
    }

    func testTheSnippetCallsTheBinaryThatGeneratedItByAbsolutePath() {
        let text = ShellInit.zsh(mysidepulsePath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse")
        XCTAssertTrue(text.contains("/Applications/MySidepulse.app/Contents/MacOS/mysidepulse job begin"),
                      "a PATH lookup can find a different mysidepulse — this machine had one")
        XCTAssertFalse(text.contains("command mysidepulse"))
    }

    func write(_ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Every `mysidepulse` invocation the commands made, in order, without
    /// the load's release of the shell's slot
    /// (`testTheLoadReleasesTheShellsSlotAsACancellation` holds that one).
    func zsh(_ commands: String, preamble: String = "") throws -> [String] {
        var calls = try zshCalls(commands, preamble: preamble)
        if calls.first?.hasPrefix("job end --id zsh-") == true { calls.removeFirst() }
        return calls
    }

    /// Every `mysidepulse` invocation the snippet made, in order, the load's
    /// own included, and every line the script itself wrote to the log.
    func zshCalls(_ commands: String, preamble: String = "") throws -> [String] {
        let log = dir.appendingPathComponent("log")
        try? FileManager.default.removeItem(at: log)
        // The preamble runs before the snippet is sourced, so its own command
        // lines predate the hooks and never register as jobs themselves.
        let script = """
        export MYSIDEPULSE_LOG=\(log.path)
        export PATH=\(dir.appendingPathComponent("bin").path):$PATH
        \(preamble)
        source \(dir.appendingPathComponent("init.zsh").path)
        \(commands)
        """
        try shell(["-f", "-i"], stdin: script)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    @discardableResult
    func shell(_ arguments: [String], stdin: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testTheSnippetIsSyntacticallyValidZsh() throws {
        XCTAssertEqual(try shell(["-n"], stdin: snippet), 0)
    }

    func testACommandBeginsAndEndsAJob() throws {
        let calls = try zsh("true")
        XCTAssertEqual(calls.count, 2, "one begin, one end — got \(calls)")
        XCTAssertTrue(calls[0].hasPrefix("job begin "), calls[0])
        XCTAssertTrue(calls[0].contains("--label true"), calls[0])
        XCTAssertTrue(calls[0].contains("--show-after \(Int(K.shellShowAfterDefaultSeconds))"),
                      "short commands must stay dark by default: \(calls[0])")
        XCTAssertTrue(calls[1].hasPrefix("job end "), calls[1])
        XCTAssertTrue(calls[1].contains("--exit 0"), calls[1])
    }

    func testTheJobIdIsStableForOneShell() throws {
        let calls = try zsh("true\ntrue")
        let ids = calls.compactMap { $0.split(separator: " ").dropFirst(3).first.map(String.init) }
        XCTAssertEqual(Set(ids).count, 1, "one shell owns one job slot: \(calls)")
    }

    func testAFailingCommandReportsItsExitStatus() throws {
        let calls = try zsh("(exit 3)")
        XCTAssertTrue(calls.last?.contains("--exit 3") == true, "\(calls)")
    }

    /// The plumbing half of the same rule: the hook must forward the real
    /// 130 rather than collapsing it to a generic failure.
    func testAnInterruptedCommandForwardsItsSignalStatus() throws {
        let calls = try zsh("sh -c 'kill -INT $$'")
        XCTAssertTrue(calls.last?.contains("--exit 130") == true, "\(calls)")
    }

    func testAnInteractiveCommandIsSkipped() throws {
        XCTAssertEqual(try zsh("vim"), [], "every editor session would hold the strip")
    }

    /// An agent is shown through its own hooks; as a command it would hold
    /// the strip for as long as its session stays open, working or not.
    /// Stand-ins, so no real agent ever runs.
    func testTheAgentsAreNeverCommands() throws {
        for agent in ["claude", "codex", "copilot", "opencode"] {
            try write("bin/\(agent)", "#!/bin/sh\nexit 0\n")
            XCTAssertEqual(try zsh(agent), [], agent)
            XCTAssertEqual(try zsh("\(agent) --help"), [], agent)
            XCTAssertEqual(try zsh("cd '\(dir.path)' && \(agent)"), [], agent)
        }
    }

    /// Neither app's own command is work: `koffeelid status` in a terminal is
    /// the sibling app's CLI, `mysidepulse status` this one's. Stand-ins.
    func testTheTwoAppsCommandsAreNeverCommands() throws {
        try write("bin/koffeelid", "#!/bin/sh\nexit 0\n")
        XCTAssertEqual(try zsh("koffeelid status"), [])
        XCTAssertEqual(try zsh("cd '\(dir.path)' && koffeelid arm"), [])
        XCTAssertEqual(try zsh("mysidepulse status"), ["status"], "the call itself, and no job around it")
    }

    func testTheSkipListIsUsersToExtend() throws {
        let calls = try zsh("true", preamble: "MYSIDEPULSE_SKIP=(true)")
        XCTAssertEqual(calls, [], "a user-set skip list replaces the default")
    }

    /// The line iBoysoft MagicMenu's "open in Claude" action generates is
    /// `cd '<dir>' && '<binary>' run`. Matching only the first word put the
    /// skip list out of reach of every such launcher, and the strip then
    /// followed an interactive session for the whole of its life.
    func testASkippedCommandIsFoundAfterACdOnTheSameLine() throws {
        XCTAssertEqual(try zsh("cd '\(dir.path)' && vim"), [],
                       "a launcher that prepends `cd …` must not hold the strip")
    }

    /// The same launchers quote the absolute path they generate, and `(z)`
    /// leaves the quotes on the word: the tail of `'/bin/vim'` is `vim'`,
    /// which matches nothing.
    func testAQuotedAbsolutePathIsMatchedAgainstTheSkipList() throws {
        let vim = dir.appendingPathComponent("bin/vim").path
        XCTAssertEqual(try zsh("'\(vim)'"), [],
                       "the closing quote must not become part of the name")
    }

    /// A group opener is not a command name: `(vim)` was skipped by nothing,
    /// because `(` was both the candidate and the label.
    func testAnInteractiveCommandInASubshellIsSkipped() throws {
        XCTAssertEqual(try zsh("(vim)"), [], "the subshell is not the command")
    }

    /// The other half of the rule. Reading the whole line must not become
    /// "skip any line that mentions a skipped word" — only a segment's head
    /// names a command.
    func testASkippedWordUsedAsAnArgumentStillTracksTheLine() throws {
        let calls = try zsh("true vim")
        XCTAssertEqual(calls.count, 2, "an argument is not the command — got \(calls)")
    }

    /// A compound line whose segments are all ordinary must stay tracked,
    /// which is what the launcher case must not cost.
    func testACompoundCommandWithNoSkippedSegmentIsStillTracked() throws {
        let calls = try zsh("cd '\(dir.path)' && true")
        XCTAssertEqual(calls.count, 2, "one begin, one end — got \(calls)")
        XCTAssertTrue(calls[0].hasPrefix("job begin "), calls[0])
    }

    /// Themes read `$?` in their own precmd hook. Ours runs first and must
    /// hand the command's real status on, not the status of its own CLI call.
    func testTheCommandsExitStatusSurvivesOurHook() throws {
        let calls = try zsh("""
        _mysidepulse_probe() { printf 'probe %s\\n' "$?" >> $MYSIDEPULSE_LOG }
        add-zsh-hook precmd _mysidepulse_probe
        (exit 3)
        """)
        XCTAssertTrue(calls.contains("probe 3"),
                      "our precmd clobbered the exit status: \(calls)")
    }

    // MARK: re-reading the snippet, prefixes, shells

    /// The shell's pid, written by the script before it sources the snippet.
    let printPid = #"print -r -- "pid $$" >> $MYSIDEPULSE_LOG"#

    func pid(in calls: [String]) throws -> String {
        String(try XCTUnwrap(calls.first { $0.hasPrefix("pid ") }).dropFirst(4))
    }

    func assertEveryBeginIsEnded(_ calls: [String], file: StaticString = #filePath, line: UInt = #line) {
        var open: String?
        for call in calls {
            if call.hasPrefix("job begin") {
                XCTAssertNil(open, "a job began while \(open ?? "") was still open: \(calls)", file: file, line: line)
                open = call
            } else if call.hasPrefix("job end") {
                open = nil
            }
        }
        XCTAssertNil(open, "left open: \(calls)", file: file, line: line)
    }

    /// `source ~/.zshrc` runs the snippet again inside the `source` command.
    /// An assignment at load emptied the job variable there, so `precmd`
    /// ended nothing and the strip stayed on a job nobody ran.
    func testResourcingTheSnippetKeepsTheRunningJob() throws {
        let calls = try zshCalls("source \(dir.appendingPathComponent("init.zsh").path)\ntrue", preamble: printPid)
        let pid = try pid(in: calls)
        let show = "--show-after \(Int(K.shellShowAfterDefaultSeconds))"
        let release = "job end --id zsh-\(pid) --exit 130"
        XCTAssertEqual(calls, ["pid \(pid)",
                               release,                                                  // the first load
                               "job begin --id zsh-\(pid) --pid \(pid) --label source \(show)",
                               release,                                                  // the load inside `source`
                               "job end --id zsh-\(pid) --exit 0",                       // precmd: the variable survived
                               "job begin --id zsh-\(pid) --pid \(pid) --label true \(show)",
                               "job end --id zsh-\(pid) --exit 0"])
    }

    /// The load ends whatever job the shell's pid held, as a cancellation,
    /// so an orphan never shows as an outcome; `exec zsh` keeps the pid, and
    /// the new image's load releases the slot the old one began.
    func testTheLoadReleasesTheShellsSlotAsACancellation() throws {
        let calls = try zshCalls("true", preamble: printPid)
        let pid = try pid(in: calls)
        XCTAssertEqual(calls.dropFirst().first, "job end --id zsh-\(pid) --exit 130", "\(calls)")

        // With `zsh` off the skip list, `exec zsh` begins a job the old image never ends.
        let snippet = dir.appendingPathComponent("init.zsh").path
        let exec = try zshCalls("exec /bin/zsh -f -i\n\(printPid)\nsource \(snippet)\ntrue",
                                preamble: "MYSIDEPULSE_SKIP=(vim)\n" + printPid)
        let pids = exec.filter { $0.hasPrefix("pid ") }
        XCTAssertEqual(pids.count, 2, "\(exec)")
        XCTAssertEqual(Set(pids).count, 1, "exec keeps the pid: \(exec)")
        XCTAssertEqual(exec.filter { $0.hasPrefix("job begin") && $0.contains("--label zsh ") }.count, 1, "\(exec)")
        let second = try XCTUnwrap(exec.lastIndex { $0.hasPrefix("pid ") })
        XCTAssertEqual(exec.dropFirst(second + 1).first, "job end --id zsh-\(try self.pid(in: exec)) --exit 130", "\(exec)")
        assertEveryBeginIsEnded(exec)
    }

    /// A prefix is not the program: `sudo vim` is vim, and so is every
    /// spelling below, with the prefixes' flags and their arguments.
    func testPrefixesAreSkippedBeforeTheHead() throws {
        // `env -i` clears PATH: the stand-in is named by its path, so no real vim ever runs.
        let stub = "'\(dir.appendingPathComponent("bin/vim").path)'"
        for line in ["sudo -n vim", "sudo -n -E vim", "FOO=1 vim", "FOO=1 BAR='a b' vim", "time vim", "env vim",
                     "command vim", "builtin vim", "nice vim", "nohup vim", "noglob vim", "caffeinate vim",
                     "true && sudo vim", "env -i \(stub)", "env -i FOO=1 \(stub)", "env -u HOME vim",
                     "nice -n 10 vim", "caffeinate -i vim", "sudo -u root vim", "sudo --chdir=/tmp vim",
                     "sudo -u root nice -n 5 vim", "exec vim"] {
            XCTAssertEqual(try zsh(line).filter { $0.hasPrefix("job begin") }, [], line)
        }
        for line in ["sudo make", "sudo -u root make"] {
            let make = try zsh(line)
            XCTAssertEqual(make.count, 2, "\(line): \(make)")
            XCTAssertTrue(make.first?.hasPrefix("job begin") == true, "\(line): \(make)")
            XCTAssertTrue(make.first?.contains("--label make ") == true, "\(line): \(make)")
        }
        let assigned = try zsh("FOO=1 true")
        XCTAssertTrue(assigned.first?.contains("--label true ") == true, "\(assigned)")
    }

    /// `sudo -i` opens a root shell: the line waits on something interactive.
    func testALineOfPrefixesAloneBeginsNothing() throws {
        XCTAssertEqual(try zsh("sudo -i"), [])
        XCTAssertEqual(try zsh("sudo -s"), [])
        XCTAssertEqual(try zsh("sudo -i && true"), [], "the line waits on the root shell")
        XCTAssertEqual(try zsh("FOO=1"), [], "an assignment runs nothing")
    }

    /// A shell counts as skipped only when it runs interactively, every word
    /// after its name being a flag; `su`, `login`, `tig` and `lazygit` are
    /// plain skips.
    func testInteractiveShellsNeverShow() throws {
        for line in ["bash", "bash -l", "zsh -f -i", "su", "login -f nobody"] {
            XCTAssertEqual(try zsh(line), [], line)
        }
    }

    /// A shell that runs a script is real work.
    func testAShellThatRunsAScriptShows() throws {
        for (line, label) in [("bash build.sh", "bash"), ("sh -c true", "sh"), ("zsh -f -c true", "zsh"),
                              ("true && bash build.sh", "true")] {
            let calls = try zsh(line)
            XCTAssertEqual(calls.count, 2, "\(line): \(calls)")
            XCTAssertTrue(calls.first?.contains("--label \(label) ") == true, "\(line): \(calls)")
        }
    }

    // MARK: the block in ~/.zshrc

    let line = ShellInit.zshrcLine(mysidepulsePath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse")
    var block: String {
        ([ShellInit.zshrcHeader] + ShellInit.zshrcDescription + [line, ShellInit.zshrcHeader])
            .joined(separator: "\n") + "\n"
    }
    /// Two neighbours the block must never mistake for its own: another
    /// tool's block, and the block this app's former name left behind.
    let koffeelid = "# ---------- KoffeeLid ----------\n"
        + #"[ -x "/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" ] && eval "$("/Applications/KoffeeLid.app/Contents/MacOS/KoffeeLid" shell-init zsh)""#
        + "\n# ---------- KoffeeLid ----------\n"
    let formerName = "# ---------- SidePulse ----------\n"
        + #"[ -x "/Applications/SidePulse.app/Contents/MacOS/sidepulse" ] && eval "$("/Applications/SidePulse.app/Contents/MacOS/sidepulse" shell-init zsh)""#
        + "\nSIDEPULSE_SKIP+=(cswap)\n# ---------- SidePulse ----------\n"

    func testANewZshrcStartsAndEndsWithTheHeader() {
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: ""), block)
        XCTAssertTrue(block.hasPrefix("# ---------- MySidepulse ----------\n"))
        XCTAssertTrue(block.hasSuffix("\n# ---------- MySidepulse ----------\n"))
        XCTAssertTrue(block.contains("is removed by"), "the block warns what Remove deletes")
    }

    /// MYSIDEPULSE_SKIP is otherwise invisible. The syntax is shown for
    /// *below* the block, where it extends the shipped list and survives.
    func testTheBlockDocumentsHowToSkipACommand() {
        XCTAssertTrue(ShellInit.zshrcDescription.contains { $0.contains("MYSIDEPULSE_SKIP+=(") })
        XCTAssertTrue(ShellInit.zshrcDescription.contains {
            $0.contains("default \(Int(K.shellShowAfterDefaultSeconds))")
        }, "the threshold in the comment comes from K")
    }

    func testAFileWithOrWithoutATrailingNewlineGetsOneBlankLineFirst() {
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: "export A=1"), "export A=1\n\n" + block)
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: "export A=1\n"), "export A=1\n\n" + block)
    }

    func testTheHeaderOrAnEvalLineOfOursMeansAlreadySetUp() {
        XCTAssertNil(ShellInit.zshrcAppending(line, to: "export A=1\n\n" + block))
        XCTAssertNil(ShellInit.zshrcAppending(line, to: #"eval "$(mysidepulse shell-init zsh)""# + "\n"))
    }

    func testACommentedOutEvalLineDoesNotCount() {
        let existing = "# " + line + "\n"
        XCTAssertFalse(ShellInit.zshrcSourcesSnippet(existing))
        XCTAssertEqual(ShellInit.zshrcAppending(line, to: existing), existing + "\n" + block)
    }

    func testAnotherToolsBlockAndTheFormerNamesBlockAreNotOurs() {
        for foreign in [koffeelid, formerName] {
            XCTAssertFalse(ShellInit.zshrcSourcesSnippet(foreign))
            XCTAssertEqual(ShellInit.zshrcAppending(line, to: foreign), foreign + "\n" + block)
            XCTAssertNil(ShellInit.zshrcRemoving(from: foreign), "nothing of ours to remove")
        }
    }

    func testRemovingUndoesAppending() {
        for original in ["", "export A=1", "export A=1\n", "# a comment\nexport A=1\n", koffeelid, formerName] {
            let added = ShellInit.zshrcAppending(line, to: original)!
            let expected = original.isEmpty || original.hasSuffix("\n") ? original : original + "\n"
            XCTAssertEqual(ShellInit.zshrcRemoving(from: added), expected,
                           "round trip for \(original.debugDescription)")
        }
    }

    func testRemovingLeavesTheNeighboursAloneWhereverTheBlocksSit() {
        XCTAssertEqual(ShellInit.zshrcRemoving(from: koffeelid + "\n" + block + "\nexport B=2\n"),
                       koffeelid + "\nexport B=2\n")
        XCTAssertEqual(ShellInit.zshrcRemoving(from: block + "\n" + formerName), formerName)
    }

    func testRemovingTakesEverythingBetweenTheTwoHeaders() {
        let text = "export A=1\n\n" + ShellInit.zshrcHeader + "\n" + line
            + "\nMYSIDEPULSE_SKIP+=(cswap)\n" + ShellInit.zshrcHeader + "\n\nexport B=2\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text), "export A=1\n\nexport B=2\n",
                       "the block's own comment says so")
    }

    func testRemovingKeepsAForeignLineAfterAnUnclosedHeader() {
        let text = "export A=1\n\n" + ShellInit.zshrcHeader + "\n" + line + "\nexport MINE=1\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: text), "export A=1\n\nexport MINE=1\n",
                       "only the header and our line go")
    }

    func testRemovingTakesAHandWrittenLineAndKeepsACommentedCopy() {
        let hand = "export A=1\n" + line + "\n# " + line + "\n"
        XCTAssertEqual(ShellInit.zshrcRemoving(from: hand), "export A=1\n# " + line + "\n")
        XCTAssertNil(ShellInit.zshrcRemoving(from: "export A=1\n"), "nothing to remove")
    }

    /// The block is a third text no compiler checks: sourced by a real zsh, it
    /// must load the snippet through the guarded line, and stay silent and
    /// harmless when the binary is gone.
    func testTheBlockLoadsTheSnippetInARealZshAndIsSilentWithoutTheApp() throws {
        try write("bin/cli", "#!/bin/sh\n[ \"$1 $2\" = 'shell-init zsh' ] && cat \"\(dir.path)/init.zsh\"\n")
        let out = dir.appendingPathComponent("out")
        for (cli, expected) in [("bin/cli", "loaded\n"), ("bin/gone", "absent\n")] {
            let zshrc = try XCTUnwrap(ShellInit.zshrcAppending(
                ShellInit.zshrcLine(mysidepulsePath: dir.appendingPathComponent(cli).path), to: "export A=1\n"))
            try zshrc.write(to: dir.appendingPathComponent("zshrc"), atomically: true, encoding: .utf8)
            let status = try shell(["-f"], stdin: """
            source \(dir.path)/zshrc
            if typeset -f _mysidepulse_preexec >/dev/null; then print loaded; else print absent; fi > \(out.path)
            """)
            XCTAssertEqual(status, 0)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), expected, cli)
        }
    }
}
