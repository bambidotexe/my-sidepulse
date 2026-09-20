import Foundation

/// Reads the process ancestor chain via sysctl — microseconds, no
/// subprocesses.
public enum ProcWalk {
    public struct ProcInfo: Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let name: String
        public let path: String?
        /// This process's own controlling terminal, from the same kinfo_proc
        /// the walk already reads — free, and what `tabTTY` compares across
        /// the chain.
        public let tty: String?
        public init(pid: Int32, ppid: Int32, name: String, path: String?, tty: String? = nil) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.tty = tty
        }
    }

    public struct Origin: Equatable {
        public var claudePid: Int32?
        public var hostAppPid: Int32?
        public var hostBundlePath: String?
        /// The terminal TAB the session is displayed in, or nil when the
        /// chain proves there is no tab to name. See `tabTTY`.
        public var tabTTY: String?
        public init(claudePid: Int32? = nil, hostAppPid: Int32? = nil, hostBundlePath: String? = nil,
                    tabTTY: String? = nil) {
            self.claudePid = claudePid; self.hostAppPid = hostAppPid
            self.hostBundlePath = hostBundlePath; self.tabTTY = tabTTY
        }
    }

    public static func info(for pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = proc.kp_eproc.e_ppid
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        return ProcInfo(pid: pid, ppid: ppid, name: name, path: path,
                        tty: ttyName(forDevice: proc.kp_eproc.e_tdev))
    }

    public static func chain(from pid: Int32, maxHops: Int = 15) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var current = pid
        while out.count < maxHops, current > 1, let info = info(for: current) {
            out.append(info)
            current = info.ppid
        }
        return out
    }

    /// The exec path recorded for a process, which for a symlinked launcher is
    /// the symlink itself rather than proc_pidpath's resolved target.
    static func execPath(for pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), then the NUL-terminated exec path.
        let start = MemoryLayout<Int32>.size
        var end = start
        while end < size, buffer[end] != 0 { end += 1 }
        guard end > start else { return nil }
        let bytes = buffer[start..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// One variable from another same-user process's environment, via the
    /// same KERN_PROCARGS2 buffer as `execPath`: argc, exec path, NULs, the
    /// argv strings, then the environment as NUL-separated KEY=VALUE pairs.
    /// Needed because cswap redirects each Claude account's config dir via
    /// CLAUDE_CONFIG_DIR, and the session-registry file lives under it.
    public static func environmentValue(_ name: String, forPid pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer.prefix(MemoryLayout<Int32>.size)) }
        var index = MemoryLayout<Int32>.size
        // Skip the exec path and the padding NULs after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        // Skip argc argv strings.
        var remaining = argc
        while remaining > 0, index < size {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
            remaining -= 1
        }
        // What follows are the environment strings.
        let prefix = Array("\(name)=".utf8)
        while index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            if end > index, buffer[index..<end].starts(with: prefix) {
                return String(decoding: buffer[(index + prefix.count)..<end], as: UTF8.self)
            }
            if end == index { break } // double NUL: past the environment
            index = end + 1
        }
        return nil
    }

    /// True for a path that belongs to a Claude Code install. Both real shapes
    /// must match: the symlink launcher `~/.local/bin/claude`, and the native
    /// installer's versioned target `~/.local/share/claude/versions/<version>`,
    /// whose last component is a version string and whose p_comm is likewise —
    /// matching only "ends with /claude" would miss that second shape and
    /// leave process-death detection blind to it.
    static func isClaudePath(_ path: String) -> Bool {
        if path.hasSuffix("/claude") { return true }
        return path.split(separator: "/").contains("claude")
    }

    static func isClaudeProcess(_ info: ProcInfo) -> Bool {
        if info.name == "claude" { return true }
        if let path = info.path, isClaudePath(path) { return true }
        if let argv0 = execPath(for: info.pid), isClaudePath(argv0) { return true }
        return false
    }

    /// Whether a live pid still looks like a Claude Code process. Used by
    /// the replay-time prune: a pid recycled by some unrelated process while
    /// the app was down would otherwise keep a dead session alive until the
    /// staleness backstop — kill(0) proves a process, not THE process.
    public static func looksLikeClaude(pid: Int32) -> Bool {
        guard let info = info(for: pid) else { return false }
        return isClaudeProcess(info)
    }

    /// NODEV spells itself -1 or UInt32.max depending on how `e_tdev`
    /// imports, and `devname` answers "??" for a device it cannot name — a
    /// process with no controlling terminal must come back nil by all three
    /// routes, or a chain of tty-less daemons would agree on "??" and
    /// `tabTTY` would call it a tab.
    static func ttyName<D: BinaryInteger>(forDevice dev: D) -> String? {
        guard dev != 0, dev != -1, dev != UInt32.max else { return nil }
        guard let name = devname(dev_t(dev), mode_t(S_IFCHR)) else { return nil }
        let string = String(cString: name)
        guard string.hasPrefix("tty") else { return nil }
        return string
    }

    /// The terminal TAB a session is displayed in — the one fact that scopes
    /// acknowledgement to what the user can actually see.
    ///
    /// A tty is NOT proof of a tab. Claude Code 2.1's daemon hosts sessions
    /// on ptys it allocates itself (`claude daemon run` → `bg-pty-host` →
    /// `bg-spare`), which are indistinguishable from a tab by name: such a
    /// pty has no window behind it, so no front tab can ever match it, and
    /// its green stays unacknowledgeable until a tab-side process of the
    /// same session id happens to fire a hook event and overwrite the tty.
    ///
    /// So the tty is trusted only when the chain shows a shell holding it
    /// under the host app: same tty from Claude up to (not including) the
    /// app, and at least one process in between — the login/shell the app
    /// started. A daemon pty fails on the first hop, whose parent has no
    /// controlling terminal at all. Nil means "no tab to name", which the
    /// ack path already treats as the app-level fail-open, so a rejection
    /// can only ever widen acknowledgement, never strand an alert.
    public static func tabTTY(in chain: [ProcInfo], claudePid: Int32?, hostAppPid: Int32?) -> String? {
        guard let claudePid, let hostAppPid,
              let claudeIndex = chain.firstIndex(where: { $0.pid == claudePid }),
              let hostIndex = chain.firstIndex(where: { $0.pid == hostAppPid }),
              let tty = chain[claudeIndex].tty else { return nil }
        let between = chain[(claudeIndex + 1)..<max(claudeIndex + 1, hostIndex)]
        guard !between.isEmpty, between.allSatisfy({ $0.tty == tty }) else { return nil }
        return tty
    }

    /// claude = first ancestor named "claude"; host = first ancestor living
    /// inside a .app bundle (outermost bundle wins for nested helpers).
    public static func classify(_ chain: [ProcInfo]) -> Origin {
        var origin = Origin()
        for info in chain {
            if origin.claudePid == nil, isClaudeProcess(info) {
                origin.claudePid = info.pid
            }
            if origin.hostAppPid == nil, let path = info.path,
               let bundle = outermostAppBundle(in: path) {
                origin.hostAppPid = info.pid
                origin.hostBundlePath = bundle
            }
        }
        // Derived here rather than at the call site so no caller can record a
        // pty that is not a tab.
        origin.tabTTY = tabTTY(in: chain, claudePid: origin.claudePid, hostAppPid: origin.hostAppPid)
        return origin
    }

    static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The bundle id of the terminal that invoked THIS process — what a job
    /// must be tagged with for focusing that terminal to acknowledge it.
    ///
    /// Starts at the parent, never at self. The CLI ships inside
    /// MySidepulse.app, so a walk that includes itself resolves to
    /// `io.mysidepulse.app`, an LSUIElement with no windows that can never be
    /// frontmost — every job so tagged is unacknowledgeable for its full
    /// twenty-minute life. The hook has always started at the parent; this
    /// exists so job callers cannot get it wrong differently.
    public static func callerHostBundleId() -> String? {
        classify(chain(from: getppid())).hostBundlePath
            .flatMap(bundleIdentifier(forBundleAt:))
    }

    public static func bundleIdentifier(forBundleAt bundlePath: String) -> String? {
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }
}
