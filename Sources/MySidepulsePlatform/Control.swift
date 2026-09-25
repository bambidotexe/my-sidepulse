import Foundation

/// One ordinary command borrowing the strip. `exitCode` present means the
/// job has ended.
public struct JobRequest: Codable, Equatable {
    public var id: String
    /// The process to watch for death. `slotPid` is the terminal that owns
    /// the job slot; for a shell hook the two are the same, for the `run`
    /// wrapper they are not.
    public var pid: Int32?
    public var slotPid: Int32?
    public var label: String?
    public var exitCode: Int32?
    public var showAfterSeconds: Double?
    public var hostBundleId: String?
    public init(id: String, pid: Int32? = nil, slotPid: Int32? = nil, label: String? = nil,
                exitCode: Int32? = nil, showAfterSeconds: Double? = nil,
                hostBundleId: String? = nil) {
        self.id = id; self.pid = pid; self.slotPid = slotPid; self.label = label
        self.exitCode = exitCode
        self.showAfterSeconds = showAfterSeconds; self.hostBundleId = hostBundleId
    }
}

/// A field left nil is left unchanged — `notify` with everything nil is a
/// status read.
public struct NotifyRequest: Codable, Equatable {
    public var enabled: Bool?
    public var topic: String?
    public var server: String?
    public var test: Bool?
    public init(enabled: Bool? = nil, topic: String? = nil, server: String? = nil,
                test: Bool? = nil) {
        self.enabled = enabled; self.topic = topic; self.server = server; self.test = test
    }
}

/// Every field beyond `cmd` is optional so a CLI and an app from different
/// installs can still talk to each other.
public struct ControlRequest: Codable, Equatable {
    public var cmd: String
    public var mode: String?
    public var job: JobRequest?
    public var notify: NotifyRequest?
    /// `brightness-cycle`: how many steps the cycle has.
    public var steps: Int?
    public init(cmd: String, mode: String? = nil, job: JobRequest? = nil,
                notify: NotifyRequest? = nil, steps: Int? = nil) {
        self.cmd = cmd; self.mode = mode; self.job = job; self.notify = notify
        self.steps = steps
    }
}

public struct SessionStatus: Codable, Equatable {
    public var id: String
    public var state: String
    public var reason: String?
    public var ageSeconds: Int
    public var cwd: String?
    public init(id: String, state: String, reason: String?, ageSeconds: Int, cwd: String?) {
        self.id = id; self.state = state; self.reason = reason
        self.ageSeconds = ageSeconds; self.cwd = cwd
    }
}

public struct DeviceStatus: Codable, Equatable {
    public var name: String
    public var path: String
    public var leds: Int
    public var stalled: Bool
    public init(name: String, path: String, leds: Int, stalled: Bool) {
        self.name = name; self.path = path; self.leds = leds; self.stalled = stalled
    }
}

public struct JobStatus: Codable, Equatable {
    public var id: String
    public var state: String
    public var label: String?
    public var ageSeconds: Int
    /// The terminal that must be focused to acknowledge this job. Reported
    /// because a wrong value here is otherwise invisible: the job simply never
    /// clears, and nothing says why.
    public var hostBundleId: String?
    /// Seen, so it no longer displays. Together these two answer the only
    /// question anyone asks of this output: why is the strip not showing this?
    public var acknowledged: Bool
    public init(id: String, state: String, label: String?, ageSeconds: Int,
                hostBundleId: String? = nil, acknowledged: Bool = false) {
        self.id = id; self.state = state; self.label = label; self.ageSeconds = ageSeconds
        self.hostBundleId = hostBundleId; self.acknowledged = acknowledged
    }
}

/// Deliberately has NOWHERE to put a raw topic. `mysidepulse status --json`
/// dumps the whole response and that output is what gets pasted into issues
/// and transcripts — which is how the previous topic was burned. The raw
/// topic travels only in `ControlResponse.notifyTopic`, which only the
/// `notify` command populates.
public struct NotifyStatus: Codable, Equatable {
    public var enabled: Bool
    public var server: String
    /// Safe to print anywhere.
    public var topicMasked: String
    /// Whether the configured topic and server can actually be posted to.
    /// Computed by the app, so nothing else needs the raw topic to find out.
    public var topicUsable: Bool
    public init(enabled: Bool, server: String, topicMasked: String, topicUsable: Bool) {
        self.enabled = enabled; self.server = server
        self.topicMasked = topicMasked; self.topicUsable = topicUsable
    }
}

public struct BatteryStatus: Codable, Equatable {
    public var percent: Int
    public var plugged: Bool
    public init(percent: Int, plugged: Bool) { self.percent = percent; self.plugged = plugged }
}

public struct ControlResponse: Codable, Equatable {
    public var ok: Bool
    public var error: String?
    public var mode: String?
    public var display: String?
    public var sessions: [SessionStatus]?
    public var devices: [DeviceStatus]?
    public var battery: BatteryStatus?
    public var loginItem: String?
    public var lastEventAgeSeconds: Int?
    public var jobs: [JobStatus]?
    public var notify: NotifyStatus?
    /// The raw topic, populated ONLY in reply to the `notify` command — the
    /// one you run when you mean to read it. Never on a status reply.
    public var notifyTopic: String?
    /// The strips' brightness in whole percent after `brightness-cycle`; nil
    /// when the cycle turned the strip off.
    public var brightnessPercent: Int?
    public init(ok: Bool, error: String? = nil, mode: String? = nil, display: String? = nil,
                sessions: [SessionStatus]? = nil, devices: [DeviceStatus]? = nil,
                battery: BatteryStatus? = nil, loginItem: String? = nil,
                lastEventAgeSeconds: Int? = nil, jobs: [JobStatus]? = nil,
                notify: NotifyStatus? = nil, notifyTopic: String? = nil,
                brightnessPercent: Int? = nil) {
        self.ok = ok; self.error = error; self.mode = mode; self.display = display
        self.sessions = sessions; self.devices = devices; self.battery = battery
        self.loginItem = loginItem; self.lastEventAgeSeconds = lastEventAgeSeconds
        self.jobs = jobs; self.notify = notify; self.notifyTopic = notifyTopic
        self.brightnessPercent = brightnessPercent
    }
}

public enum ControlServerError: Error, Equatable {
    /// Another instance is already listening on this path.
    case alreadyRunning
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

public enum ControlSocketAddress {
    public static func make(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let bytes = Array(path.utf8.prefix(dst.count - 1))
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        return addr
    }
}
