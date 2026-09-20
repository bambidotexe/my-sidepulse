import XCTest
import MySidepulseCore
@testable import MySidepulsePlatform

final class LedWriterTests: XCTestCase {
    var mount: URL!
    override func setUp() {
        mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-dev-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mount.appendingPathComponent("LEDS.LED").path,
                                       contents: nil)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: mount) }

    func probe() -> LedDevice { LedDevice.probe(mountPath: mount.path, name: "SidePulsePro")! }

    func waitForWrites(_ writer: LedWriter, count: Int) {
        let exp = expectation(description: "writes flushed")
        exp.assertForOverFulfill = false
        writer.onWriteCompleted = { if writer.writesPerformed >= count { exp.fulfill() } }
        if writer.writesPerformed >= count { exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    func testProbeRequiresLedsFile() {
        XCTAssertNotNil(LedDevice.probe(mountPath: mount.path, name: "SidePulsePro"))
        XCTAssertEqual(probe().ledCount, 8)
        try! FileManager.default.removeItem(at: mount.appendingPathComponent("LEDS.LED"))
        XCTAssertNil(LedDevice.probe(mountPath: mount.path, name: "SidePulsePro"))
        XCTAssertNil(LedDevice.probe(mountPath: "/nonexistent", name: "x"))
    }

    func testWriteThenDedupe() throws {
        let writer = LedWriter()
        let device = probe()
        writer.deviceAppeared(device)
        writer.write(program: "#003311", to: device)
        waitForWrites(writer, count: 1)
        XCTAssertEqual(try String(contentsOf: mount.appendingPathComponent("LEDS.LED"),
                                  encoding: .utf8), "#003311")
        writer.write(program: "#003311", to: device)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(writer.writesPerformed, 1, "unchanged program must not be rewritten")
        writer.write(program: "off", to: device)
        waitForWrites(writer, count: 2)
        XCTAssertEqual(try String(contentsOf: mount.appendingPathComponent("LEDS.LED"),
                                  encoding: .utf8), "off")
    }

    func testReplugSameProgramWritesAgain() {
        let writer = LedWriter()
        let device = probe()
        writer.deviceAppeared(device)
        writer.write(program: "#003311", to: device)
        waitForWrites(writer, count: 1)
        // Replug: same path, new mount identity — the device rebooted and
        // replayed INIT.LED, so the remembered program is a lie.
        writer.deviceGone(device.key)
        try! FileManager.default.removeItem(at: mount)
        try! FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mount.appendingPathComponent("LEDS.LED").path,
                                       contents: nil)
        let replugged = probe()
        writer.deviceAppeared(replugged)
        writer.write(program: "#003311", to: replugged)
        waitForWrites(writer, count: 2)
        XCTAssertEqual(writer.writesPerformed, 2)
    }

    func testAStalledDeviceIsDetectedAndStopsReceivingWrites() throws {
        // A FIFO with no reader blocks open(O_WRONLY) forever — the closest
        // deterministic stand-in for the stalled USB volume this exists for.
        let ledsPath = mount.appendingPathComponent("LEDS.LED").path
        try FileManager.default.removeItem(atPath: ledsPath)
        XCTAssertEqual(mkfifo(ledsPath, 0o644), 0)

        let writer = LedWriter()
        let device = probe()
        writer.deviceAppeared(device)

        let stalled = expectation(description: "device reported stalled")
        writer.onStall = { key in
            XCTAssertEqual(key, device.key)
            stalled.fulfill()
        }
        writer.write(program: "#003311", to: device)
        wait(for: [stalled], timeout: K.writeWatchdogSeconds + 3)

        XCTAssertTrue(writer.stalledKeys.contains(device.key))
        writer.write(program: "off", to: device)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(writer.writesPerformed, 0,
                       "a stalled device receives no further writes")

        writer.deviceAppeared(device)
        XCTAssertFalse(writer.stalledKeys.contains(device.key),
                       "a device reappearing clears the stall")

        // Unblock the parked open() so no thread is left wedged after the
        // test. Opening non-blocking then closing immediately is racy: the
        // writer thread's open(O_WRONLY) only becomes *runnable* the instant
        // a reader connects, and actually reaching its write() call still
        // takes a scheduler hop, while this thread's close() runs with no
        // such delay — so the reader is almost always gone again before the
        // write() executes, which raises SIGPIPE and kills the whole test
        // process (not just this test). Verified reproducible 100% of the
        // time with the naive open+close. Keeping the read end open through
        // a blocking read() — which only returns once the writer's write()
        // actually lands — closes that race.
        let reader = open(ledsPath, O_RDONLY)
        if reader >= 0 {
            var buf = [UInt8](repeating: 0, count: 64)
            _ = read(reader, &buf, buf.count)
            close(reader)
        }
    }

    /// A power transition with the lid closed can make one write take longer
    /// than the watchdog: the strip is marked stalled, and without this
    /// recovery nothing would ever clear it — the volume can stay perfectly
    /// healthy (keepalive still touching it) while the strip holds one frame
    /// for hours. A write that is slow but *completes* proves the volume is
    /// alive, so it must clear the stall and paint whatever piled up
    /// meanwhile.
    func testASlowWriteThatCompletesClearsTheStallAndPaintsWhatPiledUp() throws {
        // Same FIFO stand-in as the stall test, but with a reader that turns up
        // after the watchdog has already given up: open(O_WRONLY) blocks past
        // the deadline and then succeeds, which is exactly the hardware case.
        let ledsPath = mount.appendingPathComponent("LEDS.LED").path
        try FileManager.default.removeItem(atPath: ledsPath)
        XCTAssertEqual(mkfifo(ledsPath, 0o644), 0)

        let writer = LedWriter()
        let device = probe()
        writer.deviceAppeared(device)

        let stalled = expectation(description: "device reported stalled")
        writer.onStall = { _ in stalled.fulfill() }
        let recovered = expectation(description: "device reported recovered")
        writer.onRecover = { key in
            XCTAssertEqual(key, device.key)
            recovered.fulfill()
        }

        writer.write(program: "#003311", to: device)
        wait(for: [stalled], timeout: K.writeWatchdogSeconds + 3)
        XCTAssertTrue(writer.stalledKeys.contains(device.key))

        // Pushed while stalled: must be kept, not dropped on the floor.
        writer.write(program: "off", to: device)

        // Attach the reader; drain until both programs have landed. Holding the
        // read end open until then is what keeps the writer's second open() from
        // blocking and its write() from raising SIGPIPE (see the stall test).
        let reader = open(ledsPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        var seen = ""
        let deadline = Date().addingTimeInterval(10)
        while !seen.contains("off"), Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(reader, &buf, buf.count)
            if n > 0 {
                seen += String(decoding: buf[0..<n], as: UTF8.self)
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        wait(for: [recovered], timeout: 5)
        XCTAssertFalse(writer.stalledKeys.contains(device.key),
                       "a write that completes clears the stall")
        XCTAssertEqual(seen, "#003311off",
                       "the slow write lands, then the program queued while stalled")
        XCTAssertEqual(writer.writesPerformed, 2)
    }

    /// The same latch, reached the other way: the stall must lift when the
    /// parked write *returns*, not when it succeeds. A write that came back
    /// failed still proves the queue is free, and leaving lastProgram alone is
    /// what lets the next sync() retry the very same program.
    func testAFailedWriteAlsoClearsTheStall() throws {
        let ledsPath = mount.appendingPathComponent("LEDS.LED").path
        try FileManager.default.removeItem(atPath: ledsPath)
        XCTAssertEqual(mkfifo(ledsPath, 0o644), 0)

        // A reader that leaves before the write lands makes write() fail with
        // EPIPE. Unhandled that is SIGPIPE, which kills the whole test process
        // (see the stall test), so it is suppressed for the duration.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }

        let writer = LedWriter()
        let device = probe()
        writer.deviceAppeared(device)

        let stalled = expectation(description: "device reported stalled")
        writer.onStall = { _ in stalled.fulfill() }
        let recovered = expectation(description: "device reported recovered")
        writer.onRecover = { _ in recovered.fulfill() }

        // Deliberately larger than any macOS pipe buffer (16 KiB, grown to at
        // most 64 KiB). That size is load-bearing, not arbitrary: it is what
        // makes the failure below deterministic. With a short program the
        // write fits the buffer entirely, so whether it FAILS depends on
        // whether the writer thread reaches write() before the read end is
        // closed a few instructions later — a scheduler race this test lost
        // about one full-suite run in four, reporting `("1") is not equal to
        // ("0")` because the write had quietly succeeded.
        let program = String(repeating: "#003311", count: 40_000)
        writer.write(program: program, to: device)
        wait(for: [stalled], timeout: K.writeWatchdogSeconds + 3)
        XCTAssertTrue(writer.stalledKeys.contains(device.key))

        // Unpark the open(), then drop the read end so the write fails.
        // Oversized, and nothing ever reads: write() fills the buffer and
        // parks with bytes still owed, so closing the read end always returns
        // it short or EPIPE. Both orderings now fail — if the writer has not
        // reached write() yet it finds no reader at all — so there is no
        // window left in which the write could succeed.
        let reader = open(ledsPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(reader, 0)
        close(reader)

        wait(for: [recovered], timeout: 5)
        XCTAssertFalse(writer.stalledKeys.contains(device.key),
                       "a write that returns at all clears the stall")
        XCTAssertEqual(writer.writesPerformed, 0, "but a failed write is not counted")
    }

    func testBlackoutWritesEveryStripAndReportsSuccess() throws {
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: second) }
        let secondLeds = second.appendingPathComponent("LEDS.LED")
        FileManager.default.createFile(atPath: secondLeds.path, contents: nil)
        let firstLeds = mount.appendingPathComponent("LEDS.LED")

        XCTAssertTrue(LedWriter.blackout(paths: [firstLeds.path, secondLeds.path],
                                         program: "off", timeout: K.quitBlackoutSeconds))
        XCTAssertEqual(try String(contentsOf: firstLeds, encoding: .utf8), "off")
        XCTAssertEqual(try String(contentsOf: secondLeds, encoding: .utf8), "off")
    }

    func testBlackoutWithNoStripsSucceeds() {
        XCTAssertTrue(LedWriter.blackout(paths: [], program: "off",
                                         timeout: K.quitBlackoutSeconds))
    }

    /// The whole reason the wait is bounded: a card that has stopped answering
    /// never returns from open(), and quitting may not wait for it. The strips
    /// that are healthy still go dark.
    func testBlackoutGivesUpOnAStalledStripAndDarkensTheRest() throws {
        let stalledPath = mount.appendingPathComponent("LEDS.LED").path
        try FileManager.default.removeItem(atPath: stalledPath)
        XCTAssertEqual(mkfifo(stalledPath, 0o644), 0)

        let healthy = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-dev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: healthy) }
        let healthyLeds = healthy.appendingPathComponent("LEDS.LED")
        FileManager.default.createFile(atPath: healthyLeds.path, contents: nil)

        let started = Date()
        XCTAssertFalse(LedWriter.blackout(paths: [stalledPath, healthyLeds.path],
                                          program: "off", timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "a strip that never answers must not hold up the quit")
        XCTAssertEqual(try String(contentsOf: healthyLeds, encoding: .utf8), "off")

        // Release the abandoned write, so it does not sit on a global-queue
        // thread for the rest of the run. Its open() returns as soon as this
        // reader arrives; the read consumes what it writes, because closing
        // first would raise SIGPIPE and kill the whole test process.
        let reader = open(stalledPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(reader, 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        _ = read(reader, &buffer, buffer.count)
        close(reader)
    }

    func testKeepaliveTouchCreatesFile() {
        Keepalive.touch(mountPath: mount.path)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: mount.appendingPathComponent("keepalive").path),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mount.appendingPathComponent("keepalive").path))
    }
}
