import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class JournalWriterTests: XCTestCase {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-test-\(UUID().uuidString).jsonl")
    }

    func testAppendCreatesAndAppendsWithNewline() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(JournalWriter.append(Data("{\"a\":1}".utf8), to: url))
        XCTAssertTrue(JournalWriter.append(Data("{\"b\":2}".utf8), to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{\"a\":1}\n{\"b\":2}\n")
    }

    /// A job's lines go where the hook's do, one line each, in a folder the
    /// writer makes when it is missing, and read back as written.
    func testTheJobLinesAreAppendedToTheJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mysidepulse-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_787_652_000)
        let begin = JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make", showAfterSeconds: 5,
                                  hostBundleId: "com.apple.Terminal", loggedAt: t0)
        let end = JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: t0.addingTimeInterval(9))
        XCTAssertTrue(JobJournal.append(begin, to: url))
        XCTAssertTrue(JobJournal.append(end, to: url))
        XCTAssertEqual(JournalTailer.readAll(url: url), [begin, end])
        XCTAssertFalse(JobJournal.append(end, to: URL(fileURLWithPath: "/no-such-dir/x.jsonl")))
    }

    /// A shell with an agent on its chain runs that agent's work: `job begin`
    /// and `run` write nothing for it. Stand-in processes, as in
    /// `ProcWalkTests`.
    func testNoBeginIsWrittenForAShellUnderAnAgent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mysidepulse-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.jsonl")
        func chain(_ parents: [(String, String)]) -> [ProcWalk.ProcInfo] {
            [ProcWalk.ProcInfo(pid: 999_900, ppid: 999_901, name: "zsh", path: "/bin/zsh")]
                + parents.enumerated().map { i, p in
                    ProcWalk.ProcInfo(pid: 999_901 + Int32(i), ppid: 999_902 + Int32(i), name: p.0, path: p.1)
                }
        }
        let begin = JobLine.begin(id: "zsh-999900", pid: 999_900, slotPid: 999_900, label: "sleep",
                                  showAfterSeconds: 5, hostBundleId: nil, loggedAt: Date(timeIntervalSince1970: 1_787_652_000))
        for parents in [[("opencode", "/Users/u/.opencode/bin/opencode"), ("launchd", "/sbin/launchd")],
                        [("codex", "/Users/u/.codex/packages/app-server-daemon/releases/0.157.1/bin/codex")],
                        [("2.1.90", "/Users/u/.local/share/claude/versions/2.1.90"), ("zsh", "/bin/zsh")],
                        [("copilot", "/Users/u/.local/bin/copilot")]] {
            XCTAssertFalse(JobJournal.begin(begin, chain: chain(parents), to: url), "\(parents)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing written")
        let terminal = chain([("login", "/usr/bin/login"),
                              ("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")])
        XCTAssertTrue(JobJournal.begin(begin, chain: terminal, to: url))
        XCTAssertEqual(JournalTailer.readAll(url: url), [begin])
    }

    func testAppendToUnwritablePathReturnsFalse() {
        XCTAssertFalse(JournalWriter.append(Data("x".utf8),
                                            to: URL(fileURLWithPath: "/no-such-dir/x.jsonl")))
    }
}
