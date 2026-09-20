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

    /// Every `mysidepulse` invocation the snippet made, in order.
    func zsh(_ commands: String, preamble: String = "") throws -> [String] {
        let log = dir.appendingPathComponent("log")
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
