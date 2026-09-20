import XCTest
import MySidepulseCore
@testable import MySidepulsePlatform

/// The keepalive accounting is what stops the card powering itself off. Its
/// failure mode is silent — no error, no log, just a strip that goes dark
/// three minutes later — so the policy is tested directly rather than through
/// a real `touch`, which cannot be made to wedge from outside.
final class KeepaliveTests: XCTestCase {
    /// A spawn whose completions are held until the test releases them, so
    /// "the touch never came back" is reproducible.
    final class Spawner {
        private let lock = NSLock()
        private var held: [() -> Void] = []
        private(set) var spawns: [String] = []

        func spawn(_ mount: String, _ done: @escaping () -> Void) {
            lock.lock(); defer { lock.unlock() }
            spawns.append(mount)
            held.append(done)
        }
        var outstanding: Int { lock.lock(); defer { lock.unlock() }; return held.count }
        /// Let one parked touch report back.
        func releaseOne() {
            lock.lock()
            let done = held.isEmpty ? nil : held.removeFirst()
            lock.unlock()
            done?()
        }
    }

    func device(_ ino: UInt64, path: String = "/Volumes/SidePulse") -> LedDevice {
        LedDevice(key: DeviceKey(dev: 1, ino: ino), mountPath: path, name: "SidePulsePro")
    }

    func testTouchesThatNeverReturnStopAtTheCapAndResumeWhenOneReturns() {
        let spawner = Spawner()
        let keepalive = Keepalive(spawn: spawner.spawn)
        let strip = device(10)

        for _ in 0..<10 { keepalive.tickNow([strip]) }
        XCTAssertEqual(spawner.spawns.count, K.keepaliveMaxOutstandingTouches,
                       "a mount whose touches never return must stop spawning them")
        XCTAssertEqual(keepalive.outstandingTouches[strip.key], K.keepaliveMaxOutstandingTouches)

        // One comes back: the mount is answering again, so the next round must
        // touch it rather than stay held off for ever.
        spawner.releaseOne()
        keepalive.tickNow([strip])
        XCTAssertEqual(spawner.spawns.count, K.keepaliveMaxOutstandingTouches + 1,
                       "the hold-off lifts as soon as one touch reports back")
    }

    func testEveryTouchReturningLeavesNoAccountingBehind() {
        let spawner = Spawner()
        let keepalive = Keepalive(spawn: spawner.spawn)
        let strip = device(10)
        for _ in 0..<5 {
            keepalive.tickNow([strip])
            spawner.releaseOne()
        }
        XCTAssertEqual(spawner.spawns.count, 5, "a healthy mount is touched every round")
        XCTAssertTrue(keepalive.outstandingTouches.isEmpty)
    }

    /// Keying the accounting by mount path rather than device identity would
    /// freeze the strip: touches wedge, the card is pulled and pushed back
    /// in, and the old path-keyed entries would still be there — keepalive
    /// would skip the healthy new mount for ever and the reader would power
    /// it off. A replug is a new mount identity, so it must start clean.
    func testAReplugStartsFromCleanAccounting() {
        let spawner = Spawner()
        let keepalive = Keepalive(spawn: spawner.spawn)
        let before = device(10)

        for _ in 0..<5 { keepalive.tickNow([before]) }
        XCTAssertEqual(spawner.spawns.count, K.keepaliveMaxOutstandingTouches)

        // Pulled: nothing is present this round.
        keepalive.tickNow([])
        XCTAssertTrue(keepalive.outstandingTouches.isEmpty,
                      "a device that left takes its accounting with it")

        // Pushed back in — same path, new identity.
        let after = device(11)
        keepalive.tickNow([after])
        XCTAssertEqual(spawner.spawns.count, K.keepaliveMaxOutstandingTouches + 1,
                       "the replugged card is touched again")
    }

    func testTouchWritesTheFileForReal() {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-keepalive-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        let done = expectation(description: "touch reports back")
        Keepalive.touch(mountPath: mount.path) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mount.appendingPathComponent("keepalive").path))
    }
}
