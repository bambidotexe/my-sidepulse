import Foundation
import MySidepulseCore

/// Asks the frontmost terminal which TAB is visible, by tty — the one fact
/// that scopes acknowledgement to the session actually being looked at,
/// since every tab of a terminal shares one bundle id and one pid.
///
/// Scriptable terminals only (Terminal.app, iTerm2), via a short osascript
/// subprocess with a hard timeout, exactly the keepalive's discipline: a
/// wedged or slow answer must never hold the app. The first probe triggers
/// macOS's one-time Automation consent ("MySidepulse wants to control
/// Terminal"); a denial is remembered for the process and every later ack
/// falls open to the app-level behaviour. All failure modes — unsupported
/// terminal, timeout, denial, unparseable output — answer nil, and nil
/// always means "ack at the bundle level", never "ack nothing".
public final class TerminalTabProber {
    private let queue = DispatchQueue(label: "mysidepulse.ttyprobe", qos: .userInitiated)
    private var cache: (bundleId: String, tty: String?, at: Date)?
    private var deniedBundles: Set<String> = []
    private var warnedDenied = false
    public var onDenied: (() -> Void)?

    public init() {}

    /// The per-terminal question. Anything not listed is not scriptable in
    /// a way we know, and answers nil (app-level ack).
    static func script(forBundleId bundleId: String) -> String? {
        switch bundleId {
        case "com.apple.Terminal":
            return "tell application \"Terminal\" to get tty of selected tab of front window"
        case "com.googlecode.iterm2":
            return "tell application \"iTerm2\" to get tty of current session of current tab of current window"
        default:
            return nil
        }
    }

    /// "/dev/ttys003\n" → "ttys003". Nil for anything that does not look
    /// like a tty path — a script error message must never match a session.
    static func parseTTY(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("/dev/") ? String(trimmed.dropFirst(5)) : trimmed
        guard name.hasPrefix("tty"), name.count <= 32,
              name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return name
    }

    /// Completion always on main. Immediate for unsupported/denied/cached;
    /// one subprocess otherwise.
    public func frontTTY(forBundleId bundleId: String,
                         completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard let script = Self.script(forBundleId: bundleId),
                  !deniedBundles.contains(bundleId) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if let cache, cache.bundleId == bundleId,
               Date().timeIntervalSince(cache.at) < K.ttyProbeCacheSeconds {
                let tty = cache.tty
                DispatchQueue.main.async { completion(tty) }
                return
            }
            let tty = runProbe(bundleId: bundleId, script: script)
            cache = (bundleId, tty, Date())
            DispatchQueue.main.async { completion(tty) }
        }
    }

    /// On the probe queue. Blocking, bounded by the timeout.
    private func runProbe(bundleId: String, script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + K.ttyProbeTimeoutSeconds) == .timedOut {
            process.terminate()
            return nil
        }
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        if stderr.contains("-1743") || stderr.contains("-1744") {
            // Automation consent denied (or blocked by policy): remembered,
            // and every later ack falls open to the app level.
            deniedBundles.insert(bundleId)
            if !warnedDenied {
                warnedDenied = true
                DispatchQueue.main.async { self.onDenied?() }
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        return Self.parseTTY(stdout)
    }
}
