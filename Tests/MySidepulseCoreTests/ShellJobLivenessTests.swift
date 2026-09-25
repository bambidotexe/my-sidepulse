import XCTest
@testable import MySidepulseCore

/// Whether a terminal job's shell still runs a command, asked of the shell:
/// the table of what a probe finds and what the job becomes.
final class ShellJobLivenessTests: XCTestCase {
    typealias Probe = ShellJobLiveness.Probe
    typealias Reading = ShellJobLiveness.Reading
    let gone = Probe(alive: false, isShell: true, atPrompt: false, hasChildren: false)
    let replaced = Probe(alive: true, isShell: false, atPrompt: true, hasChildren: false)
    let atPrompt = Probe(alive: true, isShell: true, atPrompt: true, hasChildren: false)
    let atPromptWithChild = Probe(alive: true, isShell: true, atPrompt: true, hasChildren: true)
    let running = Probe(alive: true, isShell: true, atPrompt: false, hasChildren: true)

    func testAShellGoneDropsTheJob() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(gone, promptSeenAt: &seen, now: at(0)), .drop(reason: "shell gone"))
    }

    func testAShellReplacedByItsProgramIsKept() {
        var seen: Date? = at(0)
        XCTAssertEqual(ShellJobLiveness.judge(replaced, promptSeenAt: &seen, now: at(60)), .keep,
                       "exec'd into the program: its exit ends the job")
        XCTAssertNil(seen)
    }

    func testAShellAtItsPromptWithNoChildIsDroppedOnceSettled() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(0)), .keep, "first sighting")
        XCTAssertEqual(seen, at(0))
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(4)), .keep, "not settled yet")
        XCTAssertEqual(seen, at(0), "the first sighting stands")
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(K.jobPromptSettleSeconds)),
                       .drop(reason: "shell at its prompt"))
    }

    func testAChildOrAForegroundCommandResetsTheSettle() {
        var seen: Date?
        _ = ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(0))
        XCTAssertEqual(ShellJobLiveness.judge(atPromptWithChild, promptSeenAt: &seen, now: at(3)), .keep,
                       "a child: the shell still runs something")
        XCTAssertNil(seen)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(6)), .keep, "the settle starts again")
        XCTAssertEqual(seen, at(6))
        XCTAssertEqual(ShellJobLiveness.judge(running, promptSeenAt: &seen, now: at(9)), .keep, "a foreground command")
        XCTAssertNil(seen)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(12)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(atPrompt, promptSeenAt: &seen, now: at(17)), .drop(reason: "shell at its prompt"))
    }

    func testARunningCommandIsKeptWithNoTimeLimit() {
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(running, promptSeenAt: &seen, now: at(6 * 3600)), .keep)
        XCTAssertNil(seen)
    }

    // MARK: the probe, from what the platform read

    func testTheProbeIsReadFromTheShellsProcess() {
        let since = at(100)
        let shell = Reading(isShell: true, pgid: 7, tpgid: 7, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(shell, children: [], jobSince: since), atPrompt)
        let busy = Reading(isShell: true, pgid: 7, tpgid: 900, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(busy, children: [at(100.5)], jobSince: since), running)
        let program = Reading(isShell: false, pgid: 7, tpgid: 7, startedAt: at(10))
        XCTAssertEqual(ShellJobLiveness.probe(program, children: [], jobSince: since), replaced,
                       "exec keeps the start time: the program is the shell's own process")
        XCTAssertFalse(ShellJobLiveness.probe(nil, children: [], jobSince: since).alive, "no such process")
        let noTerminal = Reading(isShell: true, pgid: 7, tpgid: 0, startedAt: at(10))
        XCTAssertFalse(ShellJobLiveness.probe(noTerminal, children: [], jobSince: since).atPrompt,
                       "no terminal: never at a prompt")
    }

    func testAPidHeldByAProcessStartedAfterTheJobBeganIsTheShellGone() {
        let since = at(100)
        let recycled = Reading(isShell: false, pgid: 7, tpgid: 0, startedAt: at(101))
        let probe = ShellJobLiveness.probe(recycled, children: [], jobSince: since)
        XCTAssertFalse(probe.alive, "a recycled pid is not the shell that began the job")
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(probe, promptSeenAt: &seen, now: at(110)), .drop(reason: "shell gone"))
        let recycledShell = Reading(isShell: true, pgid: 7, tpgid: 7, startedAt: at(101))
        XCTAssertFalse(ShellJobLiveness.probe(recycledShell, children: [], jobSince: since).alive,
                       "not even when the newcomer is a shell")
        let unknownStart = Reading(isShell: true, pgid: 7, tpgid: 7, startedAt: nil)
        XCTAssertTrue(ShellJobLiveness.probe(unknownStart, children: [], jobSince: since).alive,
                      "a start that cannot be read proves nothing")
    }

    func testOnlyAChildStartedSinceTheJobBeganCounts() {
        let since = at(100)
        let shell = Reading(isShell: true, pgid: 7, tpgid: 7, startedAt: at(10))
        // Powerlevel10k's gitstatusd lives beside every interactive shell from
        // its start, in the shell's own process group; an earlier `&` job
        // likewise predates the job.
        let older = ShellJobLiveness.probe(shell, children: [at(11), at(50)], jobSince: since)
        XCTAssertFalse(older.hasChildren)
        var seen: Date?
        XCTAssertEqual(ShellJobLiveness.judge(older, promptSeenAt: &seen, now: at(115)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(older, promptSeenAt: &seen, now: at(120)), .drop(reason: "shell at its prompt"),
                       "a child older than the job says nothing about it")
        let younger = ShellJobLiveness.probe(shell, children: [at(11), at(100.2)], jobSince: since)
        XCTAssertTrue(younger.hasChildren)
        seen = nil
        XCTAssertEqual(ShellJobLiveness.judge(younger, promptSeenAt: &seen, now: at(115)), .keep)
        XCTAssertEqual(ShellJobLiveness.judge(younger, promptSeenAt: &seen, now: at(120)), .keep,
                       "a child the job started keeps it")
        XCTAssertFalse(ShellJobLiveness.probe(shell, children: [since], jobSince: since).hasChildren,
                       "started at the begin: before the command")
    }
}
