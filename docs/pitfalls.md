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
[Detecting Codex](#detecting-codex) ·
[Detecting Copilot](#detecting-copilot) ·
[Detecting OpenCode](#detecting-opencode) ·
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

This is every app's trap: `docs/shared/pitfalls.md`, **S5**. Here `SettingsWindow` checks the policy after setting it and retries up to three times, 0.25 s apart.

### A permission prompt nobody clicked for costs the grant permanently

This is every app's trap: `docs/shared/pitfalls.md`, **O7**. Here `requestAuthorization` is called in one place, the onboarding's `Notifications` row; the owner overruled the old §12 rule on 2026-09-21.

### Bringing the wizard forward when a grant button reports back covers the pane it just opened

This is every app's trap: `docs/shared/pitfalls.md`, **O1** and **O3**.

### A stepping button in a stack with an invisible spacer stops being where it is drawn

This is every app's trap: `docs/shared/pitfalls.md`, **O9**. Here the footer is `OnboardingWindowController.listPage`.

### Splitting an Icon Composer stack into one group per layer renders it black

This is every app's trap: `docs/shared/pitfalls.md`, **I1**.

---

## The LED protocol

The strip is closed; everything below was learned by watching it. The tests pin
the text, and the text is necessary but not sufficient: two of these were
rejected by eye within minutes of a build whose tests were green.

### An overlay on an animation restarts it
- **Symptom.** A white LED over the running animation, shown for two seconds after a brightness press, made the strip look like it flickered.
- **Why.** The strip only takes whole programs, and a new program restarts its animation from the start: a breath caught halfway drops back to dark. The overlay restarted it when it left. Doing it at all also meant rewriting every whole-strip line per LED (`off`, `#hex` and a whole-strip pulse paint every LED), and the needs-you blink rewritten that way was over 512 bytes on 8 LEDs.
- **Instead.** The white LED shows only on a strip that would be dark, where its leaving cannot be seen; an animation shows the new brightness itself, carried on by a tail (below).
- **Rule.** Anything added to the strip for a moment costs a restart of what it shows when it goes. Add it only where nothing is playing.

### Waiting for the loop's end was rejected
- **Symptom.** A brightness press that did nothing for up to four seconds, until the breath came round.
- **Why.** Holding a change until the loop's boundary hides the restart, and the owner rejected it outright: a change applies now. The firmware refuses `repeat N`, so a single program cannot play the rest of the loop once and then loop.
- **Instead.** Two writes: a one-shot tail, the rest of the current loop from the strip's phase at the new brightness, then the loop itself when the tail ends (`LedContinuation`, `Engine.paint`). The phase is the host's clock since the write; the strip's write-to-start latency is the same for every write and cancels. Whether the two clocks drift over a long roll is unmeasured, and accepted.
- **Rule.** A change applies at once. What the strip is playing is cut, never held.

### A segment starts from the visible value, at the old brightness
- **Symptom.** After a brightness press mid-roll, the LEDs already lit finished their pulse at the old brightness and only the LEDs lighting after it showed the new one.
- **Why.** The strip keeps the visible LED state across parses as the transition start colours, and that state is what was drawn, brightness included. A new brightness reaches what the program draws towards, not where each LED starts from.
- **Instead.** Every brightness tail opens with a bridge line taking each lit LED to where it goes on from, at the new brightness (`LedContinuation.bridgeLine`).
- **Rule.** A new brightness reaches a lit LED only through a colour it is told to go to.

### A brightness line flashes the lit LEDs at the parse
- **Symptom.** With a one-frame jump line in place, the bridge's first form, a brightness press mid-roll flashed the lit LEDs far brighter than the wave for a moment (the owner's video, frames of a wide white blob), while the build before it, whose tails opened with a fall, had not.
- **Why.** On the owner's strip a program that carries `brightness N` draws at least one frame before the line takes effect. A fall from the visible value drew that frame at the value it already had; a jump line's targets are the level colours meant to be dimmed by the line, and drew at full scale. The vendor's engine, newer than the firmware, shows no such frame, so it was not the way to find out.
- **Instead.** No program carries a brightness line. `LedProgram.scaled` multiplies every colour by the brightness on the way out, the same values the line would have drawn, and the tails are cut from unscaled text and scaled once.
- **Rule.** Nothing the strip parses may depend on a line taking effect before the first frame.

### A mid-wave cut is not exact
- **Symptom.** In the roll, one or two LEDs miss their peak on the pass a brightness change or a zone lands on, or hold a dim red for up to a loop.
- **Why.** The roll's pulses overlap, so no line boundary can fall between them, and a pulse on its way up needs two segments (finish the rise, then fall) that one line cannot hold for one LED. A whole-strip pulse is two cosine halves and cuts exactly; a per-LED pulse past its peak is a crossfade to black; a rising one is not expressible.
- **Instead.** Both single segments were tried on the strip. A pulse from the LED's current level finishes the rise but returns to that level and holds it until the loop's next dark line, and each further press keeps it there: LEDs staying lit too long. A fall from that level never lights the LED: a hole in the wave, LED 5 dark between four lit and two lit in the owner's photo. So the tail opens with a bridge line (device.md *The bridge*): a rising LED below half its peak fades to black on it and plays whole from black after it; one past half rises to its peak on it and falls from there. Nothing is skipped and nothing stays lit; the price is a late peak on the two dimmest LEDs and a 60 ms rise on a bright one, on that pass only. A blinking zone that opens mid-wave adds a second cut 200 ms on, the roll's next 200 ms written as one crossfade per LED to the value the pulse reaches there.
- **Rule.** Judge a cut on the strip. The exact-text tests pin the tail; they cannot say how it looks.

### Brightness is linear in power, not in what the eye sees
- **Symptom.** Brightness steps of 33 %, 67 % and 100 % of the strip's 1…255 scale that look almost the same.
- **Why.** The eye's response to light is close to a cube root: a third of the power already looks like most of full.
- **Instead.** Every brightness the owner sets is a perceived percent through `BrightnessCurve` (`255 · fraction^γ`).
- **Rule.** Never step or slide the strip's brightness value linearly.

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
- **Instead.** `testEveryColourConstantIsAValidProgramColour` checks every palette constant and effect colour; `LedMode.parse` accepts a manual colour only as `#` plus six ASCII hex digits, and `LedPalette.applying(overrides:)` ignores a saved colour that is anything else, so a hand-edited `config.json` cannot reach the device as a broken program.
- **Rule.** Six red blinks mean "unparseable program", not a hardware fault.

### Dim with brightness, never with a darker hex
- **Symptom.** Colours that look nearly black on screen, pictures in the window drawn from hand-picked stand-ins instead of the real colours, and a colour picker that cannot show what the strip will do.
- **Why.** The colours used to be dim hexes (`#330900` for amber) chosen to fake a low brightness, before the per-strip brightness was known. A hex that low is a colour and a brightness mixed into one number, and a screen cannot render it as the LED does.
- **Instead.** Every colour is a true colour, its hue at full scale, the same hex on the strip and in the window; the strip's brightness setting dims it, applied to the text as its last step (`LedProgram.scaled`, above), never to the palette. The Colours page plays a colour on the strip while it is picked, because an LED still renders a hue differently from a display.
- **Rule.** Never darken a hex to dim the strip. Colours are the owner's call, judged on the strip.

### Do not flatten the rainbow by perceived brightness
- **Symptom.** A wheel equalised to one Rec.709 luma measures even and looks worse.
- **Why.** Flattening drags every hue down to what blue can manage, desaturates the bright hues, and breaks the property that two hues two steps apart crossfade *through* the hue between them (RGB interpolation is linear in code value, not luma).
- **Rule.** Tried on the strip and rejected. The strip is the authority.

### Rotating effects need crossfading frames, not pulses
- **Symptom.** A travelling snake with dark gaps instead of an all-on drift.
- **Why.** The working roll's single-pulse shape is ~50 % duty.
- **Instead.** Frames of per-LED assignments, each crossfading into the next, with no dark line.

### Two passes of the shared roll fit the strip; two passes under a zone do not
- **Symptom.** A shared roll that alternates its colour by pass on the whole strip and by LED under an alert zone; on the Pro, a roll three or four agents share that alternates by LED everywhere, while the Dot keeps its passes.
- **Why.** The device takes 512 bytes. Two passes of the roll are 496 bytes on 8 LEDs; add the split's baseline and its two blink lines per pass and the program is over 700 bytes, with no token to drop: the delays and durations are the shape the strip has proven.
- **Instead.** `LedProgram.rollPasses` writes one pass per colour on the whole strip wherever the rendered program fits 512 bytes and 20 lines, else one pass by LED; `splitProgram` gives each roll LED a colour (`zoneRollColors`).
- **Rule.** Decide on the rendered text, not on a count. On the Pro three or four agents do not fit as passes (three passes are 741 bytes), so their roll is one pass, LED *i* in agent *i* mod *n*'s colour, and under a zone each roll LED keeps that colour; on the Dot four passes are 294 bytes and every number of agents keeps its passes.

### A tail of the shared roll ends at the pass, not the loop, when the bridge would not fit
- **Symptom.** After a brightness press during Claude's pass of the shared roll, Claude's colour twice in a row, once.
- **Why.** The bridge line and the whole rest of the two-pass loop are over 512 bytes as soon as five or six LEDs are lit. Dropping the bridge leaves a hole in the wave, which the owner rejected on the single roll.
- **Instead.** `LedContinuation.tail` keeps the bridge and ends the tail where the pass under way ends, every LED dark, and `Engine.paint` hands over at the tail's own length. A zone opening over the shared roll (`transition`) always ends at the pass.
- **Rule.** A tail's `lengthMs` is the boundary. Nothing else may compute it from the loop.

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
- **Instead.** A quiet `working` session is checked against Claude Code's own registry: `idle` stamped after the last main-agent event ends the turn at once (`ClaudeQuietTurn`). Only then is the transcript tail read, to say how it ended: a completed assistant answer means a lost `Stop` (green, push); an unanswered last entry, or a transcript that cannot be read, is dark. Sidechain entries are subagent traffic and never speak for the main turn.
- **Rule.** Both surfaces are undocumented upstream. The canary is `quiet turn undecidable` in the log; the 2 h backstop remains.

### CPU sampling cannot tell idle from light work
- **Symptom.** An idle Claude read as working.
- **Why.** With a statusline, MCP servers and its messaging socket, an idle Claude burns about 4 % of a core in bursts.
- **Rule.** Tried and removed within hours. Do not resurrect it.

### Hooks can die mid-session, and single events can go missing
- **Symptom.** Every hook silent for ~10 minutes after a Ctrl-C, then back; or one approval producing no `PostToolUse` at all.
- **Why.** Upstream.
- **Instead.** The registry keeps `working` honest during an outage and a finish inside one is recovered from the transcript. A wait, a failed turn's `waiting(error)` included, is rechecked every 15 s: a `busy` stamp more than 2 s newer than the wait means the agent is at work again. The margin exists because whether *opening* a dialog also stamps `busy` is unproven.
- **Rule.** A *question* raised during an outage is lost — hooks are its only carrier. The once-per-session `hooks look dead` warning is the tell.

### Claude is identified by path
- **Symptom.** Process-death detection silently inactive; a killed session holds the strip for 2 h.
- **Why.** The native installer's target is `~/.local/share/claude/versions/<version>`: its last component and its `p_comm` are a version string. Matching only "ends with `/claude`" missed it.
- **Instead.** `isClaudePath` accepts a `/claude` suffix or a `claude` path component, on `proc_pidpath` and on `KERN_PROCARGS2`.
- **Rule.** A Claude launched through an interpreter (`node …/cli.js`) is not detected. The canary is the once-per-process warning that sessions exist with no `claude_pid`.

### `kill(pid, 0)` proves a process, not the process
- **Symptom.** A dead session kept alive by a recycled pid after the app was down.
- **Instead.** The startup prune also requires the pid to still look like Claude and, when the registry has a record for the pid, the record to name the same session; a record is only trusted when it carries the same pid.
- **Rule.** A recycled pid with no record, or a Claude that took over the pid before writing its record, is kept until the 2 h backstop.

### The registry is not always under `~/.claude`
- **Symptom.** Under an account switcher such as cswap, every Claude Code turn ended with Esc or Ctrl-C rolls for 2 h, and the log says `quiet turn undecidable: … no registry record for claude pid`.
- **Why.** `CLAUDE_CONFIG_DIR` moves the registry, and the only way to it through the process is its environment, which macOS may withhold from another process.
- **Instead.** The directory is read from the transcript path the hooks name (`<config>/projects/<slug>/<session>.jsonl`, kept on the session), for the rescues and the launch prune alike; the process's environment, then `~/.claude`, only for a session no line has named a transcript for.
- **Rule.** A transcript outside `<config>/projects/` would fall back the same way; none is known.

### A verdict that lives in memory dies with a relaunch
- **Symptom (potential).** A turn the registry had already closed rolls again after a relaunch, until the first check.
- **Why.** The journal holds only hook lines; the rescues' verdicts are the app's own conclusions and no hook repeats them.
- **Instead.** Every verdict is appended as a `MySidepulseVerdict` line stamped when it took effect; replay applies the outcome it records, never the live decision again: a finish found after a helper had gone stale would otherwise be held behind that helper, fresh at the stamp, and push again once it released. The tailer's delivery of the app's own line changes nothing. The line is written after the fact, so its stamp can be older than the line before it.
- **Race.** A hook line logged after the verdict's stamp but delivered after the check replays ahead of the verdict and voids it, and a `dialog-answered` read back can clear a dialog whose hook arrived late; the next hook or the 2 h backstop ends such a session. The window is the tailer's delivery delay, milliseconds.
- **Rule.** Anything that reads the journal for "the last hook event" filters out the app's lines (`MySidepulseAck`, `MySidepulseVerdict`), or a verdict written after the fact reads as hook traffic.

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

## Detecting Codex

### Codex copies Claude Code's hooks into its own file, bare
- **Symptom.** `~/.codex/hooks.json` holding `mysidepulse hook` on eleven events that nothing of ours wrote; a Codex session that would be journaled as Claude's, with no agent process found.
- **Why.** Codex's own import of Claude Code's settings (`Migrate hooks from ~/.claude to ~/.codex/hooks.json` in its global state) copies every hook entry as it is.
- **Instead.** Codex's hooks are installed as `mysidepulse hook --agent codex`, so the journal line says who fired it whatever process did; `HookConfig.install` replaces every entry carrying the marker, migrated ones included. A hook with no flag falls back to the nearest agent process in its ancestry, then to Claude.
- **Rule.** A hook must say who it is for. Never read the agent from the payload's shape: both agents send the same fields.

### A hook in `~/.codex/hooks.json` alone never runs
- **Symptom.** The 12 entries in `hooks.json`, Codex's `/hooks` screen listing them as untrusted (or modified, after a re-install that changed an entry), and no Codex line in the journal while Codex runs.
- **Why.** Codex keeps a trust status per hook (`Untrusted`, `Trusted`, `Modified`, by a hash of the entry) and runs the untrusted ones only behind its own `--dangerously-bypass-hook-trust`. The trust is a `[hooks.state."<key>"]` table in `~/.codex/config.toml` whose `trusted_hash` equals the hash Codex computes for the entry; its `/hooks` screen writes it, and switches a hook off with `enabled = false` in the same table.
- **Instead.** Setting up Codex's hooks writes that table for each of the 12, with the key and the hash Codex computes (`CodexHookTrust`, [macOS.md](macOS.md) *Codex: its hooks and their trust*). `CodexHookTrustTests` pins the hash to the ones Codex 0.157.0 reported over `hooks/list` for hooks of this shape. The System page, the Health page's `Codex hooks` line and the doctor's `codex hooks` check count a hook as set up only while it is installed **and** trusted and not switched off; one installed and untrusted reads orange, with a fix saying Codex never runs it and to press Set Up Hooks.
- **If Codex changes its hash.** The rows read Enabled (the app wrote what it computed), Codex's `/hooks` screen says modified, and no Codex line reaches the journal: Health's *Last hook event* goes stale while Codex runs. Re-derive the hash from `codex-rs/hooks/src/engine/discovery.rs` and `codex-rs/config/src/fingerprint.rs`, or ask a running `codex app-server` over `hooks/list`, and fix the test.
- **Rule.** Never write a Codex hook without its trust, and never call one set up on `hooks.json` alone.

### The trust key moves with the entry's index
- **Why.** A key ends in the group's index in the event's array. An entry of ours placed before a stranger's would shift the stranger's key and untrust their hook.
- **Instead.** Ours is appended after every existing group. A table of ours left under an old key (the file rearranged by hand) is recognised by its hash, and removal names our tables after the commands the file actually holds, whichever copy of the app wrote them.
- **Rule.** Never put a Codex entry of ours ahead of a group already there.

### `config.toml` is edited as text, not parsed
- **Why.** A TOML rewrite would lose the user's comments and layout, and Core takes no TOML library.
- **Instead.** Only `[hooks.state."<key>"]` tables are read, added and removed, the one shape Codex writes itself; everything else in the file is kept byte for byte, and the file is written only when the trust changes it. A `state` written any other way (an inline table) stops the set-up before either file is written, saying to trust the hooks from Codex's `/hooks` screen: a second definition of the same key would make the file invalid for Codex. A file that is not UTF-8 is never written; removing the hooks then still takes them out of `hooks.json`, and says the trust was left.
- **Rule.** Never re-serialise `config.toml`, and never read an unreadable one as empty: the write would replace the user's whole file with our tables.

### `SessionEnd` and `Interrupt` time out at 3 s
- **Why.** Codex allows those two hooks 3 s at most: a larger value draws a warning at every Codex start and is hashed as 3, so a trust written for it would not match.
- **Instead.** Those entries are written with `timeout: 3`, the others with 5, and a Codex entry carries no `matcher` (Codex reads a missing one as match-all, and hashes the entry as written).
- **Rule.** Change a Codex entry's shape only together with the hash its trust is computed from.

### Codex reports a tool's end after the turn was aborted
- **Symptom.** A Codex session rolling for minutes after the user stopped it with Ctrl+C, until they quit Codex; with nothing to end it, it would have rolled for the 2 h backstop. Session `01a0d9e4`, 2026-09-25: `Interrupt` 18:52:34.701, `PostToolUse` Bash 18:52:47.372, then nothing but `SessionEnd` at 18:55:28.
- **Why.** Codex aborts the turn at once (`turn_aborted` in its rollout) but fires `PostToolUse` for the aborted call when that call's process finally ends, 13 s later here and minutes for a stubborn one, under the aborted turn's `turn_id`. `Stop` runs only on a normal completion, so no event ever follows to end the turn again. Seen once in seven aborts that day.
- **Instead.** Every line keeps the turn's id (`turn_id`, else `prompt_id`). An `Interrupt` or a verdict that the turn is over closes the turn the last main-agent event with an id named, and any event of a closed turn but a prompt or a session's start or end only refreshes liveness (`SessionStore.changesNothing`); a prompt that names a closed turn reopens it, or its own `Stop` and `Interrupt` would be ignored too; the interrupt also forgets the turn's helpers and background shells. A main-agent `PreToolUse` reopens a turn a verdict closed, never one an `Interrupt` closed: a new tool call is never the straggler of an aborted tool (the late line is a `PostToolUse`), and Claude Code reuses one `prompt_id` across consecutive turns (runs of two to four prompts sharing an id in the live journal), so a turn after a verdict whose prompt line was lost would otherwise stay dark throughout. A finish held behind helpers or background shells closes nothing, a rescued one included. A line with no id is quarantined for `K.abortQuarantineSeconds` after an `Interrupt` instead. A `Stop` does not close a turn: a Stop hook that blocks it keeps the same turn running.
- **Rule.** An event does not reopen a turn because it arrived: ask which turn it belongs to and how it was closed. A prompt opens one; a main-agent tool call reopens only a verdict's close.

### The daemon outlives every TUI, so the pid proves nothing
- **Symptom.** A Codex session rolling long after its TUI was closed, and every relaunch of the app replaying it back onto the strip; the process watch never fires and the startup prune keeps it. On 2026-09-25, five overlapping TUI sessions carried the same `claude_pid`, 40531, still alive 19 min after the last TUI had gone.
- **Why.** A TUI session's hooks are spawned by Codex's managed daemon (`codex app-server --listen unix:// --managed-daemon`, under `~/.codex/packages/app-server-daemon/`, parented by launchd), not by the TUI, and the hook records the nearest `codex` process in its ancestry: the daemon. One daemon serves every TUI of the user and outlives them all; it keeps a thread loaded for 30 min after its last subscriber, so a killed TUI does not even stop a running turn. The ChatGPT app's `codex` is a shared app-server of the same kind, alive for every thread of the app; only `codex exec` runs a process of the session's own. So a lost `Stop`, a lost `Interrupt`, an errored turn or a hook Codex stopped trusting cost the full 2 h backstop: nothing keyed on the pid can end a TUI session.
- **Instead.** The session's rollout is its transcript: every Codex hook names it (`transcript_path`), and its turn markers (`task_started`, `task_complete`, `turn_aborted`) balanced exactly across the 399 turns of that day. A quiet working Codex session is checked against the rollout's last 64 KB every 15 s and at launch (`SessionStore.codexCandidates`, `CodexRolloutTail`, `Engine.checkCodexRollout`), after Codex's daemon for a session it hosts (next entry): an end marker stamped after the last main-agent event, or naming its turn, ends the turn; a `task_started` with no end keeps it alive, counted from the rollout's last line. `ProcWalk.isCodexDaemon` tells a shared app-server (the daemon, or the desktop app's `codex`) apart by its arguments (`app-server`) or the daemon's install folder, and the startup prune keeps a session on it for the launch check to decide. A verdict found late is dated to the turn's end, so a finish found long after it earns no push. The kqueue on the daemon's pid stays: its death does end every session it hosted.
- **Rule.** A live pid proves a Codex session only when the pid is the session's own. Never end a Codex turn on the rollout's modification time: a tool that sleeps for 30 min writes nothing for 30 min. Read the rollout's types, turn ids and stamps only: the rest of each line is the conversation, and it is never logged.

### The daemon's protocol is undocumented and versioned
- **Symptom.** After a Codex update, a quiet TUI session is decided by its rollout only, and the log carries `Codex daemon not answering; using the rollout` (once per launch) or `Codex daemon reports an unknown thread status …` (once per status value).
- **Why.** The control socket is Codex's app-server protocol over a WebSocket on a unix socket, meant for Codex's own clients, with no documentation or stability promise: a token, a renamed method, a reshaped answer or a new status would each break the reading. It also answers for the TUI's threads only: a `codex exec` thread runs in its own process and a desktop-app thread in the app's own `codex app-server`, and the daemon, which reads any thread from disk, calls such a thread `notLoaded` and leaves it out of its list while it works.
- **Instead.** Fail closed. `CodexDaemonClient` sends only `initialize`, `initialized`, `thread/read` and `thread/loaded/list` (`CodexDaemonRPC.methods`), each call with 1 s overall from the moment it is asked, on a utility queue, non-blocking, the deadline checked before every read however many frames keep arriving. A ping or pong is read past, a notification or an answer to another id is skipped; a refusal, a timeout, an `error`, a close, a masked frame, a fragment, an over-long frame, an `initialize` answer without `userAgent`, a `thread/read` record that does not name the thread asked about, a loaded list with a `nextCursor`, or an answer of any other shape is nil (`WebSocketFrame`, `CodexDaemonRPC`, `CodexThreadRecord` pin the shapes), and the rollout decides. Only `notLoaded`, `idle` and `active` decide; any other status is the rollout's. Only a session whose pid is the managed daemon (`ProcWalk.isManagedCodexDaemon`, `--managed-daemon`) is asked; an answer is applied only while the session is still working with the same last main-agent event it had when asked, and a session with a question out is skipped by the periodic check.
- **Rule.** Never call any other method: the same socket starts turns, answers approvals and writes Codex's config. Never block the main queue on it or wait longer than 1 s. Never read a partial loaded list, or the daemon's word on a thread it does not host, as proof that a thread is not running: the turn would be ended under a live session.

### One agent can run the other
- A Codex started by Claude's shell tool fires Codex's hooks from a chain that holds both agents. `ProcWalk.classify` takes the nearest agent process, and the `--agent` flag names which one to look for. The pid recorded is that agent's, so the process watch and the startup prune ask about the right process (`ProcWalk.looksLike(_:pid:)`).

---

## Detecting Copilot

### A `preToolUse` hook that fails denies the tool
- **Symptom.** Every Copilot tool call refused, with nothing in MySidepulse's journal to say why.
- **Why.** Copilot's `preToolUse` is fail-closed: a non-zero exit, a crash or a missing binary denies the tool, and exit 2 denies for `permissionRequest` too. A hook file of ours that outlived the app (dragged to the Trash) would run a binary that is not there before every tool.
- **Instead.** Neither is subscribed: the seven events MySidepulse takes are all fail-open, and `postToolUse` carries the working signal. The hook exits 0 on every path, a flag it does not know or a payload it cannot read included, and prints nothing (JSON on stdout is read as a decision). The uninstall deletes the file.
- **Rule.** Never subscribe `preToolUse` or `permissionRequest`, and never let `mysidepulse hook` exit non-zero.

### `sessionStart` comes after the first prompt
- **Symptom.** A Copilot turn dark from its first second: the prompt set it working, and the start set it idle a few milliseconds later.
- **Why.** Copilot fires `sessionStart` lazily, with the first prompt and after `userPromptSubmitted`. An interactive Copilot quit before any prompt fires a `sessionEnd` for a session that never started.
- **Instead.** A Copilot `SessionStart` changes no state (`SessionStore.apply`). A `SessionEnd` for a session never seen changes nothing either.

### A subagent's prompt and stop carry the subagent's id
- **Symptom.** A Copilot turn green while it still runs: its subagent's `agentStop` read as the turn's own finish, under a session no one started.
- **Why.** A `task` subagent's own `userPromptSubmitted` and `agentStop` carry the subagent's id, not the parent's, and the parent's `transcriptPath`; the id has no folder under `~/.copilot/session-state/`.
- **Instead.** The hook writes no line for a Copilot session without its folder there, `$COPILOT_HOME/session-state` when the hook's environment sets it, as long as that root exists (`CopilotSessionState.keeps`). The subagent is not followed at all: `subagentStart` names no subagent id, so it is not subscribed. The same stop is mirrored into the parent's `events.jsonl`, as a `hook.start` whose `data.input.sessionId` is the subagent's, before the parent's own with the parent's id (session `fe073462`, 2026-09-25): the reader counts an `agentStop` mirror as the turn's end only when its payload names the session read (`CopilotTranscriptTail`).
- **Rule.** Never key a Copilot session on an id the session state does not know, and never read an `agentStop` in a session's file without asking whose it is.

### Answers, interrupts and failed turns fire nothing
- **Symptom.** A Copilot turn stopped with Ctrl+C, or whose model call gave up, rolling on until the Copilot process exits or the 2 h backstop; a permission prompt cancelled with Ctrl+C left amber, saying "needs you" for a turn the user cancelled; a permission prompt approved for a `bash` command left amber, saying "needs you", for the minutes the command then ran.
- **Why.** Approving a permission or answering `ask_user` fires no hook: Copilot writes `permission.completed` in the session's `events.jsonl`, with no hook between it and the prompt's `permission.requested` and `notification` hook, and the next hook, the tool's `postToolUse`, comes only when the command ends. Two prompts in a row write `permission.completed` and the next `permission.requested` 2 ms apart, still with no hook between. The file's last line cannot tell an answered prompt from an open one: the wait's own `notification` hook writes a `hook.end` after the wait began either way. Ctrl+C and Esc Esc fire nothing, and a failed model call fires only `errorOccurred`, whose `recoverable` flag is true on retries that then succeed too (three connect timeouts in session `fe073462` each fired one before the turn went on), so no hook tells a failed turn apart. `agentStop` fires on a natural end only.
- **Instead.** The session's `events.jsonl` records each: `abort` for the interrupt, `session.error` for the failure (the retried errors write only their hook's mirror, and only the last failure writes a `session.error`), `session.shutdown` for the session closing, and a `hook.start` mirror of the session's own `agentStop` for the natural end. A quiet working Copilot session is checked against the file's last 64 KB every 15 s and at launch, like a Codex rollout (`SessionStore.copilotCandidates`, `CopilotTranscriptTail`, `Engine.checkCopilotTurns`): an end marker stamped after the last main-agent event ends the turn, dark for an abort or a close, green with its push for the `agentStop`, `waiting(error)` with its push for the `session.error` (`SessionStore.failTurn`, journaled as `turn-failed`); a `session.shutdown` looks back for the turn's own end, which says how the turn ended, but a shutdown stamped after the last main-agent event ends the turn whatever older end precedes it (a prompt closed before Copilot wrote its `user.message` finds the previous turn's end, and is dark); a step of the turn at work keeps the session alive from the file's last line. A session waiting on a permission or a question is checked too, every 15 s from the moment the wait began, with no quiet gate, since Copilot writes the answer within milliseconds of the click (`SessionStore.copilotWaitCandidates`, `CopilotTranscriptTail.waitDecision`, `Engine.checkCopilotTurns`), and the file's latest turn marker decides, by its own type and stamp: an `abort` stamped after the wait began is the prompt cancelled (`SessionStore.abandonWait`, dark, journaled as `turn-abandoned`); with the turn at work, a latest permission line that is `permission.completed`, stamped after it, is the prompt answered (`SessionStore.dialogAnswered`, back to working with the push disarmed, journaled as `dialog-answered`, logged `wait answered: Copilot session …`); a latest `permission.requested` is a prompt still open, and a tool called beside it finishing is no answer; anything else leaves the wait standing. The only interrupt seen on this Mac was Ctrl+C at an open permission prompt (session `fe073462`).
- **Rule.** Never end a Copilot turn on `errorOccurred`, on `assistant.turn_end` (it ends every model call) or on the file's modification time. Never read a wait as answered from the file's last line, its modification time or any step of work: only the latest permission line's type and its own stamp say it. Never subscribe `preToolUse` or `permissionRequest` to learn that a prompt was answered: a failing one denies the tool (*A `preToolUse` hook that fails denies the tool*). Read the lines' types, stamps, and a `hook.start`'s hook name and session only: the rest of each line is the conversation, and it is never logged.

## Detecting OpenCode

### OpenCode 2 is not the OpenCode its documentation describes
- **Symptom.** A plugin written from opencode.ai/docs/plugins that never runs, with one `failed to load plugin` line in `~/.local/share/opencode/log/opencode.log`.
- **Why.** The public documentation still describes the v1 API (`export const X = async ({ client, $ }) => ({ event })`, `session.idle`, `experimental.hook`). OpenCode 2 loads `export default { id, setup(ctx) }` only, publishes no `session.idle` or `session.status`, and has no `experimental.hook`.
- **Instead.** The plugin is the v2 shape, reads `ctx.event.subscribe()`, and ends turns on `session.execution.succeeded`, `.failed` and `.interrupted`. It was run against a real 2.0.17 server before it was adopted.
- **Rule.** After an OpenCode update, the canary is OpenCode sessions absent from the journal while OpenCode runs, and a `failed to load plugin` line in its log.

### One plugin instance per open folder, each seeing every folder's events
- **Symptom.** Every OpenCode event journaled two, three or more times.
- **Why.** The server loads a global plugin once per open folder, and each instance's event stream carries the events of every folder the server has open.
- **Instead.** The instances share `globalThis`, and the first to see an event id forwards it; the others skip it. The plugin runs its hooks one at a time, in event order.

### The server hosts every session, so its pid proves nothing about one
- **Symptom.** An OpenCode session that stays on the strip after its TUI or `opencode run` has quit.
- **Why.** The TUI, `opencode run` and OpenCode.app are clients of one server, `opencode serve --service`, parented by launchd; a turn runs on in it when its client quits, and the hook's parent is the server, not the client. The server has no tab either.
- **Instead.** The session records the server's pid (the one the plugin names, when it is an OpenCode ancestor of the hook) and no tab; its exit forgets every session it hosted. A turn always ends in one of the three terminal events, so no transcript is read. A standalone server under its client dies with it, before its last events reach the plugin: the process watch ends those sessions.
- **Rule.** Never end an OpenCode session because a client quit.

### `permission.asked` fires for permissions granted at once
- **Symptom.** An amber blink, or a push, for a permission nobody was asked.
- **Why.** A permission granted by a rule or by `--auto` is still asked and replied to, about 3 ms apart.
- **Instead.** The settle (`K.alertSettleSeconds`) keeps a wait that short off the strip, and the reply disarms its push (`OpencodeTests`).

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
- **Instead.** Generated, never derived from the machine. `config.json` is `0600`, re-applied after every save because an atomic write replaces the inode. `status`, `doctor`, the Health page and the log carry only the first six characters; the status reply has no field that could hold the raw topic. Only `mysidepulse notify` and the Notifications page's reveal print it.
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

This is every app's trap: `docs/shared/pitfalls.md`, **L2**.

### Bootstrapping the agent does not put the running app under it

This is every app's trap: `docs/shared/pitfalls.md`, **L3**. Here `doctor` says `agent installed, but this process was not started by it: no crash restart`, and a hand-over that fails opens the bundle again.

### Killing a KeepAlive job is asking launchd to restart it

This is every app's trap: `docs/shared/pitfalls.md`, **L4**.

### `launchctl disable` is permanent, and nothing ordinary undoes it

This is every app's trap: `docs/shared/pitfalls.md`, **L5**. `UninstallPlanTests` pins the helper against it.

### The bundled `.icns` is a flat stand-in, not the icon

This is every app's trap: `docs/shared/pitfalls.md`, **I2**.

### A legacy agent is filed under its signing team unless the plist names the app

- **Symptom.** System Settings › General › Login Items lists the agent as "Wooflab" with a blank icon, not as MySidepulse.
- **Why.** Background Task Management records a plist in `~/Library/LaunchAgents` as a `legacy agent` and gives it a parent when the record is created: the app listed in `AssociatedBundleIdentifiers`, or the signing team when that key is missing (`sfltool dumpbtm`: `Parent Identifier: Wooflab`). Adding the key to an existing record updates the icon at the next write of the plist but **not the parent**, so the row keeps the team's name. Deleting the plist while the job is still loaded does not drop the record either.
- **Fix.** `LoginService.install()` writes `AssociatedBundleIdentifiers = [io.mysidepulse.app]`, so a new record gets `Parent Identifier: 2.io.mysidepulse.app` and the row reads MySidepulse, with its icon. A record created without the key keeps "Wooflab" until it is created again: `mysidepulse autostart off`, `launchctl bootout gui/$(id -u)/io.mysidepulse.agent`, wait until `sfltool dumpbtm` no longer lists `8.io.mysidepulse.agent` (about 30 s), then open the app, run `mysidepulse autostart on` and let the next launch hand the app over.

### An app started by `open` is nobody's job

This is every app's fact: `docs/shared/macOS.md` § Launch, and `docs/shared/pitfalls.md` **L3**. Here `doctor` checks supervision, not registration: only `XPC_SERVICE_NAME == io.mysidepulse.agent` proves the running process would be restarted.

### `launchctl bootout` kills the process running as the job

This is every app's trap: `docs/shared/pitfalls.md`, **L6**.

### `MySidepulse` and `mysidepulse` are one file

This is every app's trap: `docs/shared/pitfalls.md`, **B4**. Here the GUI binary is `MySidepulseApp`.

### The app's name is an identity in six places
- **Symptom.** After a rename: two apps drive the strip at once, every hook fails, the ntfy topic is gone, macOS asks for its permissions again, and alerts already seen relight.
- **Why.** The name is not a label. It is the bundle id (TCC grants, `UserDefaults`), the launch agent's label, the `Application Support` directory (`config.json`, the journal), the hook command written into `~/.claude/settings.json` and the marker `HookConfig` recognises its own entries by, the `MySidepulseAck` event name inside the journal, and the `MYSIDEPULSE_*` variables in the user's shell.
- **Instead.** The move from the former name, SidePulse, was a takeover script run first by `make install` (`scripts/takeover-former-install.sh`, in git history; deleted once this Mac had moved over). In order: uninstall the former install's hooks with that install's own CLI, boot its agent out before killing it, move its support directory across (keeping `config.json` at `0600`), rename the acknowledgement lines in the moved journal.
- **What did not need doing.** Restarting the Claude Code sessions that were open. Claude Code (2.1.278) re-reads `settings.json` while it runs: two sessions open across the takeover wrote through the new hook path within seconds of `install-hooks`. Hooks are not a snapshot taken at session start.
- **Rule.** A rename is a migration. The user's own `.zshrc`, keyboard shortcuts and `PATH` symlink are outside what an install may touch: list them, do not edit them. (The app writes its own delimited block into `.zshrc` only when the user presses `Set up…` in Settings.) The hardware keeps its name — `SidePulseDot…` / `SidePulsePro…` volume names are how the LED count is read.

### GitHub answers 404 for "no release" and for "not yours to see" alike

This is every app's trap: `docs/shared/pitfalls.md`, **U7**.

### A download task succeeds on a 404

This is every app's trap: `docs/shared/pitfalls.md`, **U8**.

### A helper started by the app dies with the app

This is every app's trap: `docs/shared/pitfalls.md`, **U1**.

### Everything that can refuse an update has to happen before the quit

This is every app's trap: `docs/shared/pitfalls.md`, **U2**. Here the helper also starts the new copy through the launch agent when the old one was its job (`macOS.md` § launchd).

### A new version that is gone two seconds later has crashed, or has been quit

This is every app's trap: `docs/shared/pitfalls.md`, **U4**.

### A helper that gives up while the app may still quit

This is every app's trap: `docs/shared/pitfalls.md`, **U5**. Here the clock is `K.updateStallNoticeSeconds`.

### `ps` lists the path the kernel ran, not the one the app was installed at

This is every app's trap: `docs/shared/pitfalls.md`, **U6**.

### A new `config.json` key can wipe the config
- **Symptom.** After an update every setting is back to default — including a freshly minted ntfy topic, orphaning the phone.
- **Why.** Synthesised `Decodable` throws on a missing non-optional key, and `load()` treats any failure as "no config".
- **Rule.** Every key added after the first release is optional.

### SwiftPM records the deployment target as the SDK, and Liquid Glass follows it

This is every app's trap: `docs/shared/pitfalls.md`, **B3**.

---

## Hooks, CLI, shell

### The hook runs inside every Claude Code turn
- **Rule.** It must never block and never exit non-zero, in any agent's turn (Copilot denies a tool whose `preToolUse` hook fails). It drains stdin to EOF even past its 8 MB cap (or Claude Code's write blocks), spawns nothing, and swallows every error. Journal lines are capped at 4096 bytes so concurrent `O_APPEND` writes cannot interleave.

### A hook payload is untrusted input
- **Symptom (potential).** A Claude Code session ended by an `Interrupt`, an event Claude Code does not have; a Codex line carrying a `Notification` Codex never sends; a line under one of the app's own names (`MySidepulseVerdict`, `MySidepulseAck`) that no check wrote.
- **Why.** `hook_event_name` is the payload's to say, and the trim used to take any name the journal knows, whichever agent's hook it ran for.
- **Instead.** The hook says which agent speaks, and `Trim.journalEvent(fromHookPayload:agent:loggedAt:)` passes only that agent's own events (`HookConfig.events(for:)`: Claude Code's 15, Codex's 12), in Claude Code's spelling or the snake-case one Codex's configuration uses. Any other name is a `ParseError` line that keeps the payload's first bytes and none of its fields. Copilot's and OpenCode's trims map only their own events onto the journal's names.
- **Rule.** A payload cannot forge another agent's `Interrupt` or a verdict. Which events count is the hook's to say, never the payload's.

### `argv[0]` has no directory when the CLI is found on `PATH`
- **Symptom.** `install-hooks` writes a hook command that resolves nowhere.
- **Instead.** `_NSGetExecutablePath`, symlinks resolved. After writing, `install-hooks` counts the events that actually carry the command and reports "N of 15", exiting 1 if a shape it refuses to rewrite kept one out.

### `mysidepulse run` must not ignore signals
- **Why.** `SIG_IGN` is inherited through `posix_spawn`, which would break the child's own Ctrl-C.
- **Instead.** Ctrl-C hits the whole foreground group; the wrapper dies with its child and the app's pid watch clears the job.

### The zsh snippet is a text no compiler checks
- **Instead.** `ShellInitTests` runs the generated snippet in a real interactive zsh against a stub CLI. That test caught two real bugs; comparing the string with itself proves nothing.
- **Rule.** `precmd` captures `$?` first and returns it, or later hooks and prompt themes lose the exit status. The same discipline applies to the notification copy (`AlertCopy`) and the LED program text.

### An agent's tool shell loads the snippet
- **Symptom.** A command an agent runs shows as a job: violet beside the agent's colour, and a job that outlives the agent's session. Seen with KoffeeLid on this Mac: Codex's shell tool under its app-server daemon (`~/.codex/packages/app-server-daemon/…/bin/codex`), and an OpenCode tool's `zsh -c … sleep` under `opencode serve --service`, still running after a Ctrl+C in OpenCode's window.
- **Why.** An agent's shell tool can run an interactive zsh, which reads `~/.zshrc` and so the snippet; and OpenCode's server, not its window, owns a tool's processes, so interrupting the session does not end them.
- **Instead.** `Engine` drops a `job-begin` whose shell has an agent's process on its chain (`ProcWalk.hostingAgent(in:)`), logging `job ignored: shell <pid> runs under <agent>` once per shell: the agent's own session is what shows its work.
- **Rule.** Do not filter by environment variables (each agent sets its own, none is promised) or in the snippet (it cannot see the process chain cheaply), and do not count a desktop app's window process as the agent, or a terminal pane the user opens in that app stops counting.

### `exec zsh` and `source ~/.zshrc` end the running job
- **Symptom.** Right after `exec zsh` or `source ~/.zshrc` (the natural thing to type after Set Up Terminal Hook), the strip turns violet 5 s later and stays on a job nobody runs, until the next command in that shell, the shell's exit or the 2 h backstop.
- **Why.** `preexec` began a job (labelled `exec` or `source`); then the snippet ran again, inside the `source` command or in the new image under the same pid, and its `typeset -g _mysidepulse_job=` at load emptied the job variable, so `precmd` ended nothing. The shell is alive and watched, so the kqueue never fires.
- **Instead.** The snippet declares `_mysidepulse_job` without assigning it (`(( ${+_mysidepulse_job} )) || typeset -g _mysidepulse_job=`), and an interactive shell loading it sends `job end --id zsh-$$ --exit 130` before it registers its hooks, which ends the job an earlier image of that pid began, as a cancellation, so the orphan never turns into an outcome. `exec` is a skipped prefix and an interactive `zsh` a skipped program, so `exec zsh` begins nothing by default. `ShellInitTests` re-source the snippet and `exec` a shell in a real `zsh -f -i` and pin the exact calls.
- **Rule.** Assign none of the snippet's state at load, and keep the load's `job end` a cancellation.

### A shell at its prompt is the truth about a job
- **Symptom.** A `job end` that never arrived (a control-socket call that timed out on a busy main queue, the CLI missing during an install or an update, a snippet re-read mid-command) left the strip violet until the next command in that shell; a timer on the job, the other way round, took the colour off a three-hour build while it ran.
- **Why.** The app knows only what the hooks said. The shell knows whether it runs a command: at its prompt it owns its terminal's foreground process group, and while a command runs that group is the command's (`docs/macOS.md` *Process inspection*). But a shell's children are not only its commands: Powerlevel10k keeps a `gitstatusd` child beside every interactive shell on the owner's Mac, from the shell's start, so "the shell has a child" is always true there, and a rule built on it would hold a lost end until the shell exits.
- **Instead.** `Engine.probeJobs` asks each running job's pid at every `sync()`, from the job's begin, at least every `K.jobProbeSeconds` (15 s) and again `K.jobPromptSettleSeconds` (5 s) after a first sighting at the prompt: `ShellJobLiveness.probe` builds the probe from `ProcWalk.info` and `ProcWalk.childStartTimes`, counting only a child started after the job began, and `ShellJobLiveness.judge` decides. A pid gone, or held by a process started after the job began (a recycled pid), clears the job; a process that is no longer a shell (it `exec`'d into the program; `exec` keeps the start time) keeps it for the kqueue; a shell at its prompt with no child of the job, seen so twice 5 s apart, clears it; anything else keeps it, with no time limit. Each clear logs `job <id> ended without a hook (<reason>)` and leaves no outcome. Only a running job without a pid is dropped after `K.jobStaleSeconds`.
- **Rule.** Do not time out a job whose shell can be asked, count every child of the shell, or clear a job on one sighting of the prompt: the shell owns its terminal for milliseconds between `preexec` and the fork, and between two commands of one line. Known false negative: a builtin that blocks (`wait`, `read`, a loop of builtins) keeps the group and forks nothing, so its job is cleared 5 s after the first probe that sees it, which comes up to 15 s after the builtin began: 5 to 20 s in all. Known false positive: a lost end in a shell that has started a background child since the job began holds until that child exits.
- **Rule.** Do not put a shell's name on the skip list as a plain skip: `bash build.sh` and `sh install.sh` are real work. The snippet skips `zsh`, `bash`, `sh`, `fish`, `dash` and `ksh` only when every word after the name is a flag.

---

## Open issues

Known, bounded, and left alone.

- **Cancelling a standing dialog with Esc leaves its amber up** until the next prompt or the 2 h backstop: the abort fires no hook, and at a dialog "at rest" and "waiting for you" look the same from outside.
- **A subagent's question or plan wait is not cleared by that subagent's next event** — only `waiting(permission)` is (`SessionStore.apply`, subagent branch). The answered-dialog rescue clears it within ~15–30 s.
- **A subagent quiet for over 4 minutes releases a hold while it still runs.**
- **A daemon-hosted session has no tab to scope to**, so it is acknowledged by any input anywhere. And because the daemon shares the user's session id, a `SessionEnd` from *any* process with that id deletes the record while the daemon's process may still run; it reappears on its next event.
- **The `idle_prompt` lost-Stop rescue writes no log line**, unlike the registry rescues.
- **Jobs are not journaled**: a restart forgets them and their acknowledgements. A `mysidepulse run` wrapper killed while its child survives leaves the command running unlit.
- **The zsh hook labels a compound command by its first head** (`cd repo && npm run build` shows as `cd`), and an interactive program that is not on the skip list (a REPL, `git log` in its pager, `docker exec -it`) shows for its whole life.
- **A subshell that re-reads the snippet ends its parent's job** (`(source ~/.zshrc; make)`): it is still interactive and its `$$` is the parent's.
- **The zsh hook's prefix rules know only short flags and a fixed list of the ones that take an argument.** `sudo --user root vim` and `sudo -nu root vim` take `root` as the head (a long flag's argument, and flags run together, are not skipped); `caffeinate -t 3600 make` is labelled `3600`; `time (make)` and `time { make }` begin nothing, since a prefix followed only by a group reads as a line of prefixes alone.
- **`doctor`'s strip check never fails**, and its auto-start check fails when `Open at Login` is deliberately off — fairly, since that also turns off crash restart.
- **`reconcile()` re-stats every known mount** when an unrelated disappear arrives without a description, so a transient stat failure can briefly report a live strip as gone.
- **Wake forces no rescan**, and the safety-net timers pause during sleep.
- **A transition tail's chords are one shape the strip has not been sent before**: a per-LED crossfade behind a delay (`4:#3a0c11 120ms 40ms`), which the vendor's grammar lists (`duration delay`) but this app had never written. A refused shape shows as six red blinks at the moment a zone opens over the roll. Every other tail shape is one the programs already use.
- **A Codex turn that ends in an error has no known rollout marker.** `Stop` runs only on a normal completion, and no errored turn has been seen in a rollout: if it ends on `task_complete` it shows green with a push, as a lost `Stop`; if it ends on nothing, a TUI session goes dark once Codex's daemon says the thread is idle, but a `codex exec` or desktop-app session, or any session while the daemon is down, keeps rolling on the `task_started` until 2 h after the rollout's last line. Which status the daemon gives an errored thread is unobserved.
- **A Codex run under a `CODEX_HOME` other than `~/.codex`** has its rollout refused, since only `~/.codex/sessions/` is trusted, so its quiet turns decide nothing and a lost end costs the 2 h backstop.
- **A Codex turn that wrote more than 64 KB since its `task_started`** has no marker in the tail the app reads (53 of 744 gaps between markers on 2026-09-25), so a quiet check decides nothing for it until its end marker is written; its 2 h backstop counts from its last hook event meanwhile.
- **Whether Codex fires `PreToolUse` for `request_user_input` is unobserved**, so a Codex question may show nothing until the turn ends. A permission request has its own event and shows amber.
- **The shared roll's programs and tails have not been seen on the strip**: the two-pass loop, the one-pass roll of three or four agents, the by-LED split, the pass-end handover and the recolour tail are pinned by text and by the sweeps, and judged by nobody's eye yet. Neither have Copilot's `#0e5cff` and OpenCode's `#ff0043`: whether they read apart from Codex's `#0a00ff` and Claude's `#ff374a` on the strip is unseen.
- **Codex sessions hosted by the ChatGPT app** are acknowledged at app level: the app is their host and they hold no tab. The app-server daemon's sessions have no host at all and acknowledge on any input.
- **A Copilot turn ended by Ctrl+C, Esc Esc or a failed model call is read from its `events.jsonl` within about 35 s** (the 20 s quiet gate and the 15 s recheck), **and a Copilot prompt answered or cancelled within about 15 s** (the recheck, with no gate), not at once: no hook reports them. Until then an interrupted turn rolls, a cancelled or answered prompt stays amber, and a failed turn rolls before its amber.
- **A `/compact` after a Copilot turn whose `agentStop` hook was lost** writes about 95 KB of model lines after the turn's end, which pushes it out of the 64 KB the app reads: the check decides nothing, and the turn rolls until the next hook, the process's exit or the 2 h backstop.
- **A Copilot run under a `COPILOT_HOME` other than `~/.copilot`** has its `events.jsonl` refused, since only `~/.copilot/session-state/` is trusted and the app, started by launchd, cannot see the variable: its quiet turns decide nothing.
- **A `copilot -p` finish is gone at once**: Copilot fires `sessionEnd` (`complete`) right after every `-p` turn's `agentStop`, and a `SessionEnd` forgets the session, as it does for every agent.
- **A bare hook reads its agent from its ancestry**, so a Claude Code the walk cannot recognise (one run through an interpreter) under a Copilot or an OpenCode is journaled as that agent's. Every hook MySidepulse installs but Claude Code's carries `--agent`, which always wins.
- **A standalone OpenCode server inside OpenCode.app is its session's host**, as the first bundle in the chain always is: while OpenCode.app itself runs, such a session's alerts are acknowledged by bringing OpenCode.app forward, not the terminal. The shared server is parented by launchd, has no host, and acknowledges on any input.
