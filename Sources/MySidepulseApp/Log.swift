import os

/// The app's only logging surface. Deliberately tiny: the events logged here
/// are the ones that are otherwise invisible — a control server that never
/// bound, a device that appeared, vanished or wedged, and process-death
/// detection sitting inert. Nothing per-tick, nothing per-event: a chatty
/// logger is one nobody reads.
enum Log {
    static let app = Logger(subsystem: "io.mysidepulse.app", category: "app")
}
