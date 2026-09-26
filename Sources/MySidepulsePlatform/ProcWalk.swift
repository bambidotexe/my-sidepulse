import Foundation
import MySidepulseCore

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
        /// The process group, and the foreground process group of its
        /// controlling terminal (0 without one). A shell at its prompt owns
        /// its terminal's foreground group; one running a foreground command
        /// has handed it to that command's group.
        public let pgid: Int32
        public let tpgid: Int32
        /// When the process was forked; an `exec` keeps it.
        public let startedAt: Date?
        public init(pid: Int32, ppid: Int32, name: String, path: String?, tty: String? = nil,
                    pgid: Int32 = 0, tpgid: Int32 = 0, startedAt: Date? = nil) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.tty = tty
            self.pgid = pgid; self.tpgid = tpgid; self.startedAt = startedAt
        }

        /// A shell's `p_comm`, a login shell's leading `-` stripped. A shell
        /// replaced by `exec` carries its program's name instead.
        public var isShell: Bool {
            ProcWalk.shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
        }

        /// What a terminal job's liveness rule reads of this process.
        public var shellReading: ShellJobLiveness.Reading {
            ShellJobLiveness.Reading(isShell: isShell, pgid: pgid, tpgid: tpgid, startedAt: startedAt)
        }
    }

    static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh"]

    public struct Origin: Equatable {
        /// The agent's own process: the nearest ancestor that is an agent,
        /// and which one it is.
        public var agentPid: Int32?
        public var agent: AgentKind?
        public var hostAppPid: Int32?
        public var hostBundlePath: String?
        /// The terminal TAB the session is displayed in, or nil when the
        /// chain proves there is no tab to name. See `tabTTY`.
        public var tabTTY: String?
        public init(agentPid: Int32? = nil, agent: AgentKind? = nil, hostAppPid: Int32? = nil,
                    hostBundlePath: String? = nil, tabTTY: String? = nil) {
            self.agentPid = agentPid; self.agent = agent; self.hostAppPid = hostAppPid
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
                        tty: ttyName(forDevice: proc.kp_eproc.e_tdev),
                        pgid: proc.kp_eproc.e_pgid, tpgid: proc.kp_eproc.e_tpgid,
                        startedAt: startedAt(of: proc))
    }

    static func startedAt(of proc: kinfo_proc) -> Date? {
        let start = proc.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// When each child of `pid` was forked, for the children that can still
    /// be read; empty when it has none or cannot be read. A shell's children
    /// include helpers that live beside it from its start (Powerlevel10k's
    /// `gitstatusd`), so the fork time is what tells them from a command's.
    public static func childStartTimes(pid: Int32) -> [Date] {
        var children = [Int32](repeating: 0, count: 256)
        let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return children.prefix(min(Int(count), children.count)).compactMap { child in
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, child]
            var proc = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard child > 0, sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return nil }
            return startedAt(of: proc)
        }
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

    /// A process's argv, from the same KERN_PROCARGS2 buffer: argc, the exec
    /// path, its padding NULs, then argc NUL-terminated strings. Nil when
    /// the process is gone or the buffer cannot be read.
    public static func arguments(for pid: Int32) -> [String]? {
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
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var out: [String] = []
        while out.count < Int(argc), index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            out.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return out
    }

    /// A shared Codex app-server, whose being alive proves nothing about any
    /// one session: Codex's managed daemon, `codex app-server --listen unix://
    /// --managed-daemon`, installed under `~/.codex/packages/app-server-daemon/`,
    /// one per user, started by the first TUI and parented by launchd, alive
    /// across every TUI, which spawns every TUI session's hooks, so the pid
    /// those hooks record is its own; and the ChatGPT app's `codex`, an
    /// app-server too, alive for every thread of the app. Only `codex exec`
    /// runs in a process of the session's own. Told apart by the
    /// `app-server` argument, or by the daemon's install folder when the
    /// arguments cannot be read.
    public static func isCodexDaemon(_ info: ProcInfo) -> Bool {
        if let args = arguments(for: info.pid), args.dropFirst().contains("app-server") { return true }
        return info.path?.contains("/app-server-daemon/") ?? false
    }

    /// Codex's managed daemon alone, the app-server behind
    /// `~/.codex/app-server-control/app-server-control.sock` and the only one
    /// whose threads that socket answers for: the ChatGPT app's `codex
    /// app-server` runs its threads itself. Told apart by `--managed-daemon`,
    /// or by the daemon's install folder when the arguments cannot be read.
    public static func isManagedCodexDaemon(_ info: ProcInfo) -> Bool {
        if let args = arguments(for: info.pid) { return args.dropFirst().contains("--managed-daemon") }
        return info.path?.contains("/app-server-daemon/") ?? false
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

    /// True for a path that belongs to a Codex install: the standalone
    /// release under `~/.codex/packages/…/bin/codex`, the launcher
    /// `~/.local/bin/codex`, and the copy inside the ChatGPT app
    /// (`ChatGPT.app/Contents/Resources/codex`), every one of which ends in
    /// `/codex` or passes through a `codex` component.
    static func isCodexPath(_ path: String) -> Bool {
        if path.hasSuffix("/codex") { return true }
        return path.split(separator: "/").contains("codex")
    }

    /// True for GitHub Copilot CLI's executable, `copilot` wherever it lives:
    /// `~/.local/bin/copilot`, or the copy GitHub Copilot.app runs its
    /// sessions in, `~/Library/Caches/github-copilot-sdk/cli/<version>/copilot`.
    /// By the last component only: Copilot's own package folder,
    /// `~/Library/Caches/copilot/`, holds other programs.
    static func isCopilotPath(_ path: String) -> Bool {
        executableName(path) == "copilot"
    }

    /// OpenCode's server runs one of three executables: `opencode`
    /// (`~/.opencode/bin/`, Homebrew), `opencode-cli` (inside OpenCode.app,
    /// and the copy it stages under Application Support) or `.opencode` (the
    /// npm package's). The desktop app's window process and the `opencode2`
    /// launcher, which execs `opencode`, are not it.
    static let opencodeExecutables: Set<String> = ["opencode", "opencode-cli", ".opencode"]

    static func isOpencodePath(_ path: String) -> Bool {
        opencodeExecutables.contains(executableName(path))
    }

    static func executableName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Which agent a process is, if it is one. The name is tried first, then
    /// the resolved path, then the exec path: a Claude launched by its
    /// versioned installer is named by its version, and a symlinked launcher
    /// resolves elsewhere.
    static func agent(of info: ProcInfo) -> AgentKind? {
        if info.name == "claude" { return .claude }
        if info.name == "codex" { return .codex }
        if info.name == "copilot" { return .copilot }
        if opencodeExecutables.contains(info.name) { return .opencode }
        if let path = info.path, let kind = agent(ofPath: path) { return kind }
        if let argv0 = execPath(for: info.pid) { return agent(ofPath: argv0) }
        return nil
    }

    static func agent(ofPath path: String) -> AgentKind? {
        if isClaudePath(path) { return .claude }
        if isCodexPath(path) { return .codex }
        if isCopilotPath(path) { return .copilot }
        if isOpencodePath(path) { return .opencode }
        return nil
    }

    static func isClaudeProcess(_ info: ProcInfo) -> Bool { agent(of: info) == .claude }

    /// Whether a live pid still looks like that agent's process. Used by
    /// the replay-time prune: a pid recycled by some unrelated process while
    /// the app was down would otherwise keep a dead session alive until the
    /// staleness backstop — kill(0) proves a process, not THE process.
    public static func looksLike(_ kind: AgentKind, pid: Int32) -> Bool {
        guard let info = info(for: pid) else { return false }
        return agent(of: info) == kind
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
    /// acknowledgement to what the user can actually see. The same walk
    /// serves both agents: it starts at the agent's process, whichever it is.
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
    public static func tabTTY(in chain: [ProcInfo], agentPid: Int32?, hostAppPid: Int32?) -> String? {
        guard let agentPid, let hostAppPid,
              let agentIndex = chain.firstIndex(where: { $0.pid == agentPid }),
              let hostIndex = chain.firstIndex(where: { $0.pid == hostAppPid }),
              let tty = chain[agentIndex].tty else { return nil }
        let between = chain[(agentIndex + 1)..<max(agentIndex + 1, hostIndex)]
        guard !between.isEmpty, between.allSatisfy({ $0.tty == tty }) else { return nil }
        return tty
    }

    /// The agent = the nearest ancestor that is one (`agent` names which one
    /// to look for, when the hook was told); host = first ancestor living
    /// inside a .app bundle (outermost bundle wins for nested helpers).
    /// Nearest, because one agent can run the other: a Codex started by
    /// Claude's shell tool fires Codex's hooks, and it is Codex's process that
    /// hosts them. `claimed` is a pid the payload names as the agent's own
    /// (OpenCode's server): taken when it is in the chain and is that agent,
    /// else the nearest one is. An OpenCode server hosts every session of
    /// every client and sits in no tab, so its sessions name none.
    public static func classify(_ chain: [ProcInfo], agent wanted: AgentKind? = nil,
                                claimed: Int32? = nil) -> Origin {
        var origin = Origin()
        if let claimed, let wanted, let info = chain.first(where: { $0.pid == claimed }),
           agent(of: info) == wanted {
            origin.agentPid = claimed
            origin.agent = wanted
        }
        for info in chain {
            if origin.agentPid == nil, let kind = agent(of: info), wanted == nil || wanted == kind {
                origin.agentPid = info.pid
                origin.agent = kind
            }
            if origin.hostAppPid == nil, let path = info.path,
               let bundle = outermostAppBundle(in: path) {
                origin.hostAppPid = info.pid
                origin.hostBundlePath = bundle
            }
        }
        // Derived here rather than at the call site so no caller can record a
        // pty that is not a tab.
        origin.tabTTY = origin.agent == .opencode
            ? nil : tabTTY(in: chain, agentPid: origin.agentPid, hostAppPid: origin.hostAppPid)
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
