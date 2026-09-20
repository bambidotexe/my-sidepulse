import Foundation
import DiskArbitration
import MySidepulseCore
import MySidepulsePlatform

/// DiskArbitration push notifications for volume mount/unmount, plus one
/// initial /Volumes scan. Replug repaints because the key changes.
final class DeviceMonitor {
    var onAppear: ((LedDevice) -> Void)?
    var onDisappear: ((DeviceKey) -> Void)?
    private var session: DASession?
    private var knownByPath: [String: DeviceKey] = [:]
    /// One remount retry timer per vetoed disk, keyed by BSD name.
    private var mountRetries: [String: DispatchSourceTimer] = [:]

    /// stat() on a wedged mount blocks uninterruptibly. Every other part of
    /// this design keeps such calls off the main queue — LedWriter has its own
    /// io queue behind a watchdog, Keepalive shells out to /usr/bin/touch —
    /// and probing must too, or a dying device freezes the menu, the LEDs and
    /// the control socket at once.
    private let probeQueue = DispatchQueue(label: "mysidepulse.deviceprobe", qos: .utility)

    /// Retries DASessionCreate. Only ever armed while there is no session.
    private var sessionRetry: DispatchSourceTimer?
    /// Slow safety net. Everything above is push-driven, and a push that never
    /// arrives leaves the strip dark with nothing to notice it. A rescan is
    /// idempotent — deliver() only reports a device whose identity changed —
    /// so this can only ever find something that was missed.
    private var rescan: DispatchSourceTimer?

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            // A failed session must not cost the initial scan too — a strip
            // already plugged in would stay dark for the whole run even
            // though nothing is wrong with it. Scan anyway, and keep trying
            // for a session so hotplug comes back on its own.
            Log.app.error("DASessionCreate failed — scanning /Volumes and retrying")
            scanVolumes()
            scheduleSessionRetry()
            return
        }
        stopSessionRetry()
        self.session = session
        DASessionSetDispatchQueue(session, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().diskChanged(disk)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().diskChanged(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().diskGone(disk)
        }, context)
        // The eject guard rides on this same session — see EjectGuard for why
        // it exists. Registered last so a failure here cannot cost us device
        // discovery, which is the app's actual job.
        DARegisterDiskEjectApprovalCallback(session, nil, { disk, context in
            guard let context else { return nil }
            return Unmanaged<DeviceMonitor>.fromOpaque(context)
                .takeUnretainedValue().approveEject(disk)
        }, context)
        scanVolumes()
        startRescan()
    }

    private func startRescan() {
        guard rescan == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + K.deviceRescanSeconds,
                       repeating: K.deviceRescanSeconds, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.scanVolumes() }
        timer.resume()
        rescan = timer
    }

    private func scheduleSessionRetry() {
        guard sessionRetry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + K.deviceSessionRetrySeconds,
                       repeating: K.deviceSessionRetrySeconds)
        // start() cancels this timer itself once a session is created, and
        // re-arms it if one still cannot be. Rescanning each time also picks
        // up a device plugged in while hotplug was unavailable.
        timer.setEventHandler { [weak self] in self?.start() }
        timer.resume()
        sessionRetry = timer
    }

    private func stopSessionRetry() {
        guard let timer = sessionRetry else { return }
        Log.app.notice("DiskArbitration session recovered — hotplug detection is back on")
        timer.cancel()
        sessionRetry = nil
    }

    // MARK: eject guard

    /// nil means "not mine, allow". A dissenter vetoes the eject; DA takes
    /// ownership of it, hence passRetained.
    private func approveEject(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        let description = DADiskCopyDescription(disk) as? [String: Any]
        guard EjectGuard.isBuiltInCardReader(
            deviceProtocol: description?[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            deviceModel: description?[kDADiskDescriptionDeviceModelKey as String] as? String)
        else { return nil }

        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
        let volume = description?[kDADiskDescriptionVolumeNameKey as String] as? String ?? "unmounted"
        Log.app.notice(
            "vetoing eject of \(bsd, privacy: .public) (\(volume, privacy: .public)) — built-in SD reader")
        startMountRetries(bsd: bsd)
        return Unmanaged.passRetained(DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
            "MySidepulse is keeping the SD card attached" as CFString))
    }

    /// The veto stops the eject; this puts the volume back. While the screen
    /// is locked each attempt is dissented in turn, and the first one after
    /// unlock succeeds — which is the whole mechanism.
    ///
    /// Keyed by BSD name rather than by holding the DADisk from the approval
    /// callback: that object's description never reflects a later mount, so
    /// checking it would keep the loop spinning against an already-mounted
    /// volume. Asking the session for a fresh disk each tick is what makes
    /// the stop condition observable.
    private func startMountRetries(bsd: String) {
        guard mountRetries[bsd] == nil else {
            Log.app.info("eject guard: retries already running for \(bsd, privacy: .public)")
            return
        }
        Log.app.info("eject guard: starting remount retries for \(bsd, privacy: .public)")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + K.ejectRemountRetrySeconds,
                       repeating: K.ejectRemountRetrySeconds)
        timer.setEventHandler { [weak self] in
            guard let self, let session = self.session else { return }
            // No disk, or no description, means it is genuinely gone —
            // physically removed rather than software-ejected. That is what
            // bounds these retries; a locked machine can stay locked for hours.
            guard let disk = bsd.withCString({
                      DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
                  let description = DADiskCopyDescription(disk) as? [String: Any]
            else {
                self.stopMountRetries(bsd, "disk gone")
                return
            }
            if description[kDADiskDescriptionVolumePathKey as String] != nil {
                self.stopMountRetries(bsd, "remounted")
                return
            }
            Log.app.info("eject guard: retrying mount of \(bsd, privacy: .public)")
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
        }
        timer.resume()
        mountRetries[bsd] = timer
    }

    private func stopMountRetries(_ bsd: String, _ why: String) {
        guard let timer = mountRetries.removeValue(forKey: bsd) else { return }
        timer.cancel()
        Log.app.info("eject guard: stopping retries for \(bsd, privacy: .public) — \(why, privacy: .public)")
    }

    private func diskChanged(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
              let url = description[kDADiskDescriptionVolumePathKey as String] as? URL
        else {
            // A description change with no volume path is what a bare unmount
            // (no detach, so no disappear callback) looks like from here. We
            // cannot tell WHICH path this disk used to hold, so re-check every
            // known mount instead of carrying a phantom device that fails
            // every write until the next unrelated DA event.
            reconcile()
            return
        }
        let name = description[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? url.lastPathComponent
        probe(mountPath: url.path, name: name)
    }

    private func diskGone(_ disk: DADisk) {
        if let description = DADiskCopyDescription(disk) as? [String: Any],
           let url = description[kDADiskDescriptionVolumePathKey as String] as? URL,
           let key = knownByPath.removeValue(forKey: url.path) {
            onDisappear?(key)
            return
        }
        reconcile()
    }

    /// The description can already be gone when the callback fires, so fall
    /// back to asking which known mounts still answer — off the main queue,
    /// because this runs exactly when a flaky device is going away.
    private func reconcile() {
        let snapshot = knownByPath
        probeQueue.async { [weak self] in
            let vanished = snapshot.filter { path, key in
                // Identity, not mere existence: a same-named volume remounting
                // at this path during the probe window would answer the stat
                // and mask the departure of the device we actually recorded.
                LedDevice.probe(mountPath: path,
                                name: URL(fileURLWithPath: path).lastPathComponent)?.key != key
            }
            guard !vanished.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // The snapshot is stale by the time it returns: only drop an
                // entry that has not changed underneath it.
                for (path, key) in vanished where self.knownByPath[path] == key {
                    self.knownByPath.removeValue(forKey: path)
                    self.onDisappear?(key)
                }
            }
        }
    }

    func scanVolumes() {
        probeQueue.async { [weak self] in
            let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
            for name in volumes {
                let path = "/Volumes/\(name)"
                guard let device = LedDevice.probe(mountPath: path, name: name) else { continue }
                DispatchQueue.main.async { self?.deliver(device, at: path) }
            }
        }
    }

    private func probe(mountPath: String, name: String) {
        probeQueue.async { [weak self] in
            guard let device = LedDevice.probe(mountPath: mountPath, name: name) else { return }
            DispatchQueue.main.async { self?.deliver(device, at: mountPath) }
        }
    }

    /// Main queue only: knownByPath is engine-adjacent state.
    private func deliver(_ device: LedDevice, at mountPath: String) {
        if let previous = knownByPath[mountPath], previous != device.key {
            // This path now hosts a different device, so the one we had
            // recorded is gone — whether or not its disappear callback ever
            // arrived. Retiring it here is what stops a phantom device
            // lingering in the engine and in `mysidepulse status`.
            onDisappear?(previous)
        }
        guard knownByPath[mountPath] != device.key else { return }
        knownByPath[mountPath] = device.key
        onAppear?(device)
    }
}
