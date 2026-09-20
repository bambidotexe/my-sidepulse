import Foundation
import IOKit.ps
import MySidepulseCore

/// Push-driven battery reads: IOKit notifies on every power-source change.
final class PowerMonitor {
    var onChange: ((PowerState?) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    /// Same safety net as the device rescan, for the same reason: if the IOKit
    /// source cannot be created, or one notification goes missing, the battery
    /// reading would otherwise stay frozen at whatever it was for the whole
    /// run — and in battery-glance mode that is what the strip is showing.
    private var refresh: DispatchSourceTimer?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.onChange?(PowerMonitor.read()) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        onChange?(Self.read())
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + K.powerRefreshSeconds,
                       repeating: K.powerRefreshSeconds, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.onChange?(Self.read()) }
        timer.resume()
        refresh = timer
    }

    static func read() -> PowerState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            // Never fabricate a charge level: an absent capacity key read as
            // 0 % is a critical battery to BatteryRules, which would breathe
            // the whole strip red on a reporting glitch. No reading at all is
            // the honest answer, and Arbiter already handles a nil power state.
            guard let current = description[kIOPSCurrentCapacityKey] as? Int else { return nil }
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) * 100 / Double(maximum)).rounded()) : current
            return PowerState(
                percent: percent,
                plugged: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                charged: description[kIOPSIsChargedKey] as? Bool ?? false,
                present: true)
        }
        return nil
    }
}
