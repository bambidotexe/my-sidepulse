import Foundation
import MySidepulseCore
import MySidepulsePlatform

enum CLIMain {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "hook":
            // 64 KB chunks, retaining at most the 8 MB cap while still
            // draining stdin to EOF — stopping early could block or break the
            // Claude Code process writing to us, and the hook must never do
            // either. The cap bounds this process, not the writer.
            var input = Data()
            let stdinHandle = FileHandle.standardInput
            while let chunk = try? stdinHandle.read(upToCount: 65536), !chunk.isEmpty {
                if input.count < K.hookStdinMaxBytes {
                    input.append(chunk.prefix(K.hookStdinMaxBytes - input.count))
                }
            }
            let origin = ProcWalk.classify(ProcWalk.chain(from: getppid()))
            return HookCommand.run(input: input, environment: ProcessInfo.processInfo.environment,
                                   journalURL: Paths.journal, now: Date(), origin: origin)
        case "led":
            // "toggle" is passed through verbatim for the app to resolve
            // against the mode it currently holds; everything else is
            // validated here so a typo never reaches the device.
            let requested: String?
            switch args.dropFirst().first?.lowercased() {
            case "toggle": requested = "toggle"
            case let raw?: requested = LedMode.parse(raw)?.configValue
            case nil: requested = nil
            }
            guard let wanted = requested else {
                print("usage: mysidepulse led auto|off|toggle|#RRGGBB|<effect>")
                print("effects: \(LedEffects.names.joined(separator: ", "))")
                return 2
            }
            guard let response = ControlClient.send(ControlRequest(cmd: "led", mode: wanted),
                                                    socketPath: Paths.controlSocket.path),
                  response.ok else {
                print("MySidepulse.app is not running (no reply at \(Paths.controlSocket.path)).")
                return 1
            }
            print("LEDs: \(response.mode ?? wanted)")
            return 0
        case "autostart":
            let wanted = args.dropFirst().first?.lowercased()
            guard wanted == nil || wanted == "on" || wanted == "off" else {
                print("usage: mysidepulse autostart [on|off]")
                return 2
            }
            guard let response = ControlClient.send(
                    ControlRequest(cmd: "autostart", mode: wanted),
                    socketPath: Paths.controlSocket.path), response.ok else {
                print("MySidepulse.app is not running (no reply at \(Paths.controlSocket.path)).")
                return 1
            }
            print("autostart: \(response.loginItem ?? "unknown")")
            return 0
        case "status":
            guard let response = ControlClient.send(ControlRequest(cmd: "status"),
                                                    socketPath: Paths.controlSocket.path) else {
                print("MySidepulse.app is not running (no reply at \(Paths.controlSocket.path)).")
                return 1
            }
            if args.contains("--json"),
               let data = try? JSONEncoder().encode(response) {
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            print("mode: \(response.mode ?? "?")   display: \(response.display ?? "?")")
            if let battery = response.battery {
                print("battery: \(battery.percent)% \(battery.plugged ? "plugged" : "on battery")")
            }
            for device in response.devices ?? [] {
                print("device: \(device.name) (\(device.leds) LEDs)\(device.stalled ? " STALLED" : "") at \(device.path)")
            }
            if (response.devices ?? []).isEmpty { print("device: none mounted") }
            for session in response.sessions ?? [] {
                let reason = session.reason.map { " (\($0))" } ?? ""
                print("session \(session.id.prefix(8)): \(session.state)\(reason), \(session.ageSeconds)s ago, \(session.cwd ?? "?")")
            }
            for job in response.jobs ?? [] {
                let seen = job.acknowledged ? ", seen" : ""
                print("job \(job.label ?? job.id): \(job.state)\(seen), \(job.ageSeconds)s ago")
            }
            if let notify = response.notify {
                // A status reply cannot carry the raw topic at all; see
                // NotifyStatus. `mysidepulse notify` is where you read it.
                print("notifications: \(notify.enabled ? "on (\(notify.topicMasked))" : "off")")
            }
            return 0
        case "run":
            return RunCommand.run(Array(args.dropFirst()))
        case "job":
            return JobCommand.run(Array(args.dropFirst()))
        case "notify":
            return NotifyCommand.run(Array(args.dropFirst()))
        case "shell-init":
            guard args.dropFirst().first == "zsh" else {
                print("usage: mysidepulse shell-init zsh")
                return 2
            }
            // proc_pidpath resolves through the /usr/local/bin symlink to the
            // real binary inside the bundle, which is the stable target.
            print(ShellInit.zsh(mysidepulsePath:
                ProcWalk.info(for: getpid())?.path ?? CommandLine.arguments[0]))
            return 0
        case "doctor":
            let report = Doctor.run(Doctor.liveProbes())
            report.lines.forEach { print($0) }
            return Int32(report.failures)
        case "install-hooks":
            return report(HookInstaller.installClaudeHooks())
        case "uninstall-hooks":
            return report(HookInstaller.removeClaudeHooks())
        default:
            print("""
            usage: mysidepulse <command>
              hook              (internal) Claude Code hook entry — reads stdin
              led auto|off|toggle|#RRGGBB|<effect>
                                set LED mode; toggle flips off <-> auto (skhd-friendly)
                                effects: \(LedEffects.names.joined(separator: ", "))
              status [--json]   sessions, display, device, battery
              doctor            health checks; exit code = failure count
              install-hooks     subscribe Claude Code events in ~/.claude/settings.json
              uninstall-hooks   remove MySidepulse hook entries
              run [--show-after N] [--label L] -- <cmd...>
                                run a command with the strip following it;
                                exits with the command's own status
              job begin|end     the same primitives, for shell hooks
              notify [on|off|topic new|topic T|server URL|test]
                                phone notifications; bare notify shows settings
              autostart [on|off]
                                start at login and restart on crash;
                                bare autostart shows the current state
              shell-init zsh    print the preexec/precmd snippet for eval
            """)
            return args.isEmpty ? 0 : 2
        }
    }

    private static func report(_ outcome: HookInstaller.Outcome) -> Int32 {
        outcome.lines.forEach { print($0) }
        return outcome.ok ? 0 : 1
    }
}
