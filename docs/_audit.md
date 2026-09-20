# Audit — 2026-09-19

Working file. What the read pass found, what is deleted, what stays and why.
Coverage and the fan-out log are in [_coverage.md](_coverage.md).

## Map

| Area | Files | Verdict |
|---|---|---|
| Core: session state, arbiter, alerts, presence, codec, hook config | `SessionStore`, `Event`, `Arbiter`, `Alert`, `Presence`, `JournalCodec`, `HookConfig` | LIVE |
| Core: LED programs, effects, constants, trim, battery, eject rule, jobs, zsh snippet | `LedProgram`, `LedEffects`, `Constants`, `Trim`, `BatteryRules`, `EjectGuard`, `JobStore`, `ShellInit` | LIVE, with D1, D3, F2 below |
| Platform: Claude source | `HookCommand`, `JournalWriter`, `JournalTailer`, `ProcWalk`, `ProcessWatcher`, `ClaudeProcessRegistry`, `TranscriptTail`, `TerminalTabProber`, `BootTime`, `Paths`, `SettingsFile` | LIVE, with D5 |
| Platform: device, ntfy, control, doctor | `LedDevice`, `LedWriter`, `Keepalive`, `Notifier`, `Control*`, `Doctor` | LIVE |
| App: engine and monitors | `main`, `AppDelegate`, `Engine`, `DeviceMonitor`, `PowerMonitor`, `AttentionMonitor`, `LoginService`, `AppConfig`, `Log` | LIVE, with D2, D4, F3 |
| App: UI | `MenuBarController`, `Settings*`, five `*Pane`, `StripPreviewView` | LIVE |
| CLI | `main`, `CLIMain`, `HooksInstall`, `RunCommand` | LIVE |
| Tests | 17 Core, 14 Platform | LIVE; one opt-in skip (`RealJournalReplayTests`, needs `MYSIDEPULSE_REPLAY_JOURNAL`) |
| Build | `Package.swift`, `Makefile`, `scripts/*`, `.vscode/launch.json`, `.gitignore` | LIVE, with F1 |
| Docs | `CLAUDE.md`, `README.md`, `docs/FUNCTIONAL.md`, `docs/mysidepulse-functional.html` | rewritten; D6 |

One device backend (`LedWriter`), one ntfy client (`Notifier`), one Claude
status source (hooks → journal) with two read-only side channels (Claude's
process registry, the transcript tail). No duplicate implementations, no
commented-out code, no `TODO`/`FIXME`, no `#if false`, no disabled tests, no
secrets in the repository.

## How dead code was found

Slice readers reported no dead symbols. That verdict was wrong for one constant
(S2 claimed every `K` member had a caller; `K.agentReregisterPauseSeconds` has
none), so the parent ran a mechanical sweep: every identifier declared in
`Sources/` (981) counted by word occurrence across `Sources/` and `Tests/`.
One occurrence → dead or framework-called; two → checked by hand for
write-only state. The stitch agents then confirmed each finding independently
at its call sites.

## Deletions

| # | What | Where | Proof |
|---|---|---|---|
| D1 | `K.agentReregisterPauseSeconds` | `Constants.swift:179-182` | Zero references in `Sources/` and `Tests/`. Residue of the `SMAppService` mechanism; `LoginService.install` is synchronous and never pauses. |
| D2 | `AppConfig.loginItemHandled` | `AppConfig.swift:8`, written at `AppDelegate.swift:39` | Written, never read. An existing `config.json` carrying the key still decodes (unknown keys are ignored); the next save drops it. |
| D3 | The provider abstraction: `provider:` on `LedProgram.program` and `splitProgram`, `providerWorkingColors`, `K.unknownWorking`, `testUnknownProviderFallsBackToCyan`, the `unknownWorking` palette row in `ProgramTests` | `LedProgram.swift:47,58,63,73,152,158`, `Constants.swift:9`, `ProgramTests.swift:30-,120` | The one production caller (`Engine.swift:343`) never passes `provider`; no journal field carries one. Every emitted program is unchanged. |
| D4 | The `"ping"` control command | `Engine.swift:585-586` | No `ControlRequest(cmd: "ping")` anywhere in `Sources/`. `ControlTests` use `ping` against their own handler, not the engine's. |
| D5 | `ProcWalk.controllingTTY(forPid:)` and the test of it | `ProcWalk.swift:145-156`, `TerminalTabProberTests.swift:26-31` | Public, called only by that test. Tab ttys come from `ProcWalk.chain` + `tabTTY`; `ttyName` keeps its own tests. |
| D6 | `docs/mysidepulse-functional.html` | — | A v1.0.2 snapshot of the functional doc (single-pulse waiting, `waiting(idle_prompt)`, 2.4 s battery breath — none of it current). Nothing generates or links it. Loads Google Fonts. |
| D7 | Narrative comments | all of `Sources/`, `Tests/` | See "Comment policy". |

## Fixes that ride along

| # | What | Where |
|---|---|---|
| F1 | `VERSION="1.5.2"` on a tree whose HEAD is titled 1.5.3 → `1.5.4` | `scripts/make-app.sh:6` |
| F2 | Comment names `K.alertZoneLeds`; the constants are `alertZoneLedsNeedsYou` / `alertZoneLedsFinished` | `LedProgram.swift:24` |
| F3 | Unnamed literal `300` for the hook-silence warning → `K.hooksSilentWarnSeconds` | `Engine.swift:415` |
| F4 | Comment points at `docs/FUNCTIONAL.md §2` | `HookConfig.swift:6` |

## Kept, deliberately

| What | Why |
|---|---|
| Test seams: `LedWriter.onWriteCompleted` / `writesPerformed`, `ControlServer.isServing`, `Keepalive.tick` / `tickNow` / `outstandingTouches` | Production never calls them; the tests that pin write dedupe, stall recovery, bind retry and touch accounting cannot work without them. |
| Journal fields the app never reads: `promptId`, `agentType`, `reason`, `stopHookActive`, `errorType`, `isInterrupt`, `lastMessageTail`, `hostAppPid`, `permissionMode`, `rawPrefix` (and `K.messageTailMaxChars`, the tail shrink pass) | The journal is the forensic record the timing constants are calibrated from, and `RealJournalReplayTests` replays it. Recording them is current behaviour. |
| `LoginService.migrateFromLoginItem()` | Reachable on every launch. A no-op once migrated, but whether a given machine still has a registered login item cannot be proven from code, and what it prevents (a second copy at login, a stale Login Items entry) is real. |
| `SessionStore.swift:242` — `sessionEnd`, `parseError`, `ack` in the main switch | Unreachable (handled above), but they keep the switch exhaustive without a `default`, so a new event cannot be silently ignored. |
| `LedProgram.ledCount`'s `sidepulsepro` branch | Same result as the default today; it is the only place the code names the 8-LED product. |
| `.gitignore`: `*.xcodeproj`, `docs/superpowers/` | Tool output. |

## Comment policy

Deleted: version markers, dates, "used to / was / until / previously / the first
cut", stories of fixed bugs, rejected approaches, who asked for what and when.
Every such story that is a real trap is in [pitfalls.md](pitfalls.md).

Kept, in the present tense: invariants and what breaks without them; the
non-obvious reason for a design; hardware, macOS and Claude Code facts the code
depends on; and — as `CLAUDE.md` requires — the measurement behind each derived
constant (the evidence, not the story).

## Disparities between docs and code

None large. `docs/FUNCTIONAL.md` matches the code on every feature checked
(S11b: ~65 features, ~40 numbers). Drift found:

- Prose says the quiet-turn gate is 90 s and the recheck 30 s; its own table and
  the code say 20 s and 15 s.
- `autoRestartWanted` is missing from its list of `config.json` keys.
- The transcript tail's 256 KB window and its `stop_sequence` case are not
  mentioned.
- `CLAUDE.md` and one code comment name a constant that does not exist
  (`K.alertZoneLeds`).
- The shipped bundle reports 1.5.2.

## Behaviour found that is not dead code

Recorded in the docs, not changed — this cleanup does not alter what the strip
means.

| Finding | Where | Bound |
|---|---|---|
| A wait raised by a *subagent's* `PermissionRequest` for `AskUserQuestion` / `ExitPlanMode` is not cleared by that subagent's next event; only `waiting(permission)` is | `SessionStore.swift:142` vs `:146` | The answered-dialog rescue clears it within ~15–30 s |
| The eject veto matches the reader, so any card in the built-in slot is vetoed and remounted | `EjectGuard.swift:17-20` | — |
| One io queue for all strips: a write that never returns blocks every strip | `LedWriter.swift:10,59` | Replug does not free it; restart does |
| A blocked main queue stops keepalive as well as the CLI (`main.sync` in a repeating timer's handler) | `Engine.swift:141-143` | `doctor`'s app check |
| Keepalive, rescan, power refresh and DA retry timers are monotonic and pause during sleep; wake forces no rescan | `Keepalive.swift:35`, `DeviceMonitor.swift:73,83`, `PowerMonitor.swift:27` | DiskArbitration / IOKit pushes |
| The `idle_prompt` lost-Stop rescue writes no log line | `SessionStore.swift:224-227` | — |
| Program builders clamp LED count to 2…8, the battery bar to 1…8 | `LedProgram.swift:107,153,190` | Unreachable: `ledCount` is only ever 2 or 8 |

## Questions

None that block. Two facts the code cannot settle are listed in
`functional.md` §14.

## Not done, on purpose

- **The front-tab probe runs on every activation of Terminal or iTerm2**, alert
  or not (`Engine.acknowledge` always asks `TerminalTabProber`), bounded to one
  `osascript` per 2 s. Skipping it when nothing is acknowledgeable would save
  the subprocess and change nothing visible except *when* macOS first asks for
  the Automation permission. It touches the acknowledgement path, so it is left
  for a change of its own with tests. The comment on `K.ttyProbeCacheSeconds`
  claimed the probe only ran while an alert was displayed; it now says what the
  code does.
- **The subagent question/plan wait asymmetry** (`SessionStore.swift`, subagent
  branch) is a status-mapping change, not a cleanup. Recorded under Open issues
  in `pitfalls.md`.
- **`make install` was not run.** It restarts the running monitor and, because
  every ad-hoc build has a new code identity, can make macOS ask for the
  Automation permission again. The installed app is still the previous build.

## Verification

| Check | Result |
|---|---|
| Comments-only proof: `Sources/`, `Tests/`, `Makefile`, `scripts/` with comments stripped, before vs after the comment pass (91 files) | 0 files with code differences |
| `swift build` | clean, no warnings |
| `swift test` | 306 tests, 0 failures: Core 215 (1 opt-in skip), Platform 91 |
| `MYSIDEPULSE_REPLAY_JOURNAL=<live journal> swift test --filter RealJournalReplayTests` | passed, 9,117 journal lines replayed |
| `make app` (release build, bundle, ad-hoc signing) | built; bundle reports 1.5.4 |
| Exact-text LED program tests (`ProgramTests`) | unchanged and passing — no emitted program differs |
| Deleted symbols anywhere in the repository | none left |
| Topic- or token-shaped strings | only synthetic test fixtures (`cc-abc123`) |
| History narrative in comments | none left (remaining pattern hits are present-tense uses, one zsh line inside a string literal, and fixture data) |
| Dates / versions in `functional.md`, `architecture.md`, `device.md`, `macOS.md`, both READMEs | none, bar the audit date in `docs/README.md` |
| Relative links in the docs | all resolve |

Not verified: the strip itself. No program text changed, so there is nothing
new for it to show; the installed app was not replaced.
