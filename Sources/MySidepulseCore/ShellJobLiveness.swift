import Foundation

/// Whether a terminal job's shell still runs a command, asked of the shell
/// itself: a `job end` can be lost (a snippet re-read mid-command, a socket
/// that timed out, a CLI missing at that instant), and only the shell knows.
/// A shell at its prompt owns its terminal's foreground process group; one
/// running a foreground command has handed that group to the command.
public enum ShellJobLiveness {
    public struct Probe: Equatable {
        /// The job's pid still names the process that began the job.
        public var alive: Bool
        /// That process is still a shell, not replaced by `exec` with a program.
        public var isShell: Bool
        /// It owns its terminal's foreground process group.
        public var atPrompt: Bool
        /// It has a child started since the job began.
        public var hasChildren: Bool
        public init(alive: Bool, isShell: Bool, atPrompt: Bool, hasChildren: Bool) {
            self.alive = alive; self.isShell = isShell; self.atPrompt = atPrompt; self.hasChildren = hasChildren
        }
    }

    /// What the platform read of a job's pid: whether its name is a shell's,
    /// its process group, its terminal's foreground group (0 without a
    /// terminal), and when it was forked (an `exec` keeps it).
    public struct Reading: Equatable {
        public var isShell: Bool
        public var pgid: Int32
        public var tpgid: Int32
        public var startedAt: Date?
        public init(isShell: Bool, pgid: Int32, tpgid: Int32, startedAt: Date?) {
            self.isShell = isShell; self.pgid = pgid; self.tpgid = tpgid; self.startedAt = startedAt
        }
    }

    public enum Verdict: Equatable {
        case keep
        case drop(reason: String)
    }

    /// Gone → drop. Replaced by its program → keep: that program's exit ends
    /// the job. At its prompt with no child started since the job began, seen
    /// so `K.jobPromptSettleSeconds` apart → drop: the end was lost. Anything
    /// else is a command running → keep, the settle forgotten.
    /// `promptSeenAt` is the job's own first sighting at the prompt.
    public static func judge(_ probe: Probe, promptSeenAt: inout Date?, now: Date) -> Verdict {
        guard probe.alive else { return .drop(reason: "shell gone") }
        guard probe.isShell, probe.atPrompt, !probe.hasChildren else {
            promptSeenAt = nil
            return .keep
        }
        guard let seen = promptSeenAt else {
            promptSeenAt = now
            return .keep
        }
        return now.timeIntervalSince(seen) >= K.jobPromptSettleSeconds ? .drop(reason: "shell at its prompt") : .keep
    }

    /// The probe of a job begun at `jobSince` whose pid reads as `reading`
    /// (nil: no such process), with the fork time of each of its children.
    /// A process forked after the job began holds a recycled pid, not the
    /// shell that began it. Only a child forked after the job began counts:
    /// one older than the job (a prompt's helper such as Powerlevel10k's
    /// `gitstatusd`, an earlier `&` job) says nothing about it.
    public static func probe(_ reading: Reading?, children: [Date], jobSince: Date) -> Probe {
        guard let reading, reading.startedAt.map({ $0 <= jobSince }) ?? true else {
            return Probe(alive: false, isShell: false, atPrompt: false, hasChildren: false)
        }
        return Probe(alive: true, isShell: reading.isShell,
                     atPrompt: reading.pgid > 0 && reading.tpgid == reading.pgid,
                     hasChildren: children.contains { $0 > jobSince })
    }
}
