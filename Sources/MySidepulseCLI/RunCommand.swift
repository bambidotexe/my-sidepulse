import Foundation
import MySidepulseCore
import MySidepulsePlatform

/// A job's begin and end, each one journal line (`JobJournal`): no call to
/// the app, so an app that is down, wedged or older never delays or fails
/// the user's command, and a restart replays the line.
enum JobReport {
    static func begin(id: String, pid: Int32, slotPid: Int32, label: String?, showAfter: Double) {
        JobJournal.append(JobLine.begin(id: id, pid: pid, slotPid: slotPid, label: label,
                                        showAfterSeconds: showAfter,
                                        hostBundleId: ProcWalk.callerHostBundleId(), loggedAt: Date()),
                          to: Paths.journal)
    }

    static func end(id: String, exitCode: Int32) {
        JobJournal.append(JobLine.end(id: id, exitCode: exitCode, loggedAt: Date()), to: Paths.journal)
    }
}

/// `mysidepulse run [--show-after N] [--label L] -- <cmd…>`
///
/// No signal handling on purpose. Ctrl-C reaches the whole foreground process
/// group, so this process dies with its child and the app clears the job when
/// the pid dies — the mechanism already built for Claude sessions. Trapping
/// here would need SIG_IGN, which posix_spawn inherits into the child,
/// breaking Ctrl-C for the command itself.
enum RunCommand {
    static func run(_ args: [String]) -> Int32 {
        var showAfter = K.jobShowAfterDefaultSeconds
        var label: String?
        var command: [String] = []
        var index = 0
        parse: while index < args.count {
            switch args[index] {
            case "--":
                command = Array(args[(index + 1)...])
                break parse
            case "--show-after":
                guard index + 1 < args.count, let value = Double(args[index + 1]),
                      value >= 0 else { return usage() }
                showAfter = value
                index += 2
            case "--label":
                guard index + 1 < args.count else { return usage() }
                label = args[index + 1]
                index += 2
            default:
                command = Array(args[index...])
                break parse
            }
        }
        guard !command.isEmpty else { return usage() }

        let id = UUID().uuidString
        // Watch this process; own the shell's slot. A second `mysidepulse run`
        // from the same shell then replaces this one instead of stacking.
        JobReport.begin(id: id, pid: getpid(), slotPid: getppid(),
                        label: label ?? command.joined(separator: " "), showAfter: showAfter)

        let process = Process()
        // env, so the command is found on PATH exactly as the shell would.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        do {
            try process.run()
        } catch {
            JobReport.end(id: id, exitCode: 127)
            FileHandle.standardError.write(Data(
                "mysidepulse run: cannot run \(command[0]): \(error.localizedDescription)\n".utf8))
            return 127
        }
        process.waitUntilExit()
        // A command killed by a signal reports the signal number; shells render
        // that as 128 + n, and so does this, so the wrapper stays transparent.
        let code = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        JobReport.end(id: id, exitCode: code)
        return code
    }

    static func usage() -> Int32 {
        print("usage: mysidepulse run [--show-after SECONDS] [--label TEXT] -- <command…>")
        return 2
    }
}

/// The primitives the shell hooks drive. `mysidepulse run` is the same thing
/// with the command in between.
enum JobCommand {
    static func run(_ args: [String]) -> Int32 {
        var id: String?
        var pid = getppid()          // the shell that invoked us
        var label: String?
        var showAfter = K.shellShowAfterDefaultSeconds
        var exitCode: Int32 = 0
        var index = 1                // args[0] is begin|end
        while index + 1 < args.count {
            let value = args[index + 1]
            switch args[index] {
            case "--id": id = value
            case "--pid": pid = Int32(value) ?? pid
            case "--label": label = value
            case "--show-after": showAfter = Double(value) ?? showAfter
            case "--exit": exitCode = Int32(value) ?? 0
            default: return usage()
            }
            index += 2
        }
        guard let id, !id.isEmpty else { return usage() }
        switch args.first {
        case "begin":
            // A shell hook passes its own pid: the watched process and the
            // slot are the same shell.
            JobReport.begin(id: id, pid: pid, slotPid: pid, label: label, showAfter: showAfter)
            return 0
        case "end":
            JobReport.end(id: id, exitCode: exitCode)
            return 0
        default:
            return usage()
        }
    }

    static func usage() -> Int32 {
        print("""
        usage: mysidepulse job begin --id ID [--pid PID] [--label TEXT] [--show-after SECONDS]
               mysidepulse job end   --id ID --exit STATUS
        """)
        return 2
    }
}

enum NotifyCommand {
    static func run(_ args: [String]) -> Int32 {
        let request: NotifyRequest?
        switch (args.first, args.dropFirst().first) {
        case (nil, _):               request = nil
        case ("on", _):              request = NotifyRequest(enabled: true)
        case ("off", _):             request = NotifyRequest(enabled: false)
        case ("test", _):            request = NotifyRequest(test: true)
        case ("topic", "new"):       request = NotifyRequest(topic: Notifier.generateTopic())
        case ("topic", let value?):  request = NotifyRequest(topic: value)
        case ("server", let value?): request = NotifyRequest(server: value)
        default:
            print("""
            usage: mysidepulse notify              show settings
                   mysidepulse notify on|off       enable (minting a topic if needed) or disable
                   mysidepulse notify topic new    rotate to a fresh random topic
                   mysidepulse notify topic TOPIC  use a specific topic
                   mysidepulse notify server URL   use a self-hosted ntfy
                   mysidepulse notify test         send one push now
            """)
            return 2
        }
        guard let response = ControlClient.send(ControlRequest(cmd: "notify", notify: request),
                                                socketPath: Paths.controlSocket.path) else {
            print("MySidepulse.app is not running (no reply at \(Paths.controlSocket.path)).")
            return 1
        }
        guard response.ok, let notify = response.notify else {
            print(response.error ?? "notify failed")
            return 1
        }
        print("notifications: \(notify.enabled ? "on" : "off")")
        if let topic = response.notifyTopic, !topic.isEmpty {
            print("topic: \(topic)")
            print("server: \(notify.server)")
            print("subscribe on your phone: \(notify.server)/\(topic)")
            if notify.enabled {
                print("(the topic is unauthenticated — treat it as a password)")
            }
        }
        return 0
    }
}
