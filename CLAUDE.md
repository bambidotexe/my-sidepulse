# MySidepulse — CLAUDE.md

The operating manual for an agent working in this tree. Read it whole before the
first edit.

## What this project is

MySidepulse is a macOS menu-bar app that drives a **SidePulse** LED strip — an
LED bar in SD-card form factor that sits in the Mac's card slot — so that three
things are visible at a glance: an agent is **working** (a rolling wave in the
agent's colour: red for Claude Code, blue for Codex, another blue for GitHub
Copilot, another red for OpenCode; one colour per pass when several work and
the passes fit the strip, one per LED when they do not), an agent has **finished** (a green breath), an
agent **needs you** (an amber double blink). All four agents — Claude Code,
Codex, GitHub Copilot CLI and OpenCode — are followed through their own hooks
or plugin, each set up on its own by `install-hooks`, `make install` or the
System page. Finished and needs you are one colour for
every agent, because they say the Mac wants the user, not which agent does. When
nobody is at the machine the same finished / needs-you alerts go to a phone
through **ntfy**, titled with the agent's name. Around that core it shows
terminal jobs (`mysidepulse run`, zsh hooks), the battery for a few seconds when
the power cord moves, a red breath at ≤ 15 % on battery, and a few decorative
effects.

How it knows: Claude Code runs `mysidepulse hook` on 15 hook events and Codex
runs `mysidepulse hook --agent codex` on 12; GitHub Copilot CLI's own hook file
runs `mysidepulse hook --agent copilot --event <name>` on 7 events, and
OpenCode's own plugin runs `mysidepulse hook --agent opencode` on every event
it forwards. Each hook appends one trimmed line to a journal, saying which
agent; the app follows the journal, folds it into a per-session state machine,
picks one display state, and writes a small **text program** into `LEDS.LED`
on the strip's mounted volume. The strip is a closed device: no firmware here,
no USB or serial channel, no read-back — files on a volume are the whole
protocol. Read-only side channels cover what the hooks miss: for Claude Code,
its own process registry and the transcript tail; for Codex, its managed
daemon's control socket (`thread/read`: does the thread still run?) for the
TUI's sessions, and the session's rollout, whose turn markers say whether a
quiet turn runs, finished or was aborted (the pid a Codex session records is a
shared app-server, Codex's daemon or the desktop app's, which proves nothing
about the session); for Copilot, its own `events.jsonl`, checked the same way
for a quiet turn and for an open wait cancelled with Ctrl+C. OpenCode needs no
such check: every busy period ends in one terminal event.

Two names, never to be confused: **SidePulse is the hardware** (its volumes are
named `SidePulseDot…` / `SidePulsePro…`, which is how the LED count is read);
**MySidepulse is this app** (`MySidepulse.app`, CLI `mysidepulse`, bundle id
`io.mysidepulse.app`). The repository is `my-sidepulse`.

Everything it shows and everything it pushes is in English or French, picked
from the system language at launch, with English the fallback for every other
language; the `mysidepulse` CLI is English always, by rule.

Swift, SwiftPM (tools 5.10), macOS 26+, no Xcode project, no third-party
dependency. One app process plus a CLI in the same bundle; signed with the
Wooflab team's Developer ID and notarized, not sandboxed. A personal tool by
and for one user, on one Mac. It looks for a newer release on GitHub at launch
and once a week, announces one with a notification on this Mac, and installs
it on a click: a window fetches and checks the release while the app runs,
and **Install and Relaunch** swaps the bundle once the app has quit. A release
is `scripts/release.sh`'s signed, notarized disk image attached to a GitHub
release. **The check is anonymous, so the repository has to be public for it to
see anything**: a private one reads exactly like no release at all.

## The family, and the shared documents

This app is one of the macOS apps under `~/Projects` that share one shape; the `macos-map` skill lists
them and routes a task to the right skill. **`docs/shared/` is a synced copy of
`~/Projects/macos-app-template/docs/shared/`, and it is never edited here**: a change goes in the template
and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh` replicates it to every app. A trap, a
convention or a platform fact that applies to more than this app goes there, not in this app's own
documents. `docs/shared/workflow.md` is the change workflow every app of the family follows and
`docs/shared/pitfalls.md` the traps they all share; the sections below are this app's own statement of the
workflow, with its own file names, and this app's own traps.

## Read first

| File | What it is |
|---|---|
| `docs/README.md` | The index: which document answers which question, and how to start. |
| `docs/functional.md` | **The authority on behaviour.** Every state, rule, delay, command and setting, with the numbers. Kept in sync with the code by the workflow below. |
| `docs/architecture.md` | The four targets, the status / device / notification layers, `Engine.sync()`, who watches what, threading, the control socket, persistence, the hook path, build. |
| `docs/device.md` | The strip as the host sees it and the exact program text for every display state. Read it before touching `LedProgram`, `LedEffects` or `LedWriter`. |
| `docs/macOS.md` | The platform boundary: DiskArbitration and the eject guard, sleep, presence inputs, process inspection, permissions, launchd, bundle and signing, logging. Read it before designing on a platform assumption. |
| `docs/pitfalls.md` | What looks right and is not — card slot, LED protocol, Claude Code detection, acknowledgement, ntfy, launchd, hooks — and the open issues. The only place that records approaches that failed. |
| `docs/_audit.md`, `docs/_coverage.md` | The September 2026 audit: what was read, deleted and deliberately kept. A record, not a rulebook. |

## Who decides what

**Functional is the owner's. Technical is Claude's.** Stated by the owner on
2026-08-26 and binding on every session after it.

The whole point of this project, in the owner's words: **know when Claude is
working, when Claude has finished, and when Claude needs their attention.**
Everything else in here — battery, jobs, effects, the strip's other rungs —
exists around that and must never come at its cost. When a change would make
one of those three states slower, wrong or ambiguous, it is wrong, however
good the reason.

What belongs to the owner — ask, and only about these:

- What the strip should *mean*. A new state, a state retired, a rung moved in
  the ladder, one situation deliberately shown as another.
- What reaches them off the machine: when a push fires, what it says, whether
  it fires at all.
- Anything with a cost outside this repo — spending money, publishing, posting,
  touching another project, anything not undoable.

What belongs to Claude — decide it, do it, do not raise it:

- Every technical choice: architecture, data structures, algorithms, naming,
  dependencies, file layout, tests, refactors.
- **Bugs. See one, judge it, act.** Fix it if it is worth fixing; leave it and
  write it under Open issues in docs/pitfalls.md if it is not. Do not present
  a menu of fixes and do not ask which to take. A wrong call that is
  documented beats a question.
- Every constant that is derived rather than felt — timings, thresholds,
  windows, retries. Calibrate from evidence (usually the journal) and record
  the evidence next to the value. The LED *colours* stay the exception: they
  are calibrated by eye on hardware, so they are functional, not technical.
- Whether a flaky test, a rough edge or an inefficiency is worth the time.
- Committing finished work. Verify it, then commit it — no permission needed,
  and no question about it. `main` is the working branch; that is what the
  history has always done.

Two things this does not license. Do not quietly narrow the job — if part of
a task is dropped, say so and why. And do not let "technical" swallow a
functional change: a fix that alters what the strip *means* is the owner's
call even when it arrives dressed as a bug fix.

Verification is not optional just because the decision is Claude's. This is a
non-critical personal tool, so the bar is "prove it works", not "prove it can
never break": tests green, and where the change touches live behaviour, replay
the real journal or check the strip. Say plainly what was verified and what
was not.

## Changing behaviour — the workflow

Every change to what the app does follows these steps, in this order. A change
that skips one is not done.

1. **Find the rule.** Read the section of `docs/functional.md` that governs the
   behaviour. It is the authority: what it says is what the app is supposed to
   do today.
2. **Check for a conflict.** If the request contradicts a rule that is written
   there — a number, a trigger, an order, a precedence, a "never" — **stop and
   ask the owner whether the existing rule is overruled, quoting the rule.** Do
   not guess, do not implement both, do not add an exception beside the old
   rule. This holds even when the request looks obviously intended: the owner
   may not remember the rule, or may want it kept. A request that only adds
   behaviour no rule covers needs no question. A purely technical change needs
   none either — see "Who decides what".
3. **Change the code**, in the layer that owns it: `MySidepulseCore` for
   anything decidable from values alone (it never reads a clock and never does
   I/O); `MySidepulsePlatform` for the one call that touches a file, a socket, a
   process or the network; `MySidepulseApp` / `MySidepulseCLI` for wiring, UI
   and commands. A comment states the present rule, never the history of the
   change.
4. **Update `docs/functional.md` in the same commit.** Replace the old rule with
   the new one. Never keep an outdated rule — not as a note, not as "it used to
   be", not as a crossed-out line. A changed number changes in its section
   *and* in the §13 table. If the change touches how the app is built, the
   strip's protocol, a platform fact or a trap, update `architecture.md`,
   `device.md`, `macOS.md` or `pitfalls.md` the same way, and `README.md` if it
   says anything about it.
5. **Verify.** `swift build`, then `swift test` and read **both** summary lines.
   A pure rule gets a test in `MySidepulseCoreTests`; an I/O behaviour gets one
   in `MySidepulsePlatformTests`. Replay the live journal (see Commands) for
   anything in `SessionStore`. A change to LED program text is verified **on
   the strip** — the exact-text tests are necessary and are not the proof.
6. **Commit per task** on `main`: conventional commits (`feat|fix|build|docs(scope): …`), the attribution
   trailers from the session's system reminder, files staged by path. Never
   touch `VERSION` in `scripts/make-app.sh`: only a release moves it
   (`scripts/publish.sh`, below), in a commit of its own titled
   `build(version): the tree moves to X.Y.Z`.

The sync rule in one sentence: **the code and `docs/functional.md` describe the
same app at every commit, and the newer of a request and a written rule wins
only after the owner has said so.**

### Where a change usually lands

Paths are under `Sources/`; `Core` = `MySidepulseCore`, and so on. § numbers
are `docs/functional.md`.

| To change… | Edit | Then document in |
|---|---|---|
| what a hook event means; a state or a transition | `Core/SessionStore.swift` (`apply`, `set`, `applyStopVerdict`), `Core/Event.swift` — pinned by `SessionStoreTests`, `GoldenReplayTests`, `CodexTests` | §4 |
| an agent: which there are, its colour, how its sessions are told apart, what its events mean | `Core/Agent.swift` (`AgentKind`: Claude, Codex, Copilot, OpenCode; `Agents`), `Core/LedPalette.swift` (`rollColors`), `SessionStore.apply` (`Interrupt`, `request_user_input`), `Platform/ProcWalk.swift` (`agent(of:)`, `classify(_:agent:)`, `isCopilotPath`, `isOpencodePath`), `Platform/HookCommand.swift`, `CLI/CLIMain.swift` (`hook --agent`) — `CodexTests`, `CodexPlatformTests`, `CopilotTests`, `OpencodeTests` | §1, §3, §4, `pitfalls.md` *Detecting Codex*, *Detecting Copilot*, *Detecting OpenCode* |
| holds, expiry, the settle, any session timer | `SessionStore.tick` and `nextDeadline` (every timer needs both), `Core/Constants.swift` — `TimerTests`, `SettleTests` | §4, §3 *Settle*, §13 |
| the rescues when hooks say nothing | `App/Engine.swift` `checkAbandonedTurns`, `checkCodexTurns`, `checkCopilotTurns`, `daemonAnswered`, the launch check in `start` / `finishLaunch`; `Platform/ClaudeProcessRegistry.swift`, `TranscriptTail.swift`, `CodexRollout.swift`, `CodexDaemonClient.swift` (`CodexDaemonClientTests`, a fake daemon), `ProcWalk.isCodexDaemon` / `isManagedCodexDaemon`, `Platform/CopilotTranscript.swift`, `Platform/FileTail.swift` (shared by `CodexRollout.read`); `Core/CodexRolloutTail.swift` (the rollout's verdict and decision, which paths are trusted — `CodexRolloutTailTests`), `Core/WebSocketFrame.swift` + `Core/CodexThreadRecord.swift` (the daemon's framing, messages and answers — `WebSocketFrameTests`, `CodexThreadRecordTests`), `Core/CopilotTranscriptTail.swift` (a Copilot turn's or open wait's verdict against `events.jsonl` — `CopilotTranscriptTailTests`); `SessionStore.abandonCandidates` / `codexCandidates` / `copilotCandidates` / `copilotWaitCandidates` / `finishTurn` / `abandonTurn` / `abandonWait` / `failTurn` / `rescueStamp` / `applyVerdict` / `noteBusy` / `dialogAnswered`; the journaled verdicts: `TurnVerdict` (`Core/Event.swift`, including `turn-failed`), `Engine.persist(_:sessionId:at:)` writing the `MySidepulseVerdict` line | §4 *When hooks say nothing*, *Expiry*, `pitfalls.md` |
| which events are subscribed for each agent, the hook command, setting the hooks up and removing them | `Core/HookConfig.swift` (`events`, `codexEvents`, `copilotEvents`, `command(cliPath:agent:event:)`, the OpenCode plugin source and its `opencodePluginId`), `Platform/HookInstaller.swift` (shared by the CLI and the settings window; `installAllHooks` is `install-hooks`; `OpenCodePluginState`), `Platform/SettingsFile.swift`, `Platform/Paths.swift` (`codexHooks`, `copilotHooks`, `opencodePlugin`); the rows are in `App/SettingsSystemPage.swift` — `HookConfigTests`, `HookInstallerTests`, `CodexPlatformTests`, `OpencodePluginRunTests` | §4 *Source*, §10, §11 |
| what the hook records | `Core/Trim.swift`, `Core/Event.swift`, `Platform/HookCommand.swift`, `ProcWalk.swift` | `architecture.md` *The hook path*, *Persistence* |
| the precedence ladder, the split display, which agents a state names | `Core/Arbiter.swift` — `ArbiterTests`, `CodexTests` | §3 |
| carrying an animation across a rewrite: the tail, its cut rules, the roll under a zone, when the loop is handed over | `Core/LedContinuation.swift` (the reader, the cut rules, `tail`, `transition`), `LedProgram.rollHandover` (which changes carry the roll), `Engine.paint` / `carryOn` / `handOver` — `ContinuationTests`, `TransitionTests` (exact text, and a sweep over every phase) | §3 *Carrying an animation on*, `device.md` *Carrying an animation on*, `pitfalls.md` |
| what a state looks like: program text, colours, zone widths, effects, the shared roll's passes | `Core/LedProgram.swift` (`rolling(colors:)`, `rollPasses` — one pass per colour wherever it fits, else one pass by LED —, `splitProgram`, `zoneRollColors`, `rollRecolour`), `LedEffects.swift`, `Constants.swift` — `ProgramTests`, `CodexTests` (exact text). The settings preview mirrors the timings and draws the palette's own hexes: `App/StripPreviewView.swift`, `SettingsSupport.swift` | `device.md`, §3 |
| which colours can be changed, their defaults, the Colours page | `Core/LedPalette.swift` (the slots, `standard` from `K`, the overrides rule, what each slot plays — `PaletteTests`), `Core/Constants.swift` (the defaults), `App/Engine.swift` (`palette`, `setColor`), `App/AppConfig.swift` (`colors`), `App/SettingsColorsPage.swift`, `Core/StringsColorsPage.swift` | §3 *Colours*, §10, `device.md`, `architecture.md` *Persistence* |
| acknowledgement | `SessionStore.acknowledgeAlerts`, `JobStore.acknowledge`, `Engine.acknowledge`, `App/AttentionMonitor.swift`, `Platform/TerminalTabProber.swift`, `ProcWalk.tabTTY` | §5 |
| **when** a push fires | `SessionStore.set` (arming) and `tick` (debounce, deferral, late-drop), `Core/Presence.swift` — `NotifyTests` | §6 |
| **what** a push says | `Core/StringsAlerts.swift` for the words, `Core/Alert.swift` (`AlertCopy`: the title is the agent's name, the body the kind's) — `NotifyTests` pins every string in both languages | §6, §15 |
| how a push is sent, which sessions are silent, the click link | `Platform/Notifier.swift` (`Notifier`, `ClaudeSessions`), `Engine.deliver` | §6 |
| notification settings | `Engine.applyNotifySettings`, `App/AppConfig.swift`, `CLI/RunCommand.swift` (`NotifyCommand`), `App/SettingsNotificationsPage.swift` | §6, §10, §11 |
| terminal jobs, the block in `~/.zshrc` | `Core/JobStore.swift`, `Core/ShellInit.swift` (the snippet, and the block's text rules), `Core/ShellJobLiveness.swift` (`probe`, `judge`: whether a job's shell still runs a command), `Engine.probeJobs`, `Platform/ProcWalk.swift` (`childStartTimes`, `ProcInfo.shellReading`), `Platform/HookInstaller.swift`, `CLI/RunCommand.swift` — `JobTests`, `ShellInitTests` (runs a real zsh), `ShellJobLivenessTests` | §7 |
| battery | `Core/BatteryRules.swift`, `App/PowerMonitor.swift`, `Engine.powerChanged` | §8 |
| finding the strip, the eject guard | `App/DeviceMonitor.swift`, `Platform/LedDevice.swift`, `Core/EjectGuard.swift` | §2, `macOS.md` |
| writing to the strip, keepalive | `Platform/LedWriter.swift`, `Keepalive.swift` | `device.md`, §2 |
| the menu | `App/MenuBarController.swift` | §9 |
| the onboarding wizard: a page, a row, what a row's button does, who is in front | **Invoke the `macos-building-onboarding` skill first**: it holds the window's whole contract and every trap it hit. `App/OnboardingWindowController.swift` (the window, the pages, `GrantRow`), `App/OnboardingCatalog.swift` (`GrantItem`, `FocusReturnWatch`, the five rows, `OnboardingMetrics`), `App/ControlActionHandler.swift`; the words are `Core/StringsOnboarding.swift`. The flag is `AppConfig.onboardingDone`, written through `Engine.markOnboardingDone`; `AppDelegate` opens it and cross-wires `othersNeedUsActive` with `SettingsWindow` and `UpdateController`. **A permission is asked from a button and nowhere else**: a row's, or System's Allow Notifications | §10 *The onboarding wizard*, §12, `macOS.md` *Permissions*, `pitfalls.md`, the checklist's §4 |
| a settings page, its look or its copy | **Invoke the `macos-building-settings-pages` skill first**: it holds every rule of the window's structure, numbers and wording. `App/SettingsKit.swift` (the kit: `SettingsGroup`, the rows, `StatusRow` + `StatusMark`, `SettingsMetrics` with every spacing number), `App/SettingsWindow.swift` (`SettingsPageID`: the pages, titles and symbols; the toolbar; the height that follows the page), `App/Settings*Page.swift` (one per page, structure only), `App/SettingsModel.swift`. **The words are not in the page files**: a page's copy is `Core/Strings<Page>Page.swift`, the shared status vocabulary and the eight page titles are `Core/StringsSettings.swift`, and the `Showing` sentences are `Core/StringsStatus.swift` behind `Core/StatusCopy.swift` — `StatusCopyTests`, `LocalizationTests` | §10, §15, one line in `docs/manual-test-checklist.md` |
| a CLI command | `CLI/CLIMain.swift` (and its usage text), `Platform/Control.swift` (new fields optional), `Engine.controlResponse` | §11, `architecture.md` *Control plane* |
| updates: the check, its schedule, the notification | `Core/UpdateCheck.swift` (versions, what a reply means — `UpdateCheckTests`), `Core/UpdateSchedule.swift`, `Core/UpdatePanel.swift` (the Updates group), the `update…` numbers in `Core/Constants.swift`; `Platform/UpdateChecker.swift` (the request — `UpdateCheckerTests`); `App/UpdateController.swift` (the one owner), `App/UpdateNotifier.swift`, the Updates group of `App/SettingsGeneralPage.swift` | §10 *Updates*, §12, §13, `macOS.md` *Updates* |
| updates: the window, the fetch, making it ready, Install and Relaunch | `Core/UpdateSession.swift`, `Core/StagedUpdateCheck.swift`, `Core/UpdateInstallScript.swift` (the helper's text, its plan, its result — run under a real `/bin/sh` by `UpdateInstallScriptTests`); `Platform/UpdateChecker.swift` (`UpdateDownload`), `UpdateStager.swift`, `CodeSignature.swift`, `UpdateInstaller.swift`, `DetachedProcess.swift`; `App/UpdateWindow.swift`, `UpdateController.installAndRelaunch`; the words in `Core/StringsUpdateWindow.swift` and `Core/StringsUpdate.swift` | the same, plus `pitfalls.md` (the six update entries) and the checklist's §3. **Read those entries before touching the order of an install** |
| a doctor check | `Platform/Doctor.swift` for what it probes and its `name` (an identifier, never translated), `Core/StringsDoctor.swift` for its detail sentence — `DoctorTests`, `CodexPlatformTests` (every detail is a sentence with no long dash, in both languages). The Health page reads a check by its name in `SettingsModel.healthFacts`, takes its `ok` and its sentence (the tooltip), and never reads the sentence back | §11, §10 *What the pages say*, §15 |
| the Health page: a check, a reading, a colour, a fix sentence | **Invoke the `macos-building-settings-pages` skill first** (*The Health page*: two tables, what is a check, the limits). `Core/HealthReport.swift` (`HealthFacts` → `checks(for:)` and `readings(for:)`), `Core/HealthRules.swift` (the colour rules, shared with the System page's rows), `Core/Health.swift` (the level, `HealthRow`, `InfoRow`, `HealthLimits`), `Core/StringsHealthPage.swift`; `App/SettingsModel.swift` (`healthFacts`, `readHealth`, `checkAgain`), `App/SettingsHealthPage.swift` (draws only), `App/SettingsWindow.swift` (reads a page when it is shown); the reader `Platform/CrashReports.swift` — `HealthTests` (the worst case holds `HealthLimits`), `CrashReportsTests` | §10 *What the pages say* |
| **any sentence the user reads**, in either language | `Core/Strings*.swift` (one table per surface; a string is one accessor switching over `Language`, so the two languages are added together or not at all), `Core/Localization.swift` (the language rule and the ambient switch) — `LocalizationTests`, which also reads the tables off disk to check the text rules in both languages | §15, and the section that shows the sentence |
| a new language | `Core/Localization.swift` (`Language`) — every table then fails to compile until it answers for it, which is the point | §15 |
| a constant | `Core/Constants.swift`, with its evidence in the comment | the section that states it, and §13 |
| a persisted setting | `App/AppConfig.swift` — the key must be optional | `architecture.md` *Persistence*, §12 |
| the app icon | `Resources/AppIcon.icon` (re-export from Icon Composer, never hand-edit `icon.json`), `scripts/make-app.sh`, `scripts/dmg-volume-icon.swift` (the disk image's volume icon) | `architecture.md` *Build and signing*, `macOS.md` *Bundle and signing*, `pitfalls.md`, `README.md` |
| the launch agent, install | `App/LoginService.swift`, `Makefile`, `scripts/make-app.sh` | `macOS.md` |
| a permission, `Info.plist` | `scripts/make-app.sh`, `Resources/MySidepulse.entitlements` | `macOS.md`, §12, `README.md` |
| whether a launch opens Settings | `MySidepulseCore/QuietLaunch.swift` (the marker, its freshness, the reopen grace), `MySidepulsePlatform/Paths.quietLaunch`, `MySidepulseApp/AppDelegate` (`quietLaunchAt`, `applicationShouldHandleReopen`), `scripts/install.sh` and `UpdateController.installAndRelaunch` (write the marker) | `functional.md` §10 |
| how the app comes under its launch agent | `MySidepulseCore/LaunchdHandover.swift` (the helper's text), `MySidepulseApp/LoginService.swift` (`install`, `handOverToLaunchd`), `MySidepulseApp/AppDelegate.applicationDidFinishLaunching` | `functional.md` *Handing over to launchd*, `pitfalls.md` *Bootstrapping the agent does not put the running app under it* |
| the uninstall | `MySidepulseCore/UninstallPlan.swift` (the jobs, and the helper that waits for this pid), `MySidepulseApp/Uninstall.swift` (the order, and why it is that order), the Uninstall group of `MySidepulseApp/SettingsGeneralPage.swift`, `MySidepulseCore/StringsGeneralPage.swift` | `functional.md` *Uninstalling*, `pitfalls.md` *`launchctl disable` is permanent* |
| the signing identity, the notarization profile, the build or the release | `scripts/signing.env` (sourced by every script that builds, signs, wraps or publishes a build), `scripts/make-app.sh` (signing), `Resources/MySidepulse.entitlements`, `scripts/make-dmg.sh` (`scripts/dmg-settings.py`, `scripts/dmg-background.swift`, `scripts/dmg-volume-icon.swift`), `scripts/release.sh` (notarization and stapling) | `architecture.md` *Build and signing*, `macOS.md` *Bundle and signing*, `pitfalls.md` |

## Commands

```bash
# ---- the two actions. A build of this app reaches a Mac by one of these and by nothing else. ----
make install     # skill: macos-install-locally. The production build → /Applications; leaves no .app or .dmg behind
make release     # skill: macos-publish-release. The same, plus tag, push, GitHub release, and the tree moves on
# Both work on this Mac: signing and the notary are set up and nothing is wrong with them. Use the script;
# a refusal at the notary check is run again, never diagnosed.
# -------------------------------------------------------------------------------------------------
```

- `swift build` — all four code targets.
- `swift test` — two bundles, and **one summary line each: read both.**
  `MySidepulseCoreTests` (565, one opt-in skip) runs in about thirty seconds;
  `MySidepulsePlatformTests` (191) takes about 30 s, because it spawns real
  subprocesses, FIFOs and sockets. `swift test --filter <SuiteName>` runs one
  suite.
- `MYSIDEPULSE_REPLAY_JOURNAL="$HOME/Library/Application Support/MySidepulse/journal.jsonl" swift test --filter RealJournalReplayTests`
  — replays the live journal through `SessionStore`. It asserts invariants only
  and prints nothing private. Run it for any change to session rules.
- `make install` (`scripts/install.sh`) — **one of the two ways a build of
  this app reaches a Mac.** It builds the real thing — Release, signed with the
  Wooflab team's Developer ID under the Hardened Runtime, notarized by Apple,
  stapled, wrapped in the disk image — takes the bundle out of that image into
  `/Applications`, opens it once, waits for the launch agent's job to have a
  process (the app hands itself over; the script no longer does it from
  outside), installs the hooks and prints `doctor`. It leaves **no `.app` and no `.dmg`
  anywhere under the repository**, on any exit path. **It restarts the owner's
  running monitor**: say when you ran it and when you did not. **It works on this Mac**: the signing identity and the notary profile are set up and nothing is wrong with them; if the notary check refuses, run it again and diagnose nothing (`docs/shared/workflow.md`, *Installing works on this Mac*).
- `make release LEVEL=<patch|minor|major> NOTES=<file>`
  (`scripts/publish.sh <level> --notes=<file>`) — **the other way.** Refuses
  without release notes (written from every commit since the last tag, skill
  `macos-publish-release`, *Release notes*), on a dirty tree, computes the new version and
  refuses if that tag already exists, then bumps the version by the level
  given, commits and pushes that bump, and only then builds — the same
  build `install` makes, then the tag, the push and the GitHub release carrying
  the image. Nothing bumps the version again afterward. Run it only when the
  owner has asked for a release, and ask which level if they have not said.
  It leaves `/Applications` alone: the copy here stays on the older version and
  installs the release itself, as a user's does. `--install` (`make release …
  INSTALL=1`) installs it here too, and is passed only when the owner asks for
  it.
- **There is no third way.** A bundle left in `build/` is a complete
  application that Spotlight offers; launching it by accident gives a second
  MySidepulse with the same bundle identifier, the same journal and the same
  launch agent. `scripts/no-leftovers.sh` holds that rule: `no_leftovers`
  sweeps, `never_indexed` keeps Spotlight off `build/` while a build is going.
- `scripts/version.sh` — the version rule, and the only thing that writes the
  version: **a local install always builds and installs exactly the tree's own
  version**. `scripts/publish.sh <patch|minor|major>` is the only thing that
  moves it: it bumps by that level, commits and pushes the bump before it
  builds anything, then releases exactly that version. Nothing bumps it again
  afterward.
- `make app` / `make dmg` / `scripts/release.sh` — the steps underneath, useful
  on their own only to debug the pipeline. `make-app.sh` refuses an ad-hoc build
  without `DEBUG_OK=1`, and **an ad-hoc or Debug build is never installed and
  never made without asking the owner first.** `MYSIDEPULSE_UPDATE_FEED=file:///…/latest.json`
  in the installed app's environment replaces GitHub's reply with a stand-in
  (`{"tag_name": "9.9.9", "assets": [{"name": "….dmg", "browser_download_url":
  "file:///…", "size": …, "digest": "sha256:…"}]}`), which is how the whole
  update is walked offline (`docs/manual-test-checklist.md` §3).
- `/Applications/MySidepulse.app/Contents/MacOS/mysidepulse doctor` — twelve
  checks, exit code = failures. `… status [--json]` — mode, display, strips,
  sessions with their agent, jobs, notifications with the topic masked.
- `/usr/bin/log show --predicate 'subsystem == "io.mysidepulse.app"' --last 1h`
  — the app's log. `log` alone is a zsh builtin, hence the full path. Device
  arrival, stalls, rescues and sent pushes are logged at `notice`, the lowest
  level macOS persists.
- The journal is `~/Library/Application Support/MySidepulse/journal.jsonl` —
  one JSON line per hook event, from any of the four agents (`agent`), the
  evidence every derived constant is calibrated from. It holds working
  directories and message tails: read it locally, never paste it. **Never read
  or print `config.json`** in that directory: it holds the ntfy topic.
- Codex runs a hook only once it has been trusted in Codex. After an
  `install-hooks` (every `make install` runs one) the entries in
  `~/.codex/hooks.json` are new to Codex again, and nothing reaches the
  journal from Codex until the owner has trusted them there. Copilot and
  OpenCode need no such trust step: `install-hooks` (and `make install`) sets
  up Copilot's hook file and OpenCode's plugin the moment it runs, on any Mac
  where that agent is present, and each takes effect at once.

## Architecture

Four code targets, dependencies pointing one way: Core ← Platform ← App and CLI.
Full version in `docs/architecture.md`.

- **`Sources/MySidepulseCore`** — pure rules, **Foundation only** (`PurityTests`
  fails the build otherwise). Never reads a clock: `now` is always passed in,
  which is what lets tests and the journal replay drive it.
  `Agent` (`AgentKind`: Claude Code, Codex, GitHub Copilot or OpenCode;
  `Agents`: which of them a display state is about) ·
  `SessionStore` (the per-session state machine: `apply` folds an event, `tick`
  applies every time-based rule and returns the pushes that are due,
  `nextDeadline` says when to tick next) · `Event` + `JournalCodec` + `Trim`
  (the journal line and its 4096-byte cap) · `CodexRolloutTail` (what a
  Codex rollout's tail says about a quiet turn, and which rollout paths are
  trusted) · `WebSocketFrame` + `CodexThreadRecord` (the framing, the
  four messages and the answers of Codex's daemon) · `CopilotSessionState`
  (Copilot's session-state root, a subagent filter, the transcript path) ·
  `CopilotTranscriptTail` (what a Copilot session's `events.jsonl` says about a
  quiet turn or an open wait cancelled with Ctrl+C) · `TurnVerdict` (the outcome of a
  rescue, journaled so a relaunch applies it again) · `Arbiter` (mode, power, sessions,
  jobs → one `DisplayState`) · `LedProgram` + `LedEffects` (display state →
  program text) · `LedPalette` (the eleven colours the owner can change, which
  saved colour is trusted, and the colours a roll cycles through) ·
  `BrightnessCurve` (brightness as the eye
  sees it, to the strip's 1…255) · `BrightnessCycle` (the steps of
  `mysidepulse brightness cycle`, the mode it brings back, when its white LED
  shows) · `Constants` (`K`: every default colour and
  every timing, with its evidence)
  · `Alert` (`AlertCopy`, the push text) · `Presence` · `JobStore` ·
  `BatteryRules` · `EjectGuard` · `HookConfig` (edits to Claude Code's and
  Codex's `settings.json`, Copilot's whole hook file, OpenCode's plugin
  source) · `ShellInit` (the zsh snippet, and the text of its block in `~/.zshrc`) ·
  `ShellJobLiveness` (whether a running job's shell still runs a command) ·
  `UpdateCheck` (release versions, and what GitHub's reply means) +
  `UpdateSchedule` + `UpdatePanel` + `UpdateSession` + `StagedUpdateCheck` +
  `UpdateInstallScript` (the rest of the update's rules, and the text of the
  helper that finishes an install) ·
  `StatusCopy` (which sentence and tone a display state gets) ·
  `Health` + `HealthRules` + `HealthReport` (the Health page's two tables and
  the colour rule every page's grants follow) ·
  `Localization` (`Language`, the rule that reads a system language tag, and
  `Loc`, the ambient switch) + `Strings*` (every user-facing string, English and
  French side by side, one table per surface).
- **`Sources/MySidepulsePlatform`** — headless, testable I/O. `HookCommand` +
  `JournalWriter` (the hook path) · `JournalTailer` (kqueue, follows rotation) ·
  `ProcWalk` (sysctl: the nearest of the four agents' processes, its host
  app, its terminal tab) ·
  `ProcessWatcher` (kqueue exits) · `ClaudeProcessRegistry` + `TranscriptTail`
  (Claude's side channels) · `CodexRollout` + `CodexDaemonClient` (Codex's: the rollout's tail, and its daemon's `thread/read` and `thread/loaded/list`, 1 s per call) ·
  `CopilotTranscript` (Copilot's `events.jsonl`, read through `FileTail`, the
  non-blocking tail reader it shares with `CodexRollout`) · `TerminalTabProber` (osascript, Terminal and
  iTerm2) · **`LedWriter`** (the only code that writes `LEDS.LED`: one io queue,
  dedupe, 2 s watchdog) · `LedDevice` (identity = `st_dev`, `st_ino`) ·
  `Keepalive` · `Notifier` + `ClaudeSessions` (the only ntfy client) ·
  `Control` + `ControlServer` + `ControlClient` (Unix socket, JSON lines) ·
  `Doctor` · `CrashReports` (the Health page's crash line) · `Paths` · `SettingsFile` · `HookInstaller` (sets up and removes
  Claude Code's and Codex's hook entries, Copilot's hook file, OpenCode's
  plugin and the zsh block, for the CLI and the settings
  window alike) · `UpdateChecker` +
  `UpdateDownload` (the only code that talks to GitHub) · `UpdateStager` +
  `CodeSignature` (the disk image, the copy, its signature) · `UpdateInstaller`
  + `DetachedProcess` (the hand-over to the helper, which outlives the app).
- **`Sources/MySidepulseApp`** — `AppDelegate` wires everything. **`Engine`**
  owns all mutable state on the main queue, and every input — journal events,
  timers, power, devices, focus, CLI — funnels into `sync()`, the one path from
  state to LEDs. One wall-clock deadline timer; no periodic tick.
  `DeviceMonitor` (DiskArbitration) · `PowerMonitor` (IOKit) ·
  `AttentionMonitor` (focus, input idle, screen lock) · `LoginService` (the
  launch agent) · `AppConfig` (`config.json`) · `MenuBarController` ·
  `UpdateController` (the update's one owner: the schedule's timer, the panel
  and the session the two windows observe, Install and Relaunch) +
  `UpdateNotifier` + `UpdateWindow` · the
  settings window (`SettingsKit` the kit, `SettingsWindow` the toolbar window
  whose height follows the page, eight `Settings*Page`, `SettingsModel`,
  `StripPreviewView`).
- **`Sources/MySidepulseCLI`** — `CLIMain` (dispatch and usage), `RunCommand`
  (`run`, `job`, `notify`).

The app target has no automated tests. Its verification is the strip,
`mysidepulse doctor`, the log, and the journal replay.

## Rules

- **`docs/functional.md` is kept in sync with every behaviour change, in the
  same commit, and never carries an outdated rule.** A rule the owner has
  overruled is replaced, not annotated.
- **A functional request that conflicts with a written rule is a question, not
  a change.** Quote the rule, ask whether it is overruled, and only then
  implement. If the owner reaffirms the request, that is the answer: replace
  the rule.
- **Comments and documents state the present.** A comment records a rule, an
  invariant, a fact the code depends on, or the measurement behind a derived
  constant. No dates, versions, attributions or accounts of what the code
  replaced. History belongs in git and, for traps only, in `docs/pitfalls.md`.
- `Sources/MySidepulseCore` imports Foundation only. Rules stay pure;
  frameworks live in Platform and App.
- **Nothing that can block on the strip or the network runs on the main
  queue**: probing, LED writes and keepalive touches each have their own queue,
  and the touch is a separate process.
- LED timings in `Constants.swift` are calibrated by eye on the real device:
  retune them only against hardware. The colours there are the owner's
  defaults for the Colours page, true colours, the same hex on the strip and on
  screen. A strip's brightness dims it, never a darker hex: the scaling is the
  last step before the text goes out (`LedProgram.scaled`), never a line in the
  program and never the palette. Colours are the owner's call.
- **LED program text is a device contract.** Assemble it only from token
  shapes the device already accepts, inside 20 lines and 512 bytes; change it
  only together with the exact-text tests in `ProgramTests`; verify it on the
  strip. Two other texts leave the program with no compiler to check them —
  the push copy (`AlertCopy`) and the zsh snippet with its `~/.zshrc` block
  (`ShellInit`, tested by running both in a real zsh). Same discipline.
- The hook path (`mysidepulse hook`) must never block and never exit non-zero:
  it runs inside every Claude Code turn.
- **An update never installs by itself, and a failed one never leaves the strip
  dark for good.** The automatic check only announces; the fetch and the
  install each need a click. Everything that can refuse an update runs while
  the app is up. The install leaves through `NSApp.terminate`, like every quit;
  the helper touches nothing until the pid is gone, starts the new copy through
  the launch agent when the old one was its job, and keeps the previous bundle
  until the new version is seen running, putting it back and starting it
  otherwise.
- **No user-facing string is written at its point of use.** It goes in a
  `Core/Strings*.swift` table, where one accessor answers for every language, so
  a string cannot exist in English alone. Nothing reads a translated sentence
  back to decide anything: a page that needs a fact reads the fact (the
  Health page takes the strip and the phone from the engine's status, never
  from the doctor's sentences). The CLI's output is English by rule, which costs
  nothing to keep because the language is read where a sentence is built.
- **The ntfy topic is a password.** `config.json` is `0600`; `doctor`, `status`,
  the Health page's tooltip and the log carry only a masked prefix. Never put a live
  topic in a commit message, an issue, a document or a transcript, and never
  read `config.json` to look at it.
- Every `config.json` key added after the first release is optional: a missing
  non-optional key fails the whole decode and resets the config, ntfy topic
  included.
- Every device, tab and process is known by identity, never by name or path: a
  strip by `(st_dev, st_ino)`, a tab by a tty a shell under the host app holds,
  a Claude process by pid *and* path. Every acknowledgement gate fails open: a
  doubt may widen what gets acknowledged, never strand an alert.
- The GUI executable in the bundle is `MySidepulseApp`, not `MySidepulse`:
  `Contents/MacOS` is on a case-insensitive volume, where `MySidepulse` and
  `mysidepulse` are one file. Only `CFBundleExecutable` has to match.
- The hardware is **SidePulse**; the app is **MySidepulse**. Do not "fix" the
  `sidepulsedot` / `sidepulsepro` prefixes or a sentence about the SidePulse
  strip.
- Subagents: every spawn names a model **and** an effort; never the session's
  default model, never a fan-out wider than four. The Agent tool cannot set
  effort, so use the pinned definitions in `.claude/agents/sp-*.md` (git-ignored;
  a definition written mid-session loads only after a restart).
- Apply changes with `make install`, never by building into `build/` and
  launching that; check health with `mysidepulse doctor`.
- Stage by path. `.claude/` and `.superpowers/` are the owner's.

## Traps

`docs/pitfalls.md` is the full list, with the evidence. The six that cost the
most:

1. **The tests are not the proof for the strip.** A per-LED pulse returns to its
   *pre-pulse* value, not to black, so per-LED programs open with a baseline
   frame; the same LED twice on one line renders once. Both were caught by eye
   within minutes of a build whose tests were green.
2. **Hooks are not reliable, one at a time.** `SubagentStop` is often never
   sent; Esc and Ctrl-C fire nothing; one approval can produce no event at all;
   `idle_prompt` is a 60 s timer, not a request. Never build a state on a single
   event arriving — every such state has a rescue and a backstop.
3. **A filesystem call on a dying card never returns**, and a blocked main
   queue stops the keepalive as well as the CLI — so the strip dies three
   minutes *after* the cause. `doctor`'s app check is the detector.
4. **Ad-hoc signing and launchd.** `SMAppService.agent` cannot work for this
   app, and an app started by `open` is nobody's job: only
   `XPC_SERVICE_NAME == io.mysidepulse.agent` proves a crash would be restarted.
   Do not modernise the agent; do not trust a plist on disk.
5. **CPU sampling cannot tell an idle Claude from light work.** It was tried and
   removed within hours. Do not bring it back.
6. **The app's name is an identity in six places** — bundle id, agent label,
   support directory, hook command, the ack event in the journal, the shell
   variables. Renaming any of them is a migration.

## Status

`swift build` is clean and `swift test` is green (565 + 191, one opt-in skip) at
this commit. The live journal replays.

Checked on the strip by the owner: the brightness key over the roll carries the
wave on with no hole and nothing left lit, off and back within 2 s resumes it
mid-wave, and a finish or a question landing over the roll opens its zone while
the wave rolls on.

Walked end to end on the owner's Mac: a drag install from the disk image, which
now hands itself to launchd instead of asking the user to log out; `make install`
over it, which opens no window; and Settings › General › Uninstall, which left no
launch agent, no job, no hooks, no zsh block, no preferences and no Application
Support folder.

Known limitations, in plain words — the authority is *Open issues* in
`docs/pitfalls.md`:

- Cancelling a standing dialog with Esc leaves its amber up until the next
  prompt or the 2 h backstop.
- A subagent's question or plan wait is not cleared by that subagent's next
  event; the answered-dialog check clears it within about 30 s.
- A subagent silent for over 4 minutes releases a held finish while it may
  still run: green over real work, by design, as the price of not trusting
  `SubagentStop`.
- A Claude launched through an interpreter (`node …/cli.js`) is not recognised,
  so its death goes unnoticed until the 2 h backstop; the same for a Codex run
  that way.
- A Codex turn's lost `Stop` or `Interrupt` is read from Codex's daemon and
  its rollout within about 35 s; a turn that ends in an error has no known
  rollout marker: a TUI session goes dark when the daemon says its thread is
  idle, and any other rolls until 2 h after the rollout's last line. Whether Codex
  fires `PreToolUse` for `request_user_input` is unobserved.
- A quiet Copilot turn is read from its `events.jsonl` within about 35 s, on
  the same rule as Codex's rollout; a Copilot open wait cancelled with Ctrl+C
  goes dark the same way. Approving a Copilot permission fires no hook, and
  `permission.completed` is not read as the answer, so an approved wait stays
  amber until the next event or the 2 h backstop. Nothing here has run against
  a live Copilot.
- The shared roll (one colour per pass on the whole strip wherever the passes
  fit: two agents on the Pro, any number on the Dot; one pass, one colour per
  LED, for three or four on the Pro; one per LED under a zone, LED *i* keeping
  agent *i* mod *n* for three or four), its recolour tail and its pass-end
  handover are pinned by exact text and the phase sweeps, and have not been
  seen on the strip, nor have Copilot's `#0e5cff` and OpenCode's `#ff0043`.
  Judge them there before trusting them.
- Copilot's hook file and OpenCode's plugin are set up by `install-hooks`,
  `make install` and the System page's own buttons, on any Mac where that
  agent is present, exactly as Claude Code's and Codex's hooks are. Neither
  has been walked with a real Copilot or OpenCode session: the System page's
  two new groups, the Health page's `Copilot hooks` and `OpenCode plugin`
  lines and the doctor's two new checks are proven only by their tests.
- Jobs are not journaled: a restart forgets them.
- One write queue serves every strip: a card whose write never returns freezes
  all of them until the app restarts.
- The eject guard matches the built-in reader, so it holds any card in that
  slot, not only the strip.
- The front-tab probe runs on every activation of Terminal or iTerm2, alert or
  not, at most once per 2 s.
- Every update check answers `No release published yet` (a press says so, the
  automatic one says nothing) until the GitHub repository is public and carries
  a release with a version tag and the `.dmg` that `make dmg` builds.
- The onboarding wizard has never been walked on hardware. Its rules have no
  automated test at all beyond the strings; `docs/manual-test-checklist.md` §4
  is the whole of its verification, and nothing in it has been ticked.
- The update has never been seen end to end in this app. Its rules are
  unit-tested, the helper has installed and rolled back a stand-in app for
  real, `launchctl kickstart` has been measured on a job that had exited, and
  the stager has accepted and refused this app's own ad-hoc disk image; the
  notification, the update window and MySidepulse installing over itself are
  the checklist's §3.
- Three facts the code cannot settle are listed in `docs/functional.md` §14.
