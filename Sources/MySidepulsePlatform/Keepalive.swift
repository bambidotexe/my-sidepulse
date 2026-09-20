import Darwin
import Foundation
import MySidepulseCore

/// macOS powers the SD-card reader off after ~3 min idle, taking the LEDs
/// with it. Touch each device once a minute. A subprocess on purpose: a
/// stalled USB volume blocks a filesystem call indefinitely, and
/// /usr/bin/touch under a kill-timer cannot hang the app.
public final class Keepalive {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mysidepulse.keepalive")
    private let spawn: (String, @escaping () -> Void) -> Void

    /// Touches spawned per device that have not reported back, keyed by mount
    /// *identity* rather than path. A touch parked in uninterruptible I/O
    /// never reports back, and keyed by path its entry would still be sitting
    /// there after the card was pulled and pushed back in — keepalive would
    /// then skip the healthy new mount forever, the reader would power the
    /// card off ~3 min later, and the strip would go dark for good. A replug
    /// mints a new key, so it always starts from clean accounting.
    private var outstanding: [DeviceKey: Int] = [:]

    /// The spawn is injectable because the case this accounting exists for —
    /// a touch that never returns — cannot be produced from outside: BSD
    /// `touch` uses utimensat() on a file that already exists, so not even a
    /// FIFO blocks it. Production always gets the default.
    public init(spawn: @escaping (String, @escaping () -> Void) -> Void = { mount, done in
        Keepalive.touch(mountPath: mount, completion: done)
    }) {
        self.spawn = spawn
    }

    public func start(devices: @escaping () -> [LedDevice]) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: K.keepaliveSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick(devices())
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One round: forget devices that are gone, then touch what is left.
    func tick(_ devices: [LedDevice]) {
        // A device that has left cannot take its entry with it, so a wedged
        // touch's entry would otherwise outlive the mount it was spawned for
        // and grow without bound across replugs.
        let present = Set(devices.map(\.key))
        outstanding = outstanding.filter { present.contains($0.key) }
        for device in devices { touchIfIdle(device) }
    }

    /// Test-visible: unreturned touches per device.
    var outstandingTouches: [DeviceKey: Int] { queue.sync { outstanding } }

    /// Test-visible: one round, run to completion on the keepalive queue.
    func tickNow(_ devices: [LedDevice]) { queue.sync { tick(devices) } }

    /// Hold off a mount whose touches are all still out. Uninterruptible I/O
    /// cannot be killed by any signal, so declining to spawn without bound is
    /// the only way to stay bounded — but the bound is a few, not one, and it
    /// lifts the moment any of them returns, so a single slow touch no longer
    /// costs the mount its next keepalive.
    private func touchIfIdle(_ device: LedDevice) {
        let inFlight = outstanding[device.key] ?? 0
        guard inFlight < K.keepaliveMaxOutstandingTouches else { return }
        outstanding[device.key] = inFlight + 1
        spawn(device.mountPath) { [weak self] in
            self?.queue.async {
                guard let self, let left = self.outstanding[device.key] else { return }
                if left <= 1 { self.outstanding.removeValue(forKey: device.key) }
                else { self.outstanding[device.key] = left - 1 }
            }
        }
    }

    public static func touch(mountPath: String, completion: (() -> Void)? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [mountPath + "/keepalive"]
        process.terminationHandler = { _ in completion?() }
        guard (try? process.run()) != nil else {
            completion?()
            return
        }
        let grace = K.keepaliveTouchTimeoutSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            // Escalate: SIGTERM is a request a child could catch or ignore,
            // SIGKILL is not. Neither can end uninterruptible I/O — the cap
            // above is what bounds that — but a child that survived the first
            // signal should not also survive the second.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                guard process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
