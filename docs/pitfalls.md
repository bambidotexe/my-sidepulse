# Pitfalls

Traps this project has already fallen into, or is built around. Each one is
evidenced by the code, a test, or a recorded incident. The other documents
describe the system as it is; this one is where the history lives, so that it
is not repeated.

Each entry: **Symptom** — what you see. **Why** — why it fails on this
hardware, this macOS, or this Claude Code. **Instead** — what the code does.
**Rule** — how not to repeat it.

Contents: [The card slot and macOS](#the-card-slot-and-macos) ·
[The LED protocol](#the-led-protocol) ·
[Detecting Claude Code](#detecting-claude-code) ·
[Acknowledgement](#acknowledgement) · [ntfy](#ntfy) ·
[Launch, install, signing](#launch-install-signing) ·
[Hooks, CLI, shell](#hooks-cli-shell) · [Open issues](#open-issues)

---

## The card slot and macOS

### macOS powers the card reader down after a few idle minutes
- **Symptom.** The strip goes dark about three minutes after the last write and stays dark.
- **Why.** The built-in SD reader is power-managed; an idle card loses power, and the LEDs are on the card.
- **Instead.** `Keepalive` touches `<mount>/keepalive` every `K.keepaliveSeconds` (60 s).
- **Rule.** Anything that stops the touch — including a blocked main queue, see below — darkens the strip minutes later, not at once. Look at keepalive first when the strip dies "by itself".

### A filesystem call on a wedged volume never returns
- **Symptom.** Menu, LEDs and CLI all freeze together while a card is going bad.
- **Why.** `stat`, `open` and `write` on a hung volume block in uninterruptible I/O; no signal ends them.
- **Instead.** No device call runs on the main queue: probing on `mysidepulse.deviceprobe`, writes on `LedWriter`'s io queue behind a 2 s watchdog, keepalive as a `/usr/bin/touch` subprocess under a kill timer, capped at 3 outstanding per device.
- **Rule.** Never touch a strip's volume from the main queue, and never without a bound on how many calls can be parked.

### The watchdog reports a stall; it cannot end one
- **Symptom.** `STALLED` in `status`; or, before the fix, a strip frozen on one frame until the app restarted.
- **Why.** A slow write — a power transition with the lid closed is the reliable trigger — outlives the 2 s watchdog but does return. Treating the stall as permanent left the strip frozen; dropping the writes that arrived meanwhile left nothing to paint on recovery.
- **Instead.** A stalled device still records the program it should show. When the parked write returns, success or failure, the stall clears and the pending program is painted. A failed write leaves the dedupe entry alone so the same program is retried.
- **Rule.** `STALLED` is a transient reading, not a diagnosis. The log pair is `device stalled` then `device recovered`. Only a write that never returns needs a replug — and see the next entry.

### One write queue for every strip
- **Symptom.** With two strips, one hung card freezes both.
- **Why.** All writes share one serial io queue; a write that never returns occupies it for good. Replugging clears the bookkeeping, not the queue.
- **Instead.** Nothing. Accepted: one strip is the normal case.
- **Rule.** If two strips ever matter, give each device its own io queue before anything else.

### A replugged strip comes back at the same path, blank
- **Symptom.** After pulling and re-inserting the card, the strip stays dark, or keepalive skips it for ever.
- **Why.** The volume remounts at the same `/Volumes/…` path, and the device has rebooted into its own program. State keyed by path thinks nothing changed: the writer dedupes the repaint away, and a keepalive touch parked from the old mount keeps the new one "busy".
- **Instead.** Identity is the mount point's `(st_dev, st_ino)` (`DeviceKey`). A new identity clears the dedupe entry and starts keepalive accounting clean.
- **Rule.** Key device state by identity, never by path or name.

### DiskArbitration does not always tell you what left
- **Symptom.** A phantom device in `status`, failing every write, until some unrelated disk event.
- **Why.** A bare unmount arrives as a description change with no volume path and no disappear callback; a disappear callback can arrive with its description already gone.
- **Instead.** `reconcile()` re-probes every known mount off the main queue and compares identity, not existence — a same-named volume remounting during the probe would otherwise mask the departure. `deliver()` also retires whatever was recorded at a path when a different device shows up there. A `/Volumes` rescan runs every 300 s.
- **Rule.** Treat DiskArbitration callbacks as hints. Reconcile against the filesystem.

### `DASessionCreate` can fail
- **Symptom.** A strip that was already plugged in stays dark for the whole run.
- **Why.** Returning early on a failed session costs hotplug *and* the initial scan.
- **Instead.** Scan `/Volumes` anyway and retry the session every 30 s.
- **Rule.** A failed notification source must not take the polling fallback down with it. The same one-shot mistake was made with the control socket bind.

### Eject storm at the lock screen
- **Symptom.** The card is ejected while the Mac is locked after a hibernate wake; the strip is dark on return.
- **Why.** macOS ejects removable media in that state.
- **Instead.** An eject-approval callback vetoes ejects on the built-in reader and retries the mount every 5 s. Attempts are dissented while locked; the first one after unlock succeeds. The retry asks the session for a fresh `DADisk` by BSD name each tick, because the disk object from the approval callback never reflects a later mount and the loop would spin against an already-mounted volume.
- **Rule.** The guard matches the *reader* (`Secure Digital` / `SDXC`), so it vetoes any card in that slot, not only the strip. On this machine loginwindow already dissents software unmounts of the built-in reader before the veto is consulted: physical pull is the removal path.

### A monotonic timer sleeps with the machine
- **Symptom.** After opening the lid, a stale state stands for minutes.
- **Why.** A dispatch timer on the default clock does not advance during sleep, so every deadline slips by the length of the nap.
- **Instead.** The engine's deadline timer uses `wallDeadline`; wake calls `sync()`, which re-evaluates everything against the wall clock at once.
- **Rule.** Deadlines that mean wall-clock time need `wallDeadline`. The safety-net timers (keepalive, rescan, power refresh, DiskArbitration retry) are still monotonic — acceptable for nets, wrong for anything else.

### A battery read without a capacity is not 0 %
- **Symptom.** The whole strip breathes red on a reporting glitch.
- **Why.** A missing `kIOPSCurrentCapacityKey` defaulted to 0, which is "critical".
- **Instead.** `PowerMonitor.read()` returns no reading. The last known plugged state is kept, so the next real plug/unplug still triggers the glance.
- **Rule.** Absence of a reading is its own value.

### A blocked main queue takes keepalive and the CLI with it
- **Symptom.** The process is alive, the CLI gets no answer, and a few minutes later the strip dies.
- **Why.** The control handler and the keepalive's device-list read both `main.sync`. A repeating timer whose handler never returns never fires again. launchd's `KeepAlive` restarts a dead process, not a hung one.
- **Instead.** Nothing can currently block main; every blocking call is elsewhere. `doctor` is the detector: an unreachable socket on a running app means exactly this.
- **Rule.** Do not add blocking work to the main queue, and do not call `Keepalive.tick` from it.

### `CGSessionCopyCurrentDictionary` spells its lock key without the `k`
- **Symptom.** Screen-lock detection silently never fires.
- **Why.** The dictionary reports `CGSSessionScreenIsLocked`, not `kCGSSessionScreenIsLockedKey`.
- **Instead.** `Presence.screenIsLocked` accepts both.
- **Rule.** Verified on hardware with the screen locked; keep both spellings.

### An accessory app has no menu, and its activation policy does not always stick
- **Symptom.** ⌘C / ⌘V / ⌘W do nothing in the settings window; the Dock icon sometimes fails to appear or disappear.
- **Why.** An `LSUIElement` app has no main menu, which is what routes those key equivalents. Switching activation policy at runtime is not always honoured on the first call.
- **Instead.** `AppDelegate` builds a minimal App / Edit / Window menu; `SettingsWindow` checks the policy after setting it and retries up to three times, 0.25 s apart.
- **Rule.** Keep the minimal menu. Verify activation-policy changes; do not assume them.

### A permission prompt nobody clicked for costs the grant permanently
- **Symptom.** The user meets a macOS dialog out of nowhere, refuses it, and the app can never ask again.
- **Why.** macOS remembers an explicit refusal for good: the request API then returns the denial and shows nothing. `UpdateNotifier` used to call `requestAuthorization` the first time an automatic check found a release, which is a prompt with no explanation beside it and nothing the user did to invite it. A request API also *returns* the current state, which makes it tempting as the reader, and behind the wizard's 2 s poll that is a prompt every two seconds.
- **Instead.** `UNUserNotificationCenter.requestAuthorization` is called in one place, the onboarding's `Notifications` row. Everything that needs to know reads `getNotificationSettings`. The owner overruled the old §12 rule on 2026-09-21.
- **Rule.** Every permission prompt follows a click, with no exception. Preflight and check APIs read; request APIs ask, and only from a control's action.

### Bringing the wizard forward when a grant button reports back covers the pane it just opened
- **Symptom.** A row's button opens System Settings, and the wizard lands on top of the instructions it just gave.
- **Why.** The flow reports back immediately, while System Settings is still coming up. `NSApp.activate(ignoringOtherApps:)` there wins the race. The same goes for raising the window's `level` or giving it a `collectionBehavior`, both of which put it over System Settings permanently and, for `.moveToActiveSpace`, behind the user's terminal after a Space switch.
- **Instead.** The wizard is an ordinary window and does nothing when a flow hands over. It comes back only when the app it sent the user to **quits** (`GrantItem.mayOpen` + `FocusReturnWatch`, honoured for 300 s) or when a modal of the app's own is answered (`returnsFocus`). `didBecomeActive` alone cannot carry it: an accessory app is not activated when the user closes System Settings, so the rows poll every 2 s as well.
- **Rule.** `.claude/skills/building-onboarding/SKILL.md` holds the four activation cases. Read the table before touching who is in front.

### Splitting an Icon Composer stack into one group per layer renders it black
- **Symptom.** The compiled icon is a bare dark tile with an empty slot: the glow and the LEDs are gone, though every layer is present and `actool` reports no error.
- **Why.** A group is the unit Icon Composer applies glass, shadow and translucency to, and the groups composite against each other, not just against the canvas. Three groups each carrying the single group's original `shadow` and `translucency` bury the two upper layers under the slot's own treatment.
- **Instead.** `Resources/AppIcon.icon` keeps its layers in one group, as exported.
- **Rule.** Re-export from Icon Composer to change the stack. Do not restructure `icon.json` by hand, and never take a clean `actool` run as evidence that the icon renders.

---

## The LED protocol

The strip is closed; everything below was learned by watching it. The tests pin
the text, and the text is necessary but not sufficient: two of these were
rejected by eye within minutes of a build whose tests were green.

### A per-LED pulse returns to its pre-pulse value, not to black
- **Symptom.** In a split display the gaps show the previous program's colours.
- **Why.** Whole-strip programs always opened with `off`, which hid it.
- **Instead.** Every program mixing per-LED animations opens with a baseline line assigning every LED.
- **Rule.** No per-LED program without a baseline frame.

### The same LED twice on one line does not stack
- **Symptom.** A double blink scheduled as two pulses on one line renders as one pulse.
- **Why.** The device keeps one schedule per LED per line.
- **Instead.** The split's amber pair is composed across lines: blink one on its own line, blink two on the roll's line behind a 70 ms delay.
- **Rule.** One segment per LED per line.

### 512 bytes, 20 lines
- **Symptom.** A program the device silently ignores or truncates.
- **Why.** That is the device's ceiling.
- **Instead.** `testProgramsRespectDeviceLimits` checks every program at every LED count. Durations are spelled in seconds when shorter (`0.2s`, not `200ms`): that spelling is what buys the rainbow its fourth frame. The 8-LED rainbow sits at 501 bytes with a brightness line; a step needing five characters (`190ms`) overflows.
- **Rule.** Count bytes before adding a frame. Eight frames of eight LEDs is impossible — 79 bytes a line before any duration.

### Only use token shapes the device has already accepted
- **Symptom.** A new program does nothing.
- **Why.** There is no parser documentation and no error channel.
- **Instead.** Every program is assembled from shapes already proven: per-LED assignment segments, whole-strip pulses, `off <dur>` (which the device's own `INIT.LED` ends with), `off <dur> cosine`, `repeat`, `brightness N`.
- **Rule.** New syntax needs the strip in hand, not a test.

### A colour typo is not a wrong colour, it is no program
- **Symptom.** The strip blinks red six times and shows nothing.
- **Why.** That is the device rejecting a program it cannot parse; one malformed `#rrggbb` is enough.
- **Instead.** `testEveryColourConstantIsAValidProgramColour` checks every palette constant and effect colour; `LedMode.parse` accepts a manual colour only as `#` plus six ASCII hex digits.
- **Rule.** Six red blinks mean "unparseable program", not a hardware fault.

### Colours are calibrated on the device, not on a screen
- **Symptom.** A colour "corrected" with a picker looks wrong on the strip.
- **Why.** The LEDs' response is nothing like a display's: `#330900` *is* amber on the device. Names in `Constants.swift` describe what the strip shows.
- **Rule.** Retune colours only by eye against hardware. They are the owner's call, not a technical one.

### Do not flatten the rainbow by perceived brightness
- **Symptom.** A wheel equalised to one Rec.709 luma measures even and looks worse.
- **Why.** Flattening drags every hue down to what blue can manage, desaturates the bright hues, and breaks the property that two hues two steps apart crossfade *through* the hue between them (RGB interpolation is linear in code value, not luma).
- **Rule.** Tried on the strip and rejected. The strip is the authority.

### Rotating effects need crossfading frames, not pulses
- **Symptom.** A travelling snake with dark gaps instead of an all-on drift.
- **Why.** The working roll's single-pulse shape is ~50 % duty.
- **Instead.** Frames of per-LED assignments, each crossfading into the next, with no dark line.

### The blink pair is a rhythm, and the split must share it
- **Symptom.** Four separate flashes instead of two pairs; or a full-strip blink and a split zone drifting against each other.
- **Why.** The gap must be far shorter than the pause (under a third) or the pair falls apart; below about 50 ms the two blinks merge. The split's pause is pinned by its roll line, so the full-strip pause (1030 ms) is derived, not free.
- **Instead.** `testNeedsYouRhythmMatchesTheSplit` derives both 1.5 s cycles from the constants.
- **Rule.** For a speed change scale blink and pause together; the gap is its own dial. Retuning any of blink, gap, zone width or roll breaks that test on purpose.

---

## Detecting Claude Code

### A turn that ends in a question is finished
- **Symptom.** "Want me to commit?" shown as amber and pushed as "needs you".
- **Why.** Guessing intent from the tail of the last message.
- **Instead.** Every `Stop` is a finish. Amber comes only from explicit signals: `AskUserQuestion`, permission requests (a subagent's included), plan approval, `StopFailure`.
- **Rule.** Owner's ruling. Do not reintroduce a prose heuristic.

### `idle_prompt` is a timer, not a request
- **Symptom.** Amber, and a second push, 60 s after every finished turn.
- **Why.** Claude Code fires `idle_prompt` about 60 s after a turn goes quiet, whatever the turn was.
- **Instead.** It is never an alert. Its one use: on a `working` session whose main agent has been quiet ≥ 50 s it stands in for a lost `Stop`. The guard is 50 s, not 60, because the nudge has been recorded arriving at 60.0 s exactly.
- **Rule.** Over `done`, a hold, a standing dialog or a dead turn, it is an echo and changes nothing.

### `SubagentStop` often never comes
- **Symptom.** The strip wedged on `working` for the rest of the session.
- **Why.** In the recorded journal 27 of 28 helper-held Stops never emptied, and 19 of 44 registry-visible helpers got no `SubagentStop`.
- **Instead.** A helper expires after `K.agentStaleSeconds` (240 s) of silence. The longest recorded quiet gap before a real `SubagentStop` was 202.4 s.
- **Rule.** The price is a green strip over a helper that has been silent for four minutes. Retune only against fresh journal evidence.

### A new prompt is not a helper boundary
- **Symptom.** Green over a helper that is still running.
- **Why.** Claude Code 2.1 accepts a prompt while a previous turn's background helper runs.
- **Instead.** Only a `SessionStart` that is not a compaction clears the helper registry. Helpers otherwise leave by `SubagentStop` or silence.

### A subagent's payload carries its own `background_tasks`
- **Symptom.** A hold re-armed just as the parent's `Stop` tries to release it.
- **Why.** Subagent events share the parent's `session_id`.
- **Instead.** The background snapshot is applied only from main-agent events, as a full replace.

### The background-task filter is a whitelist
- **Symptom (potential).** The strip goes green mid-build.
- **Why.** Only `type == "shell"` entries hold a finish (subagents release through their own events; monitors never complete). An entry with no `type` is kept.
- **Rule.** If Claude Code renames that type, real shells are dropped. Check here first.

### Dialogs arrive three times
- **Symptom.** A question pushed as "Needs permission"; two pushes for one dialog.
- **Why.** Claude Code 2.1 routes `AskUserQuestion` and `ExitPlanMode` through the permission system: `PreToolUse`, then `PermissionRequest` naming the tool, then a `Notification` `permission_prompt` a few seconds later.
- **Instead.** The wait reason follows the tool name, not the event; the `Notification` echo never downgrades `question` or `plan`.

### Esc and Ctrl-C fire no hook
- **Symptom.** The roll runs on after an interrupted turn.
- **Why.** 11 of 199 recorded prompts ended that way. Ctrl-C also writes no interrupt marker in the transcript, and can kill hook delivery for the whole session.
- **Instead.** A quiet `working` session is checked against Claude Code's own registry, then the transcript tail: a completed assistant answer means a lost `Stop` (green, push); an unanswered last entry means an interrupt (dark). Sidechain entries are subagent traffic and never speak for the main turn.
- **Rule.** Both surfaces are undocumented upstream. The canary is `quiet turn undecidable` in the log; the 2 h backstop remains.

### CPU sampling cannot tell idle from light work
- **Symptom.** An idle Claude read as working.
- **Why.** With a statusline, MCP servers and its messaging socket, an idle Claude burns about 4 % of a core in bursts.
- **Rule.** Tried and removed within hours. Do not resurrect it.

### Hooks can die mid-session, and single events can go missing
- **Symptom.** Every hook silent for ~10 minutes after a Ctrl-C, then back; or one approval producing no `PostToolUse` at all.
- **Why.** Upstream.
- **Instead.** The registry keeps `working` honest during an outage and a finish inside one is recovered from the transcript. An open wait is rechecked every 15 s: a `busy` stamp more than 2 s newer than the dialog means it was answered. The margin exists because whether *opening* a dialog also stamps `busy` is unproven.
- **Rule.** A *question* raised during an outage is lost — hooks are its only carrier. The once-per-session `hooks look dead` warning is the tell.

### Claude is identified by path
- **Symptom.** Process-death detection silently inactive; a killed session holds the strip for 2 h.
- **Why.** The native installer's target is `~/.local/share/claude/versions/<version>`: its last component and its `p_comm` are a version string. Matching only "ends with `/claude`" missed it.
- **Instead.** `isClaudePath` accepts a `/claude` suffix or a `claude` path component, on `proc_pidpath` and on `KERN_PROCARGS2`.
- **Rule.** A Claude launched through an interpreter (`node …/cli.js`) is not detected. The canary is the once-per-process warning that sessions exist with no `claude_pid`.

### `kill(pid, 0)` proves a process, not the process
- **Symptom.** A dead session kept alive by a recycled pid after the app was down.
- **Instead.** The startup prune also requires the pid to still look like Claude; the registry record must carry the same pid.

### Walk the process chain from the parent
- **Symptom.** The hook records MySidepulse.app as the host app.
- **Why.** A chain that includes the CLI itself finds the CLI's own bundle first.
- **Instead.** `ProcWalk.chain(from: getppid())`.

### kqueue can miss a process that already exited
- **Instead.** `ProcessWatcher` re-checks `kill(pid, 0)` after resuming the source.

### The tailer must not truncate, and startup rests on queue order
- **Why.** The hook creates the journal with `O_CREAT`; a tailer that truncated on open would race it. At startup, replayed events reach the engine through `main.async`, and the prune and push-scrub block is enqueued after them.
- **Rule.** Making the tailer's delivery synchronous, or reordering those blocks, runs the prune before the replay.

### The settle is a delay, not a minimum on-time
- **Symptom.** A brief green still flashes.
- **Why.** `alertSettleSeconds` is 1 s by preference. Replaying 803 recorded events, the shortest real flash held 2.59 s and the next 8.97 s — so 1 s does not suppress the case that prompted it; it shortens it.
- **Rule.** A minimum on-time would close the gap and was rejected: it shows green while Claude is already working again.

---

## Acknowledgement

### A tty does not prove a tab
- **Symptom.** A green that no amount of focusing would clear — 4 min 58 s in the recorded case.
- **Why.** Claude Code's daemon runs sessions on ptys it allocates itself (`claude daemon run` → `bg-pty-host` → `bg-spare`), named like any tab, with no window behind them, and it adopts the user's session id by `--resume`. A real front tab compared against such a pty never matches. The host gate failed the same way: the chain ends at the daemon.
- **Instead.** The hook records a tab only when a shell under the host app holds the tty, unbroken from Claude up to the app. A host that can never be frontmost counts as unknown. `devname`'s `"??"` is rejected, or a chain of tty-less daemons would agree on it.
- **Rule.** Every gate fails open: a rejection may only widen acknowledgement, never strand an alert.

### App-level acknowledgement clears every tab
- **Instead.** The front tab is asked of Terminal / iTerm2, with a 0.5 s timeout and a 2 s cache; unknown falls back to app level.

### `a || b` skips `b`
- **Symptom.** A job alert not acknowledged on exactly the pass where a session alert was.
- **Instead.** `acknowledgeAll` calls both stores as two statements.

### Acknowledgements must survive a restart
- **Symptom.** Every `make install` under a standing alert resurrected the amber and re-delivered its push — three duplicates in one afternoon.
- **Instead.** Each acknowledgement is journaled as a `MySidepulseAck` line keyed by the alert's `stateSince` (matched within 5 ms, so it can never clear a newer alert), and startup scrubs push deadlines already past the 120 s late-drop.

---

## ntfy

### The topic is a password
- **Symptom.** A topic pasted into a transcript or an issue is burned: anyone can read the feed. It has happened once.
- **Why.** ntfy topics are unauthenticated.
- **Instead.** Generated, never derived from the machine. `config.json` is `0600`, re-applied after every save because an atomic write replaces the inode. `status`, `doctor`, the Health report and the log carry only the first six characters; the status reply has no field that could hold the raw topic. Only `mysidepulse notify` and the Notifications page's reveal print it.
- **Rule.** Never put a live topic in a commit message, an issue, a doc or a transcript. Topics are validated, not escaped: anything but `[A-Za-z0-9_-]{1,64}` is rejected.

### One POST is not a delivery
- **Symptom.** The push that matters most never arrives.
- **Why.** The moment it matters is the moment the lid closes — which is when wifi is re-associating.
- **Instead.** Up to 3 attempts, 5 s timeout, 2 s apart, for network errors, 5xx, 408 and 429. Other 4xx are not retried: the request itself is wrong. Each retry is logged, because a push that needs three goes every evening is a wifi problem worth seeing.

### A late push is worse than none
- **Instead.** A push more than 120 s overdue — sleep, replay — is dropped. While the user is present a due push is deferred, not dropped; acknowledgement cancels it outright.
- **Rule.** Nothing is queued for later, on purpose.

### Duplicate pushes have four sources
- A repeated alert of the same kind (it moves the deadline forward instead).
- The `Notification` echo of a dialog.
- The 60 s `idle_prompt` nudge over a finished turn.
- Journal replay after a restart.

### Delivery does not belong on the main queue
- **Why.** It scans `~/.claude/sessions` and does network I/O; neither may sit in front of an LED write.

### Agents of their own must not ring the phone
- **Instead.** Sessions whose Claude record has kind `bg`, `daemon` or `daemon-worker` light the strip and never push.

---

## Launch, install, signing

### `SMAppService.agent` pins a LightWeight Code Requirement to the job
- **Symptom.** Crashes go unrecovered while `SMAppService.status` reports `.enabled`. Logs: `OS_REASON_CODESIGNING | Launch Constraint Violation`, `Unable to get updated LWCR … 0x16`; after deleting the bundle, `copy_bundle_path … Invalid or missing Program` (EX_CONFIG 78).
- **Why.** launchd checks that requirement on every spawn, and Background Task Management stores the agent against the bundle, so removing the bundle first leaves a record that resolves to nothing. Neither re-registering nor `launchctl bootout` clears it.
- **Instead.** A plain plist in `~/Library/LaunchAgents`, bootstrapped with `launchctl`. It carries no LWCR and no Background Task Management record to go stale, so it survives any number of reinstalls regardless of how the app is signed.
- **Rule.** The app's Developer ID signing keeps its code identity stable across rebuilds, which removes the reason an ad-hoc build could never register through `SMAppService.agent` at all; the plist stays anyway, since it needs none of that machinery. Even the plist job gets an LWCR on macOS 26: the first respawn after an install is killed once, launchd logs `Requesting LWCR update on next spawn`, and it recovers after one ~10 s throttle cycle. Harmless; do not fix it.

### Bootstrapping the agent does not put the running app under it
- **Symptom.** After a drag install from the disk image, Settings > Startup shows the orange warning and `doctor` says `agent installed, but this process was not started by it: no crash restart`. `launchctl list` shows the job loaded with no pid: `-  0  io.mysidepulse.agent`.
- **Why.** `install()` bootstraps the job and `RunAtLoad` makes launchd spawn it at once, but that spawn finds the hand-launched instance already up and terminates itself, as a second copy must. `KeepAlive/SuccessfulExit=false` then correctly declines to restart something that exited zero. The live app is a LaunchServices launch, which launchd does not supervise.
- **Instead.** The app hands over: a detached helper waits for the pid and runs `launchctl kickstart` on the job. `kickstart` cannot be run from inside the app, because the job is what would replace the process running it. `scripts/install.sh` did the same thing from outside with `killall` and `kickstart -k`; a copy dragged out of the disk image has nobody to run those, which is why it has to be the app's own job.
- **Rule.** A hand-over that fails opens the bundle again. An app that failed to change hands is a warning in Settings; an app that vanished after a double-click is a broken install.

### Killing a KeepAlive job is asking launchd to restart it
- **Symptom.** A reinstall's `open` reaches an instance that started before the script was finished, from the bundle the script was in the middle of replacing, and which never saw anything the script wrote for it.
- **Why.** `killall` sends SIGTERM. That is a non-zero exit, and `KeepAlive/SuccessfulExit = false` restarts exactly those. The script and launchd are then racing over the same app.
- **Instead.** `launchctl bootout gui/<uid>/<label>` unloads the job and takes its process with it, and nothing comes back until the job is bootstrapped again. Never `disable`, which is permanent (below).
- **Rule.** Anything the app must read at its next launch is written before the app is stopped, not between stopping it and starting it.

### `launchctl disable` is permanent, and nothing ordinary undoes it
- **Symptom.** Every `launchctl bootstrap` of the agent fails with `Bootstrap failed: 5: Input/output error`. The app writes a correct plist at every launch and launchd refuses it, so the strip is dead and `doctor` reports the agent missing for ever.
- **Why.** `disable` is not the opposite of `bootstrap`. It writes an override into `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist`, which survives deleting the plist, reinstalling the app, and a reboot. Only `launchctl enable gui/<uid>/<label>` clears it, or editing that file as root.
- **Instead.** `bootout` unloads a job and leaves no record. It is the only verb an uninstall or a takeover uses.
- **Rule.** Never write `launchctl disable` anywhere: not in a script, not in the app, not in a one-off command at a terminal. `UninstallPlanTests` pins the helper against it.

### The bundled `.icns` is a flat stand-in, not the icon
- **Symptom.** A disk image's volume icon looks flat and colourless next to the Liquid Glass icon the Dock and Finder show for the installed app.
- **Why.** `scripts/make-app.sh` rasterises `Contents/Resources/AppIcon.icns` from a static 1024 px preview PNG, because `.icns` is what `CFBundleIconFile` falls back to for whatever does not read `Assets.car`. The real icon is compiled by `actool` from the Icon Composer document into `Assets.car`, and only the system's own rendering of the bundle reproduces it.
- **Instead.** `scripts/dmg-volume-icon.swift` asks `NSWorkspace` how macOS itself renders the built app and builds the disk image's volume icon from that, never from the bundled `.icns`.
- **Rule.** A clean run of `make-app.sh` or `make-dmg.sh` is not evidence the icon looks right; check the rendered bundle or the mounted image by eye.

### An app started by `open` is nobody's job
- **Symptom.** The first crash after an install takes the strip and the pushes down until the next login.
- **Why.** `KeepAlive` supervises only the instance launchd spawned.
- **Instead.** `make install` launches once (which registers the agent), then kills it and `launchctl kickstart -k`s the job.
- **Rule.** `doctor` checks supervision, not registration: only `XPC_SERVICE_NAME == io.mysidepulse.agent` proves the running process would be restarted. A plist on disk proves nothing.

### `launchctl bootout` kills the process running as the job
- **Symptom.** Turning `Open at Login` off killed the app mid-request.
- **Instead.** When the app is the agent's own process, removing the plist is the whole operation; the job is simply not there next time.

### `MySidepulse` and `mysidepulse` are one file
- **Why.** `Contents/MacOS` sits on a case-insensitive volume; the second `cp` silently overwrites the first.
- **Instead.** The GUI binary is `MySidepulseApp`. Only `CFBundleExecutable` has to match.

### The app's name is an identity in six places
- **Symptom.** After a rename: two apps drive the strip at once, every hook fails, the ntfy topic is gone, macOS asks for its permissions again, and alerts already seen relight.
- **Why.** The name is not a label. It is the bundle id (TCC grants, `UserDefaults`), the launch agent's label, the `Application Support` directory (`config.json`, the journal), the hook command written into `~/.claude/settings.json` and the marker `HookConfig` recognises its own entries by, the `MySidepulseAck` event name inside the journal, and the `MYSIDEPULSE_*` variables in the user's shell.
- **Instead.** The move from the former name, SidePulse, was a takeover script run first by `make install` (`scripts/takeover-former-install.sh`, in git history; deleted once this Mac had moved over). In order: uninstall the former install's hooks with that install's own CLI, boot its agent out before killing it, move its support directory across (keeping `config.json` at `0600`), rename the acknowledgement lines in the moved journal.
- **What did not need doing.** Restarting the Claude Code sessions that were open. Claude Code (2.1.278) re-reads `settings.json` while it runs: two sessions open across the takeover wrote through the new hook path within seconds of `install-hooks`. Hooks are not a snapshot taken at session start.
- **Rule.** A rename is a migration. The user's own `.zshrc`, keyboard shortcuts and `PATH` symlink are outside what an install may touch: list them, do not edit them. (The app writes its own delimited block into `.zshrc` only when the user presses `Set up…` in Settings.) The hardware keeps its name — `SidePulseDot…` / `SidePulsePro…` volume names are how the LED count is read.

### GitHub answers 404 for "no release" and for "not yours to see" alike
- **Symptom.** `Check for updates…` says `No release published yet.` for ever, although a release exists.
- **Why.** The check is anonymous, and to an anonymous caller a private repository does not exist: `/releases/latest` is 404 either way. The same reply also covers a repository whose releases are all drafts or pre-releases.
- **Instead.** The check works once the repository is public and has a published, non-prerelease release whose tag is a version (`v1.8.0`) and which carries a `.dmg` asset. A token in the app is not the way round it: it would be a second secret to guard, for a personal tool.
- **Rule.** 403 (rate limit) and every other status are failures and say so; only 404 reads as "nothing there". A failure must never read as `Up to date.`

### A download task succeeds on a 404
- **Why.** `URLSession.downloadTask` reports no error for an HTTP error status: it hands over the error page as the downloaded file.
- **Instead.** `UpdateDownload` checks the status before it moves anything, so an error page is never saved as `MySidepulse-<v>.dmg`; and a saved file is held against the length and the SHA-256 GitHub states for the asset before anything opens it.

### A helper started by the app dies with the app
- **Symptom.** The app quits for an update and nothing happens: the helper that was to swap the two bundles is gone.
- **Why.** launchd kills whatever is left in a job's process group when the job's main process exits, and this app runs as a launchd job. Measured with three throwaway jobs: the plain `posix_spawn` child never ran, the one spawned with `POSIX_SPAWN_SETPGROUP` did.
- **Instead.** `DetachedProcess`: a process group of its own, no inherited descriptors, an environment of the app's making.

### Everything that can refuse an update has to happen before the quit
- **Why.** Quitting turns the strip off. An updater that quits first and installs after can end with a dark strip, no app, and nothing on screen to say why.
- **Instead.** The release is fetched, held against GitHub's digest, unpacked, checked (`StagedUpdateCheck`, `CodeSignature`) and the folder tried (`UpdateInstaller.obstacle`) while the app is up, where a failure is a sentence in the window; **Install and Relaunch** is enabled only after all of it. After the quit there are two renames on one volume and a start, each with its way back: a failed second rename undoes the first, and a new version not seen running within 15 s, or gone 2 s after it was seen, is moved out and the previous one moved back and started. The helper touches nothing until the app's pid is gone, and gives up untouched after 20 s: a second copy terminates itself at launch, so the new one may only start once the old one has left.
- **Rule.** The helper writes `installed` before it starts the app, which reads it as it launches, and overwrites it if it rolls back. The app's tidying never touches `updates/previous/`: only the helper deletes it, once it has seen the new version running.

### A new version that is gone two seconds later has crashed, or has been quit
- **Symptom.** The update is rolled back and the previous version comes back, because the user quit the new one as soon as it appeared: the relaunch shows the update window saying the install worked, with a **Done** button and the menu bar a click away.
- **Instead.** The launch that reads the outcome renames it to `result.read`. Gone with that mark in place, the version had started and its quit is the user's; gone without it, the helper looks again for as long as it first looked, and only if it is still nowhere is the previous one put back. That second look is also what covers a copy changing hands with launchd, which is gone for exactly that moment. `UpdateController.start()` runs last in `applicationDidFinishLaunching`, so the mark means the launch got that far.

### A helper that gives up while the app may still quit
- **Why.** Two clocks, the helper's limit and the app's "did not quit" notice, leave a gap in which the app quits with no helper left: the strip dark, nothing installed, nothing running, nothing said.
- **Instead.** One clock decides. After `K.updateStallNoticeSeconds` the app stops the helper (`SIGTERM`; while the app runs the helper can only be in its wait, having touched nothing) and then says so. The helper's own, longer limit serves only an app too hung to do that.

### `ps` lists the path the kernel ran, not the one the app was installed at
- **Why.** An app reached through a symbolic link (`/tmp` is one) runs under its resolved path, and `ps -axo comm=` lists that one. `kill -0` still answers for a process that has exited and has not been reaped by whoever started it.
- **Instead.** The helper looks for the executable under the installed path and under `pwd -P` of it: missing a running version would roll back a good install. It counts an exited, unreaped app (state `Z`) as gone, and anything `ps` cannot say as still running, the safe way round.

### A new `config.json` key can wipe the config
- **Symptom.** After an update every setting is back to default — including a freshly minted ntfy topic, orphaning the phone.
- **Why.** Synthesised `Decodable` throws on a missing non-optional key, and `load()` treats any failure as "no config".
- **Rule.** Every key added after the first release is optional.

### SwiftPM records the deployment target as the SDK, and Liquid Glass follows it
- **Symptom.** Built with the macOS 27 SDK and a macOS 15 target, the settings toolbar drew its selected page as a flat tinted rectangle, while SnappySnap's identical window drew the glass pill.
- **Why.** `swift build` writes the deployment target into the binary's `LC_BUILD_VERSION` as both `minos` and `sdk` (`otool -l` showed `sdk 15.0`), and AppKit gates the Liquid Glass design on that recorded SDK, not on the SDK that compiled the code.
- **Instead.** The target is macOS 26 in `Package.swift` and `LSMinimumSystemVersion`; tools 5.10 has no `.v26`, so it is spelled `.macOS("26.0")`.
- **Rule.** Do not lower the target to widen compatibility: the window's chrome goes with it.

---

## Hooks, CLI, shell

### The hook runs inside every Claude Code turn
- **Rule.** It must never block and never exit non-zero. It drains stdin to EOF even past its 8 MB cap (or Claude Code's write blocks), spawns nothing, and swallows every error. Journal lines are capped at 4096 bytes so concurrent `O_APPEND` writes cannot interleave.

### `argv[0]` has no directory when the CLI is found on `PATH`
- **Symptom.** `install-hooks` writes a hook command that resolves nowhere.
- **Instead.** `_NSGetExecutablePath`, symlinks resolved. After writing, `install-hooks` counts the events that actually carry the command and reports "N of 15", exiting 1 if a shape it refuses to rewrite kept one out.

### `mysidepulse run` must not ignore signals
- **Why.** `SIG_IGN` is inherited through `posix_spawn`, which would break the child's own Ctrl-C.
- **Instead.** Ctrl-C hits the whole foreground group; the wrapper dies with its child and the app's pid watch clears the job.

### The zsh snippet is a text no compiler checks
- **Instead.** `ShellInitTests` runs the generated snippet in a real interactive zsh against a stub CLI. That test caught two real bugs; comparing the string with itself proves nothing.
- **Rule.** `precmd` captures `$?` first and returns it, or later hooks and prompt themes lose the exit status. The same discipline applies to the notification copy (`AlertCopy`) and the LED program text.

---

## Open issues

Known, bounded, and left alone.

- **Cancelling a standing dialog with Esc leaves its amber up** until the next prompt or the 2 h backstop: the abort fires no hook, and at a dialog "at rest" and "waiting for you" look the same from outside.
- **A subagent's question or plan wait is not cleared by that subagent's next event** — only `waiting(permission)` is (`SessionStore.apply`, subagent branch). The answered-dialog rescue clears it within ~15–30 s.
- **A subagent quiet for over 4 minutes releases a hold while it still runs.**
- **A daemon-hosted session has no tab to scope to**, so it is acknowledged by any input anywhere. And because the daemon shares the user's session id, a `SessionEnd` from *any* process with that id deletes the record while the daemon's process may still run; it reappears on its next event.
- **The `idle_prompt` lost-Stop rescue writes no log line**, unlike the registry rescues.
- **Jobs are not journaled**: a restart forgets them and their acknowledgements. A `mysidepulse run` wrapper killed while its child survives leaves the command running unlit.
- **The zsh hook labels a compound command by its first head** (`cd repo && npm run build` shows as `cd`), and a prefix is itself a head: `sudo vim`, `FOO=bar vim`, `time vim` are not skipped unless the prefix is added to `MYSIDEPULSE_SKIP`.
- **`doctor`'s strip check never fails**, and its auto-start check fails when `Open at Login` is deliberately off — fairly, since that also turns off crash restart.
- **`reconcile()` re-stats every known mount** when an unrelated disappear arrives without a description, so a transient stat failure can briefly report a live strip as gone.
- **Wake forces no rescan**, and the safety-net timers pause during sleep.
