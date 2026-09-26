# Architecture

How MySidepulse is built. For what it does, see [functional.md](functional.md);
for the strip's protocol, [device.md](device.md); for the operating-system
boundary, [macOS.md](macOS.md).

## Targets

SwiftPM only (`Package.swift`, swift-tools 5.10, macOS 26, spelled
`.macOS("26.0")` because tools 5.10 has no symbol for it). No Xcode project, no
third-party dependency, no firmware in this repository.

| Target | Kind | Imports | Role |
|---|---|---|---|
| `MySidepulseCore` | library | Foundation only | Every rule: the four agents (`AgentKind`, `Agents`), session state machine, job store, arbiter, LED program text, constants, every user-facing string in both languages, the hook setup of every agent (the entries in Claude Code's and Codex's files, Copilot's whole hook file, OpenCode's plugin source) and the trim of each agent's payload, the zsh snippet, the update's rules (what a reply means, when an unasked check is due, the Updates group, the update window's phases, what an unpacked copy must say about itself, the install helper's text). Pure values and functions; no clock, no I/O, and it never asks the system what the language is. |
| `MySidepulsePlatform` | library | Foundation, Darwin, MachO | Headless, testable I/O: journal append and tail, process inspection, LED file writer, keepalive, ntfy client, control socket, doctor, the hook installer, and the update's I/O: the GitHub check, the download held against GitHub's digest, the stager (disk image, copy, signature), the installer and the detached helper process. |
| `MySidepulseApp` | executable | AppKit, SwiftUI, IOKit, DiskArbitration, ServiceManagement, UserNotifications | The menu-bar app: `Engine`, device/power/attention monitors, launch agent, the settings window and the onboarding wizard. |
| `MySidepulseCLI` | executable `mysidepulse` | Foundation | The CLI, including the hook entry point Claude Code, Codex and GitHub Copilot run, and OpenCode's plugin runs. |
| `MySidepulseCoreTests`, `MySidepulsePlatformTests` | tests | XCTest | |

Dependencies point one way: Core ← Platform ← App and CLI. `PurityTests` fails
the build if any file in `Sources/MySidepulseCore` imports anything but
Foundation.

Both executables ship in one bundle, `MySidepulse.app/Contents/MacOS/`:
`MySidepulseApp` (the GUI) and `mysidepulse` (the CLI).

## The three layers

```
Claude Code ─hook─▶ mysidepulse hook ──────────┐
Codex ─hook─▶ mysidepulse hook --agent codex ──┴─append─▶ journal.jsonl
                                                     │
                                               JournalTailer ─┐
zsh hooks / mysidepulse run ─── control socket ───────────────┤
PowerMonitor · DeviceMonitor · AttentionMonitor ──────────────┤
                                                              ▼
                                                        Engine.sync()
                                                              │
              SessionStore + JobStore ◀───────────────────────┘
                 │                 │
                 ▼                 ▼
              Arbiter            Alert ─▶ Notifier ─▶ ntfy
                 ▼
            DisplayState ─▶ LedProgram ─▶ LedWriter ─▶ LEDS.LED
```

**Status layer (Core).** `SessionStore` folds journal events into per-session
state, each session carrying its agent, and owns every time-based rule through
`tick(now:userPresent:)`. `JobStore` does the same for terminal jobs.
`Arbiter.decide` reduces mode, power, sessions and jobs to one `DisplayState`,
whose agent states carry the set of agents behind them (`Agents`: Claude,
Codex, or both), which is what the roll's colours and the sentences follow.
None of it reads a clock: `now` is always passed in, which is what lets the
tests and the journal replay drive it.

**Device layer (Platform + App).** `DeviceMonitor` finds strips, `LedProgram`
turns a `DisplayState` into program text, `LedWriter` writes it, `Keepalive`
keeps the reader powered. `LedWriter` is the only code that writes `LEDS.LED` — including the blackout
on the way out, which every quit goes through (`device.md` *Writing*).

**Notification layer.** `SessionStore.tick` returns the `Alert`s that are due;
`Engine.deliver` turns each into one ntfy POST through `Notifier`. `Engine` is
the only caller of `Notifier.send`. Publishing is fire-and-forget; nothing
subscribes.

**Language layer (Core).** Every user-facing string lives in a `Strings*.swift`
table, one per surface, each string a single accessor that switches over
`Language` so the two versions sit side by side and neither can be added alone.
`Loc` is the ambient switch the tables read, guarded by a lock because the
settings window reads it on the main queue while the notifier writes a push from
its own. `Loc.language` is set exactly once, in `MySidepulseApp/main.swift`,
from `Locale.preferredLanguages.first`; Core holds the rule that turns that tag
into a `Language` but never asks the system itself. `MySidepulseCLI` never sets
it, so the CLI keeps the default, English — which is also how `Doctor` and
`HookInstaller`, called by both, print English in a terminal and French in the
window from the same code: the language is read where the sentence is built, not
where the type is created.

## Engine

`Engine` (`Sources/MySidepulseApp/Engine.swift`) owns all mutable state — the
two stores, power, the device set, the mode, the config — strictly on the main
queue. Every input funnels into one method:

```
sync():
  alerts   = store.tick(now, userPresent)      // holds, settle, expiry, due pushes
  jobs.tick(now)
  probeJobs(now)                               // each running job's shell: still running a command? (ShellJobLiveness)
  checkAbandonedTurns(now)                     // registry + transcript rescues; Codex: its daemon, else the rollout; Copilot: its events.jsonl
  deliver(alerts)                              // → notify queue
  decision = Arbiter.decide(...)
  pre-paint acknowledgement if the user is typing in the host app
  apply a Playground preview over the decision (paint only)
  for each device: paint(LedProgram.program(...))   // a tail when the animation carries on, else the write
  attention.setPolling(decision.isAlertable)
  scheduleNextDeadline(now)
```

Inputs that call `sync()`: journal events (`handle`), process exits, power
changes, device arrival, acknowledgement, mode / brightness / preview changes,
job begin / end, wake from sleep, and the deadline timer.

**Carrying an animation on.** `paint` keeps, per strip, what it is playing and
since when, and the loop to hand over to. A brightness change on the same
animation, or a zone opening, closing or changing over the same roll, writes
the tail `LedContinuation` cuts from that record and schedules the loop's
write at the tail's end, a `DispatchWorkItem` on the main queue; a real change
cancels it and writes at once. `LedWriter` stays the only writer.

**One timer.** There is no periodic tick. After every `sync()` the engine arms a
single `DispatchSourceTimer` for the earliest of `SessionStore.nextDeadline`,
`JobStore.nextDeadline`, the glance end, the preview end and the end of the
brightness cycle's white LED. It is scheduled
with `wallDeadline`, so time spent asleep counts.

**Startup** (`Engine.start`, called from `AppDelegate`):

1. Replay `journal.1.jsonl`, then start the tailer on `journal.jsonl`, which
   drains the file synchronously. Events older than the last boot
   (`BootTime.bootDate`) are ignored.
2. On the next main-queue turn — after the drained events have been applied —
   drop sessions whose pid is dead or no longer that agent's process, and
   Claude sessions whose pid's registry record names another session
   (`pruneDead`), scrub push deadlines already past the late-drop window
   (`dropStaleNotifications`), run the stores' `tick`; when a working session
   is hosted by Codex's managed daemon and its socket exists, ask the daemon
   `thread/loaded/list` and decide each such session missing from the
   complete list by its rollout (`daemonListed`), at most 1 s later; then
   `finishLaunch`: `checkAbandonedTurns` with no quiet gate, arm the process
   watchers, rotate the journal if due, and `sync()`. Until `finishLaunch`,
   `sync()` returns at once (`launching`), so nothing replayed is ticked,
   pushed or painted before the launch checks.
3. Only then does `AppDelegate` start `DeviceMonitor`, so the first write to a
   strip already reflects the replayed state.

The ordering in steps 1–3 rests on main-queue FIFO: the tailer's drain delivers
through `DispatchQueue.main.async`, and the blocks that follow are enqueued
after it.

## Who watches what

| Source | Mechanism | Feeds |
|---|---|---|
| Claude Code | 15 hooks → `mysidepulse hook` → one line appended to the journal | `JournalTailer` → `Engine.handle` |
| Codex | 12 hooks → `mysidepulse hook --agent codex` → the same journal, the line saying `codex` | the same |
| GitHub Copilot | 7 hooks in `~/.copilot/hooks/mysidepulse.json` → `mysidepulse hook --agent copilot --event <name>` → the same journal, the line saying `copilot`; no line for a subagent's session | the same |
| OpenCode | the plugin `~/.config/opencode/plugins/mysidepulse.js`, inside OpenCode's server → `mysidepulse hook --agent opencode` per forwarded event → the same journal, mapped onto its names, the line saying `opencode` | the same |
| Journal | kqueue on the file (`DispatchSourceFileSystemObject`: write, extend, rename, delete); follows rotation, retries a failed reopen every 0.5 s | `SessionStore.apply` |
| Agent processes, every agent's (for OpenCode, its server) | kqueue `EVFILT_PROC` exit per tracked pid (`ProcessWatcher`) | `processExited` on both stores |
| Claude's own registry | `<config>/sessions/<pid>.json`, `<config>` taken from the session's transcript path (`ClaudeProcessRegistry.configDir(fromTranscriptPath:)`), read only for quiet `working` turns and open waits of Claude sessions, and once per Claude session by the launch prune (`ClaudeProcessRegistry`; `ClaudeQuietTurn` in Core decides: `idle` stamped after the last main-agent event ends the turn, `busy` is liveness); Codex has none | `finishTurn`, `abandonTurn`, `noteBusy`, `dialogAnswered`, `pruneDead` |
| Transcript | last 256 KB of a Claude session's JSONL (`TranscriptTail`) | finished vs interrupted, once the registry has ended the turn; unreadable is dark |
| Codex's daemon | its control socket, `~/.codex/app-server-control/app-server-control.sock` (`CodexDaemonClient`, a WebSocket over the unix socket on a utility queue, 1 s per call, completing on main; `WebSocketFrame` and `CodexThreadRecord` in Core read the frames and the answers): `thread/read` for a quiet `working` Codex session whose pid is the managed daemon (`ProcWalk.isManagedCodexDaemon`), one question out per session, the answer applied only if the session is still `working` with the same `lastMainEventAt`; `thread/loaded/list` once at launch. `notLoaded` / `idle` → the rollout tells finished from aborted, dark by default; `active` → `noteBusy`; anything else, or no answer, leaves the session to the rollout for 15 s | `finishTurn`, `abandonTurn`, `noteBusy` |
| Codex's rollout | last 64 KB of a Codex session's `rollout-…-<session id>.jsonl` under `~/.codex/sessions/` (`CodexRollout` reads, `CodexRolloutTail` in Core decides from the turn markers alone), read for quiet `working` Codex sessions (`SessionStore.codexCandidates`) the daemon does not host or could not decide, and after the daemon says a thread runs nothing; the recorded `transcript_path` when Core trusts it, else the daemon's `path` when Core trusts it, else found by session id | `finishTurn`, `abandonTurn`, `noteBusy` |
| Copilot's `events.jsonl` | last 64 KB of `~/.copilot/session-state/<session id>/events.jsonl` (`CopilotTranscript` reads, through the same non-blocking regular-file reader as the rollout, `FileTail`; `CopilotTranscriptTail` in Core decides from the lines' types and stamps and the session an `agentStop` mirror names), read for quiet `working` Copilot sessions (`SessionStore.copilotCandidates`), and for Copilot sessions in an open wait from the moment it began, with no quiet gate (`copilotWaitCandidates`, where the latest marker decides, `CopilotTranscriptTail.waitDecision`: an `abort` after the wait began cancels it, with the turn at work, a latest `permission.completed` after it answers it), by `Engine.checkCopilotTurns`; the recorded path when it is exactly the session's own under that folder, else the session's own. `abort` and `session.shutdown` → dark, the session's `agentStop` → finished, `session.error` → `waiting(error)`; a wait's `abort` → dark, a wait's answer → `working` (journaled as `dialog-answered`) | `finishTurn`, `abandonTurn`, `abandonWait`, `failTurn`, `noteBusy`, `dialogAnswered` |
| Terminal jobs | `mysidepulse run` and the zsh hooks, over the control socket | `JobStore` |
| A running job's shell | `ProcWalk.info` (`e_pgid`, `e_tpgid`, `p_comm`, `p_starttime`) and `ProcWalk.childStartTimes` (`proc_listchildpids`, each child's fork time), read at every `sync()` for each running job with a pid; `JobStore.nextDeadline` brings one at least every `K.jobProbeSeconds` and `K.jobPromptSettleSeconds` after a first sighting at the prompt; `ShellJobLiveness` in Core builds the probe and judges it | `JobStore.probe` |
| Strip | DiskArbitration callbacks + `/Volumes` scan + 300 s rescan | `Engine.deviceAppeared` / `deviceGone` |
| Battery | IOKit power-source run-loop source + 300 s refresh | `Engine.powerChanged` |
| User attention | `NSWorkspace` app activation; `HIDIdleTime` polled every 0.5 s only while an alert is displayed; screen-lock state | acknowledgement, presence |
| Front terminal tab | `osascript` asking Terminal or iTerm2, 0.5 s timeout, 2 s cache | tab-scoped acknowledgement |
| The onboarding's five rows | a 2 s `Timer` while the wizard is up, plus `didBecomeKey`; nothing tells an app that a grant was made in System Settings | each row's own trailing control (`OnboardingCatalog`, `GrantRow`) |
| The Settings window | a 2 s `Timer` while it is open (`SettingsModel.windowVisible`): the engine's status and the notification permission. The hook files when the window opens, when System or Health is shown and after a hook button. The doctor and the crash reports (`CrashReports`) when Health is shown and on Check Again, never on a timer | the pages; Health's two tables are `HealthReport.checks(for:)` and `readings(for:)` of `SettingsModel.healthFacts`, built in Core |

Nothing polls an agent. The registry and transcript (Claude sessions),
Codex's daemon and the rollout (Codex sessions) and the `events.jsonl`
(Copilot sessions) are asked on the engine's own
deadlines (`K.abandonQuietSeconds`, `K.abandonRecheckSeconds`), never on a
free-running timer, and once at launch: after the replay, `pruneDead` (which
reads each Claude session's registry record, keeps a Codex session whose
pid is a shared app-server, `ProcWalk.isCodexDaemon`, and a Copilot session
whose `copilot` runs, since one process can hold several sessions),
then `dropStaleNotifications`, the stores' `tick`, the daemon's
`thread/loaded/list` when it hosts a working session, `checkAbandonedTurns`
with no quiet gate, and only then the first `sync()`. Every `sync()` runs the
checks, and a busy journal brings many: a Codex rollout or a Copilot
`events.jsonl` read while its session had no event since is read again
`K.abandonRecheckSeconds` later at the earliest (`Engine.rolloutCheckedAt`,
`transcriptCheckedAt`, `SessionStore.sourceReadIsDue`), so the reads stay
bounded however much else the journal delivers; the launch check reads every
one.

## Threading

| Queue | Owner | Work |
|---|---|---|
| main | `Engine`, monitors, UI | All state. DiskArbitration callbacks, the deadline timer, the input poll and the rescan timers are all scheduled here. |
| `mysidepulse.tailer` | `JournalTailer` | File reads and line decoding; hops to main to deliver. |
| `mysidepulse.ledwriter.io` | `LedWriter` | The blocking `open`/`write` on the strip. One queue for all devices. |
| `mysidepulse.ledwriter.state` | `LedWriter` | Dedupe, pending, stall bookkeeping and the write watchdog. |
| `mysidepulse.keepalive` | `Keepalive` | The 60 s timer and touch accounting; reads the device list with `main.sync`. |
| `mysidepulse.deviceprobe` (utility) | `DeviceMonitor` | Every `stat`/`fileExists` on a volume. |
| `mysidepulse.notify` (utility) | `Engine` | The `~/.claude/sessions` scan and building each request. |
| `mysidepulse.codex-daemon` (utility, concurrent) | `CodexDaemonClient` | Each call to Codex's daemon: connect, upgrade, the three frames, the answer, non-blocking with `poll`, 1 s from the moment it is asked; the completion hops to main. |
| `mysidepulse.ttyprobe` (userInitiated) | `TerminalTabProber` | The `osascript` subprocess. |
| `mysidepulse.control` | `ControlServer` | Accept, read, reply; calls the handler, which does `main.sync` into `Engine.controlResponse`. |
| URLSession delegate queue | `Notifier`, `UpdateChecker` | POST completion, with retries scheduled on a global utility queue; the update check's and download's callbacks, which `UpdateController` hops to main. The unpacking of an update runs on a global user-initiated queue. |
| global utility | several | `LedWriter` stall/recover callbacks, keepalive kill timers, the Health page's doctor run. |

The rule behind the table: nothing that can block on the strip or the network
runs on main. Device stats, LED writes and keepalive touches are each off-main,
and the touch is a separate process. Two places do `main.sync` from another
queue — the control handler and the keepalive device list — so a blocked main
queue stops the CLI from answering and the card from being touched. That is
what `doctor`'s "app" check detects.

`LedWriter` never calls out while holding its state queue; stall and recover
callbacks are dispatched to a global queue first.

## Control plane

A Unix-domain stream socket at
`~/Library/Application Support/MySidepulse/control.sock`, mode `0600`. One JSON
object per line in each direction (`ControlRequest` → `ControlResponse`,
`Sources/MySidepulsePlatform/Control.swift`). Requests are capped at 1 MB and must
arrive within 3 s; the client waits 2 s (1 s for job calls).

| `cmd` | Payload | Effect |
|---|---|---|
| `status` | — | Snapshot: mode, display, sessions, devices, battery, launch-agent state, last hook event age, jobs, masked notification status. |
| `led` | `mode` = `auto`, `off`, `toggle`, `#RRGGBB` or an effect name | Sets the mode. `toggle` is resolved in the app. |
| `brightness-cycle` | `steps` | One step of `BrightnessCycle`, resolved in the app against the mode and the plugged-in strips' brightness; replies with the mode and `brightnessPercent`, absent when the step was off. |
| `autostart` | `mode` = `on`, `off` or absent | Installs or removes the launch agent; replies with its state. |
| `job-begin`, `job-end` | `job` | Drives `JobStore`. |
| `notify` | `notify` or absent | Reads or changes notification settings; can send a test. |

`ControlResponse` has a field for the raw ntfy topic, filled only by the
`notify` command when the caller read it deliberately or just set it. `status`
carries the masked form only.

A second `ControlServer` on a live socket refuses to start; a stale socket file
is reclaimed; a failed bind is retried every `K.controlRetrySeconds` (30 s).

All fields added to the request and response types are optional, so an older
CLI and a newer app (or the reverse) still decode each other.

## Persistence

Everything lives in `~/Library/Application Support/MySidepulse/` (`Paths`).

| File | Writer | Content |
|---|---|---|
| `journal.jsonl` | `mysidepulse hook` (one `O_APPEND` write per event); the app appends its own `MySidepulseAck` and `MySidepulseVerdict` lines | One `JournalEvent` per line, JSON, sorted keys, ISO-8601 with milliseconds, at most 4096 bytes. `agent` says `claude`, `codex`, `copilot` or `opencode`; a line without it is Claude's. `claude_pid` is the agent's process whichever agent it is (OpenCode's server for OpenCode): the key kept its name. Copilot's and OpenCode's events are written under the journal's own names (`SessionStart`, `Stop`, …), never their own; an OpenCode subagent's line carries its top session as `session_id` and its own session as `agent_id`. A `MySidepulseAck` line carries the seen alert's `ack_state_since`; a `MySidepulseVerdict` line carries `session_id` and `verdict` (`turn-abandoned`, `turn-finished`, `turn-failed`, `dialog-answered`, `TurnVerdict`) and is stamped when the verdict took effect, which can be earlier than the line before it. Both are the app's, never hook traffic: a reader after the newest hook event (`doctor`, `status`) filters them out. An older app version skips both names. |
| `journal.1.jsonl` | the app, by rename | The previous journal. Rotation at 20 MB, or at 5 MB when no session is active. |
| `config.json` | the app only, mode `0600`, atomic | `AppConfig`, below. |
| `control.sock` | the app | The control socket. |

`AppConfig` keys:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `ledMode` | string | `"auto"` | `auto`, `off`, `#rrggbb` or an effect name. |
| `brightness` | `{volume name: 1…255}` | `{}` | Per-strip brightness, the strip's own value (the window and the CLI show it as a perceived percent through `BrightnessCurve`); absent means 255. |
| `autoRestartWanted` | bool? | absent | absent: never asked, register the agent. `true`: keep it registered. `false`: the user turned it off; stay off. |
| `notifyEnabled` | bool? | absent | Pushes on or off. |
| `notifyTopic` | string? | absent | The ntfy topic. A secret. |
| `notifyServer` | string? | absent → `https://ntfy.sh` | The ntfy server. |
| `onboardingDone` | bool? | absent | `true` once the wizard's last button has been pressed. Absent and `false` both open it at the next launch (functional.md §10). |
| `ledModeBeforeOff` | string? | absent | The mode `brightness cycle`'s off step replaced, which its next press brings back; cleared by any other change of mode (functional.md §11). |
| `colors` | `{slot: "#rrggbb"}`? | absent | The Colours page's overrides, keyed by `LedPalette.Slot` raw value (`working`, `codexWorking`, `copilotWorking`, `opencodeWorking`, `needsYou`, `done`, `jobRunning`, `batteryCritical`, `batteryLow`, `batteryMid`, `batteryHigh`). A slot at its default is absent; a value that is not `#rrggbb` is ignored. `Engine.palette` applies them on every paint. |

Loading falls back to defaults when the file is missing or does not decode.
Because `Decodable` is synthesised, a non-optional key that is missing fails the
whole decode — so every key added after the first release is optional.

The one `UserDefaults` key is `showInMenuBar` (default `true`).
`MenuBarController` observes it, so the settings toggle and a `defaults write`
both take effect at once.

The journal is the app's only memory of sessions. Its lines keep more than the
state machine reads — `prompt_id`, `agent_type`, `reason`, `error_type`,
`is_interrupt`, `stop_hook_active`, `last_message_tail`, `host_app_pid`,
`permission_mode`, `raw_prefix` are recorded and never consumed by the app.
They are the forensic record: the timing constants in `Constants.swift` are
calibrated from it, and `RealJournalReplayTests` replays a real journal named by
`MYSIDEPULSE_REPLAY_JOURNAL`.

`updates/` in the same support directory is the update's workshop:
`MySidepulse-<v>.dmg`, `staged/MySidepulse.app` and `install.sh`, all three
removed when a fetch starts, is cancelled, and at launch
(`UpdateInstaller.sweep`); `previous/MySidepulse.app`, the install helper's
alone, which it deletes once the new version is seen running; `install.log`;
and `result`, one line (`UpdateResult`), which the launch that reads it renames
to `result.read` for the helper to see; the next launch, or the helper, removes
that.

Not persisted: jobs and their acknowledgements, the Playground preview, the
battery glance, stalled-device state.

Outside the app's own directory, `HookInstaller` — behind both
`install-hooks` / `uninstall-hooks` and the settings window's hook rows —
edits `~/.claude/settings.json` (after copying it to
`settings.json.backup-mysidepulse`), `~/.codex/hooks.json` (after copying it
to `hooks.json.backup-mysidepulse`; Codex is on the Mac when `~/.codex` is a
directory), the trust Codex wants for those hooks in `~/.codex/config.toml`
(after copying it to `config.toml.backup-mysidepulse`; `CodexHookTrust` in
Core computes Codex's key and hash, with its own `SHA256`, and edits the file
as text; `HookInstaller.CodexFiles` names the two files, so a test hands it a
temporary Codex home) and the app's block in `~/.zshrc`, and writes or deletes
two files that are MySidepulse's whole, so they take no backup:
`~/.copilot/hooks/mysidepulse.json` (Copilot is on the Mac when `~/.copilot` is
a directory) and `~/.config/opencode/plugins/mysidepulse.js` (OpenCode is on
the Mac when `~/.config/opencode`, `~/.opencode` or `/Applications/OpenCode.app`
is). Either is ours when every entry in it runs a `mysidepulse` inside an app
bundle with `hook --agent copilot` (`HookConfig.copilotFileIsOurs`), or when
it names the hook command and the plugin id `io.mysidepulse.app.opencode`
(`HookConfig.isOurOpencodePlugin`); one that is not is never replaced or
deleted. Every path is resolved first, so a symlinked dotfile stays a
symlink. The launch agent lives at
`~/Library/LaunchAgents/io.mysidepulse.agent.plist`.

## The hook path

`mysidepulse hook` runs inside every agent's turn, so it is built to be
harmless: it drains stdin to EOF (keeping at most 8 MB), walks its ancestry
with `sysctl` (no subprocess) for the nearest agent process, its host app and
its tab, trims the payload to a bounded `JournalEvent`, appends one line, and
returns 0 on every path — including unreadable input, which becomes a
`ParseError` line, and an unknown `--agent` value, a flag without its value
or one it does not know, which are ignored (`HookCommand.Arguments`). Copilot
denies a tool whose `preToolUse` hook fails, which is one reason none is
subscribed and the other reason the hook never fails. `--agent` names the
agent outright, which is how every agent's hooks but Claude Code's are
installed, and it always wins; without the flag the nearest agent process the
walk recognises says, whichever agent it is, and Claude is the fallback.
`MYSIDEPULSE_DISABLE=1` makes it return at once. Tool inputs, tool outputs
and prompts never reach the journal.

Each agent's payload has its own trim in Core. Claude Code's and Codex's name
their event (`Trim.journalEvent`), and only the agent's own events pass
(`HookConfig.events(for:)`, in Claude Code's spelling or Codex's snake case):
any other name, the app's own line names included, is a `ParseError` line. Copilot's camelCase payloads do not, so
the entry passes `--event` (`Trim.copilotEvent`); an event outside the seven
subscribed is a `ParseError` that keeps its name and none of the body. The
hook then drops a Copilot line whose session has no folder under Copilot's
session state, `$COPILOT_HOME/session-state` when the hook's environment sets
`COPILOT_HOME`, else `~/.copilot/session-state` (a subagent's own prompt and
stop carry the subagent's id, which has none), unless that root does not
exist, and names the session's `events.jsonl` on a start, a prompt or a stop
whose payload named none (`CopilotSessionState`). OpenCode's plugin writes
OpenCode's own event type, the session, the top session of a subagent's, the
server's pid and a few words; `Trim.opencodeEvent` maps it onto the journal's
names (functional.md §4), and an event outside the mapping, a form that asks
nothing, or an event of no session writes no line at all. The pid the plugin
names is taken as the agent's when it is an OpenCode ancestor of the hook,
else the nearest OpenCode is (`HookCommand.origin`, `ProcWalk.classify`'s
`claimed`); an OpenCode session records no tab, since its server hosts every
session of every client.

Each line names the turn it belongs to as `turn_id`: the payload's `turn_id`
(Codex) or, without one, its `prompt_id` (Claude Code, which also stays under
its own key). Copilot and OpenCode name none. `SessionStore` keys the closing of a turn on it
(`changesNothing`, `closeTurn`), so a late event of a turn an `Interrupt` or a
verdict closed changes nothing, but a prompt, and a main-agent `PreToolUse` of
a turn a verdict closed (`interruptedTurnIds` holds the ones an `Interrupt`
closed); a line written before the field reads as one without a turn.

Every identifier a line copies is clamped at 200 characters and a transcript
path at `K.pathMaxChars` (1024), since a cut path names no file. Lines stay
under 4096 bytes through three shrink passes (`Trim.cappedLine`), so
concurrent hook processes appending with `O_APPEND` cannot interleave.

## Build and signing

`make app` runs `scripts/make-app.sh`: a release build, the bundle assembled by
hand, and an `Info.plist` written inline. It sources `scripts/signing.env`
(`TEAM_ID`, `NOTARY_PROFILE`, `APP_NAME`, `BUNDLE_ID`, `GITHUB_REPO`,
`DMG_ACCENT`, and `SIGN_IDENTITY` — looked up in the keychain by team
identifier rather than written out, because the certificate's common name is
Apple's to spell, not ours; empty when no such certificate is in the
keychain). It then signs innermost first — `Contents/MacOS/mysidepulse`, then
`Contents/MacOS/MySidepulseApp`, then the bundle — because the outer bundle
seals what is inside it, so a nested binary re-signed afterwards would break
that seal. A real identity additionally signs with `--options runtime
--timestamp` (the Hardened Runtime and a trusted timestamp, both of which
notarization refuses a build without) and with `Resources/MySidepulse.entitlements`
(`com.apple.security.app-sandbox` false — the app writes to the LED strip and
reads the Claude Code journal, neither of which a sandbox would allow —
and `com.apple.security.automation.apple-events` true, without which the
Hardened Runtime refuses `TerminalTabProber`'s Apple Event whatever the user
has granted under Automation). `SIGN_IDENTITY="-"` in the environment signs
ad-hoc instead, for a throwaway build that cannot be notarized; ad-hoc signing
gets neither the runtime flags nor the entitlements file.

`scripts/release.sh` is the shippable build, in the order Apple's checks need:
`make-app.sh` → verify the signature (Developer ID Application for the team,
Hardened Runtime, no `get-task-allow`, the Apple Events entitlement present) →
zip and notarize the app against `NOTARY_PROFILE` → staple the app →
`scripts/make-dmg.sh` → sign and notarize the disk image → staple it → check
`spctl` accepts both. It publishes nothing; attaching the disk image to a
GitHub release is a separate, deliberate `gh release create`. The app is
notarized on its own so that the copy dragged out of the image carries its
own stapled ticket and needs no network to be trusted. Refuses at once if the
team's Developer ID Application certificate or the `NOTARY_PROFILE` keychain
profile is missing; both are one-time setup by the Wooflab team's Account
Holder (only that role can create the certificate), the latter with
`xcrun notarytool store-credentials wooflab-notary --key <AuthKey.p8> --key-id
<id> --issuer <issuer>` against an App Store Connect API key.

`scripts/make-dmg.sh` wraps an already-signed app in the release disk image;
it signs and notarizes nothing itself. The window layout
(`scripts/dmg-settings.py`) is written into the image's `.DS_Store` by
`dmgbuild`, run from a virtualenv the script creates on demand at
`build/dmgvenv` — the Finder/AppleScript way of laying out a disk image needs
an Automation grant and fails silently without one. `scripts/dmg-background.swift`
renders the backdrop at 1x and 2x into one Retina TIFF; `scripts/dmg-volume-icon.swift`
takes the volume's icon from how macOS itself renders the app bundle
(`NSWorkspace`), because the bundled `AppIcon.icns` is a flat stand-in and the
real icon exists only in `Assets.car`.

`make install` copies the bundle to `/Applications`, launches it once so it
registers its launch agent, runs `install-hooks`, then hands the process to
launchd with `launchctl kickstart -k` and runs `doctor`.

The version is the `VERSION` variable in `scripts/make-app.sh`.

The icon's source is `Resources/AppIcon.icon`, an Icon Composer bundle, beside
the layer art it was assembled from (`Resources/icon-layers/`, described in
`Resources/ICON-NOTES.md`). `make-app.sh` ships it twice: `actool` compiles the
bundle into `Contents/Resources/Assets.car`, which macOS renders with Liquid
Glass, and `Contents/Resources/AppIcon.icns` is rasterised with `sips` from
`Resources/previews/mysidepulse-glass-preview-1024.png` as the flat form for
whatever reads `CFBundleIconFile` instead. `Info.plist` names both: `CFBundleIconName`
points at `Assets.car`, `CFBundleIconFile` at the `.icns`. Nothing is cached;
both are rebuilt on every run. `actool` ships with full Xcode rather than the
Command Line Tools, and without it the build warns and ships the `.icns` alone.
