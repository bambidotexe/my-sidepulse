# Functional reference

What MySidepulse does, as implemented. Timings are named by their constant in
`Sources/MySidepulseCore/Constants.swift` (`K`); section 13 lists them all.

This document is the authority on behaviour. It describes the app as it is
today and nothing else: a change to behaviour replaces the rule it changes here,
in the same commit as the code, and no outdated rule is kept. A request that
contradicts a rule written here is put to the owner, quoting the rule, before
anything is changed. The workflow is in `CLAUDE.md`.

## 1. Purpose

MySidepulse is a macOS menu-bar app that drives a SidePulse LED strip — an
LED bar in SD-card form factor sitting in the Mac's card slot — so that three
things are visible at a glance: Claude Code is **working**, Claude Code has
**finished**, Claude Code **needs you**. When nobody is at the machine, the
same finished / needs-you alerts go to a phone through ntfy. Around that core
it also shows terminal jobs, the battery, and a few decorative effects. It
reads Claude Code through hooks; it never talks to Claude Code and sends
nothing but the ntfy pushes off the machine. Everything it shows, and everything
it pushes, is in English or French, chosen from the system language (§15).

## 2. The strip: insert, remove, missing

- A strip is any mounted volume with a `LEDS.LED` file at its root. A volume
  named `SidePulseDot…` has 2 LEDs; anything else has 8.
- **Insert.** The strip is found through DiskArbitration (or, at launch, a scan
  of `/Volumes`) and painted with the current state at once. Several strips can
  be attached; each gets the same state, rendered for its LED count.
- **No strip.** The app runs normally: sessions are tracked, pushes are sent,
  the CLI and menu work. `status` reports `device: none mounted`.
- **Pull it out.** Supported, at any time. The strip is forgotten; re-inserting
  it repaints it. macOS may show its "Disk Not Ejected Properly" notice.
- **Software eject** of a card in the built-in SD reader is vetoed, and the
  volume is remounted every `K.ejectRemountRetrySeconds` (5 s) until it is
  back. The veto keys on the *reader* (`Secure Digital` protocol or an `SDXC`
  model), not on the volume. USB readers are not vetoed.
- **Kept awake.** `<volume>/keepalive` is touched every `K.keepaliveSeconds`
  (60 s) so macOS does not power the reader down.
- **Slow or hung strip.** A write that takes longer than
  `K.writeWatchdogSeconds` (2 s) marks the strip `STALLED`; it recovers by
  itself when that write returns, and repaints. A write that never returns
  needs a replug.
- A missed DiskArbitration callback is caught by a rescan every
  `K.deviceRescanSeconds` (300 s).

## 3. What the strip shows

`Arbiter.decide` picks one display state. Top wins:

| # | Condition | Strip |
|---|---|---|
| 1 | Mode is `off`, a colour, or an effect | Dark / that colour / that effect. Nothing outranks a manual mode. |
| 2 | On battery at ≤ `K.batteryCriticalPercent` (15 %), not charging | Slow red breath, 6 s. |
| 3 | The power cord was just plugged or unplugged | Battery fill bar for `K.glanceSeconds` (7 s). |
| 4 | An **alert** and **work** at the same time | Split: the alert on the left LEDs, the work roll on the rest. |
| 5 | An alert alone | Whole strip. |
| 6 | Work alone | Whole strip. |
| 7 | Nothing | Dark. |

**Alert** is the first of these that exists and has not been acknowledged:

1. a Claude session waiting for you → amber double blink;
2. a terminal job that failed → amber double blink;
3. a Claude session that finished → green breath, 4.5 s;
4. a terminal job that succeeded → green breath.

**Work** is the first of these that exists:

1. a Claude session working — or an *acknowledged* open wait that still has
   subagents or background shells running behind it → rolling red wave;
2. a terminal job running → rolling violet wave.

In a split, a needs-you alert takes `K.alertZoneLedsNeedsYou` (3) LEDs and a
finished alert `K.alertZoneLedsFinished` (2); at least one LED always stays
with the work. The amber zone blinks in the same 1.5 s rhythm as the full-strip
blink; the green zone holds steady.

With several sessions the strip does not say which one: the most urgent alert
and the most active work win. `mysidepulse status` lists them individually.

**Settle.** An alert must stand for `K.alertSettleSeconds` (1 s) before it
reaches the strip; until then the strip keeps showing what it showed. An alert
that is gone within that second is never seen. Going to `working` has no
settle: it shows on the event that caused it.

Colours, shapes and exact program text are in [device.md](device.md).

## 4. Claude Code status

### Source

`mysidepulse install-hooks` subscribes one command — `<bundle>/Contents/MacOS/mysidepulse hook`,
matcher `*`, timeout 5 s — to 15 Claude Code events in
`~/.claude/settings.json`: `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
`PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `PreCompact`, `PostCompact`.

Settings › System › Claude Code does the same from the window: `Set Up Hooks`
subscribes, `Remove Hooks` unsubscribes. The `Claude Code hooks` row reads
`Enabled` only when all 15 events run the CLI of the app showing the window;
hooks that run another copy of it count as `Disabled`, and `Set Up Hooks`
replaces them. A `settings.json` that cannot be parsed reads `Invalid` in red,
with a warning naming the file, and is never written. Claude Code re-reads
`settings.json` while it runs: sessions already open follow a change within
seconds, without a restart, which the group's note says.

Each event becomes one trimmed line in the journal, enriched with the Claude
process id, the hosting app's bundle id, and the terminal tab's tty. The app
follows the journal. Every session id seen gets its own state.

### States

`idle`, `working`, `done`, and `waiting` with a reason: `question`,
`permission`, `plan` or `error`.

| Event | Result |
|---|---|
| `SessionStart` | `idle`; forgets the session's subagents and background shells. With `source: compact`: `working`, and they are kept. |
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `AskUserQuestion` → `waiting(question)`; `ExitPlanMode` → `waiting(plan)`; any other tool → `working` |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `PreCompact`, `PostCompact` | `working` |
| `PermissionRequest` | `waiting`, reason from the tool name: `AskUserQuestion` → `question`, `ExitPlanMode` → `plan`, else `permission`. A subagent's request raises the same wait. |
| `Notification` `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` | `waiting(permission)`, unless the session already waits for a `question` or a `plan` |
| `Notification` `idle_prompt`, `agent_needs_input` | Never an alert. See "lost Stop" below. |
| other `Notification` types | nothing |
| `Stop` | `done` — or held, see below |
| `StopFailure` | `waiting(error)` |
| `SubagentStart`, other subagent events | mark that subagent live |
| `SubagentStop` | that subagent is no longer live |
| `SessionEnd` | the session is forgotten |

A turn that ends in prose is **finished**, questions included: "Want me to
commit?" is green. Amber is raised only by the explicit signals above.

Subagent events (those carrying an `agent_id`) never speak for the main agent,
with two exceptions: a subagent's permission request blocks the turn and shows
amber, and subagent activity after `done` re-opens the turn as `working`.

### Finishing, and holds

A `Stop` means `done` only if nothing is still out. If the session has a live
subagent or a background shell (from the payload's `background_tasks`, entries
of type `shell`), the strip stays on `working` and the finish is *held*:

- when the last subagent stops and the background set is empty, the turn
  becomes `done` `K.holdGraceSeconds` (90 s) later;
- a subagent that reports nothing for `K.agentStaleSeconds` (240 s) stops
  counting as live;
- a hold never outlasts `K.holdTTLSeconds` (30 min) without an event;
- any new main-agent event cancels the hold.

`waiting` is never held.

### Expiry

- `done` stays lit for `K.doneVisibleSeconds` (20 min), then the session is
  `idle`.
- A session silent for `K.staleSeconds` (2 h) is forgotten.
- A session whose Claude process exits is forgotten at once (kqueue on the
  pid). At launch, sessions whose pid is dead or is no longer a Claude process
  are dropped.

### When hooks say nothing

Esc and Ctrl-C end a turn without any hook, and hook delivery can stop
mid-session. These rescues cover it:

| Situation | Signal | Result | Latency |
|---|---|---|---|
| Lost `Stop` | `idle_prompt` / `agent_needs_input` on a `working` session whose main agent has been quiet ≥ `K.idleSignalMinQuietSeconds` (50 s) | treated as the `Stop` | ~60 s |
| Lost `Stop` | `working`, nothing out, quiet ≥ `K.abandonQuietSeconds` (20 s); Claude's registry says `idle`; the transcript ends on a completed assistant answer (`end_turn` / `stop_sequence`) | `done`, with its push | 20–35 s |
| Interrupted turn | same, but the transcript ends on an unanswered entry | `idle` (dark) | 20–35 s |
| Same, transcript unreadable | — | `idle` after `K.abandonUndecidedDarkSeconds` (90 s) | 90 s |
| Dialog answered with no hook | an open wait; the registry says `busy`, stamped more than `K.dialogAnswerMinStampLeadSeconds` (2 s) after the dialog | `working` | ≤ 15 s + |

While the registry says `busy`, a quiet session is kept alive and stays
`working`. The registry and open waits are re-read every
`K.abandonRecheckSeconds` (15 s) while the condition lasts.

The registry is Claude Code's own `<config>/sessions/<pid>.json`, where
`<config>` is the process's `CLAUDE_CONFIG_DIR` or `~/.claude`. Transcript
entries marked `isSidechain` are ignored.

## 5. Acknowledgement

An alert stays lit until it is seen. Seeing it means: the app that hosts the
session is frontmost and there is input. The triggers are an app activation,
and — only while an alert is on the strip — a poll of input idle time every
`K.inputPollSeconds` (0.5 s) that fires when the last input is under 1 s old.
An alert born while you are already typing in its host is acknowledged before
it is painted.

Scope:

- The session's recorded host app must be the frontmost app.
- If both the frontmost **terminal tab** and the session's tab are known, they
  must match. The front tab is asked of Terminal or iTerm2 through Apple
  Events. Any other terminal, a timeout, or a denied permission means
  "unknown", and the alert is acknowledged at app level.
- A session with no focusable host (one hosted by the Claude Code daemon, or
  whose terminal has quit) is acknowledged by any activity.

Every unknown widens acknowledgement; none can strand an alert.

Acknowledging clears the strip *and* cancels the pending push. It is written to
the journal, so a restart does not resurrect it. A new alert on the same
session is unacknowledged again. Terminal jobs are acknowledged by host app
only, and not persisted.

## 6. Phone notifications (ntfy)

Publish only. One HTTP `POST` per alert to `<server>/<topic>`:

| Part | Value |
|---|---|
| `Title` header | `Claude Code` |
| `Tags` header | `white_check_mark` (finished), `speech_balloon` (question), `lock` (permission), `clipboard` (plan), `rotating_light` (turn failed) |
| `Click` header | `https://claude.ai/code/<bridgeSessionId>` when Claude's session record has one, else `https://claude.ai/code` |
| Body | English: `Finished`, `Asking you something`, `Needs permission`, `Plan ready`, `Turn failed`. French: `Terminé`, `Vous pose une question`, `Demande une permission`, `Plan prêt`, `Échec du tour` |

The title and the tags are protocol values and are never translated; only the
body is (§15). No priority, actions or authorization header. The topic is the only secret: a
generated `cc-` plus 32 hex characters, stored in `config.json` (mode `0600`),
masked to its first six characters everywhere except `mysidepulse notify` and the
Notifications page's reveal.

**When a push fires.** Entering `done` or `waiting` arms a push
`K.notifyDebounceSeconds` (15 s) ahead. A repeated alert of the same kind moves
it forward; any non-alert state, or an acknowledgement, cancels it. When it
comes due:

- **You are present** — input within `K.notifyPresenceIdleSeconds` (60 s) and
  the screen unlocked: deferred by `K.notifyDeferRecheckSeconds` (30 s), again
  and again, until you are not.
- **You are away**: sent — unless it is more than `K.notifyMaxLatenessSeconds`
  (120 s) overdue (the Mac slept, or the app was down), in which case it is
  dropped.
- If idle time cannot be read, you count as away.

A held finish pushes about 105 s after its hold clears (90 s grace + 15 s).

**Muted:** sessions whose Claude record has kind `bg`, `daemon` or
`daemon-worker` light the strip but never push. Terminal jobs never push.

**Failure.** Timeout `K.notifyTimeoutSeconds` (5 s); up to
`K.notifyMaxAttempts` (3) attempts `K.notifyRetryDelaySeconds` (2 s) apart, for
network errors, HTTP 5xx, 408 and 429 only. Any other 4xx is reported once.
Nothing is queued or retried later; a failed push is logged and gone. The strip
is unaffected.

## 7. Terminal jobs

The only other tool wired in is the terminal itself.

- `mysidepulse run [--show-after N] [--label L] -- <cmd…>` runs the command
  through `/usr/bin/env`, shows it on the strip, and exits with its status
  (`128 + signal` if it was killed; 127 if it could not start).
- `eval "$(mysidepulse shell-init zsh)"` installs `preexec` / `precmd` hooks that
  report every command. These jobs appear only after
  `K.shellShowAfterDefaultSeconds` (5 s; `MYSIDEPULSE_SHOW_AFTER`), so short
  commands stay dark. A command line is skipped when the head of *any* of its
  segments (split on `&& || | |& ; & ( ) { }`, quotes and directories stripped)
  is in `MYSIDEPULSE_SKIP` — by default editors, pagers, `ssh`, `tmux`, `top`,
  `watch`, `claude`, `codex`, `grok`, `mysidepulse` and the like.
- Settings › System › Terminal writes that line into `~/.zshrc`:
  `Set Up Terminal Hook` appends a block that opens and closes with
  `# ---------- MySidepulse ----------`, holding a few comment lines and
  `[ -x "<cli>" ] && eval "$("<cli>" shell-init zsh)"` — the CLI by absolute
  path, guarded so a shell stays silent when the app is gone. The `Terminal
  hook` row reads `Enabled` when the file holds that header or any uncommented
  MySidepulse `shell-init zsh` line. `Remove Terminal Hook` deletes everything between the two header
  lines, and any such line outside them; nothing else — not another tool's
  block, not a commented copy. Own lines belong below the closing header:
  there `MYSIDEPULSE_SKIP+=(cswap)` extends the default list instead of
  replacing it, and survives `Remove`. A `~/.zshrc` that is not UTF-8 is left
  untouched. A new terminal is needed either way.

One job per shell: a new one replaces the previous. Exit 0 → succeeded, green;
anything else → failed, amber; exit 130 or 131 (Ctrl-C, Ctrl-\) → removed
silently. A job that ends before it became visible is never shown. Outcomes
stay for `K.jobVisibleSeconds` (20 min) or until acknowledged; a running job
whose owner process dies is removed; a job that never reports back expires
after `K.jobStaleSeconds` (2 h). If the app is not running, the command runs
all the same.

Claude outranks a job at every rung, so a running job's colour is hidden while
Claude works; a job *outcome* takes the alert zone over Claude's roll.

## 8. Battery

Read from IOKit (internal battery only), on change and every
`K.powerRefreshSeconds` (300 s). Critical is ≤ 15 % while not plugged, charging
or charged. The glance bar is red ≤ 15 %, amber ≤ 50 %, green above. A reading
without a capacity value counts as no reading, never as 0 %.

## 9. Menu

Every title below is quoted in English; the French is in the code, and §15 says
which language is shown. The status item's icon never changes. It is shown unless `Show in menu bar` is
turned off in Settings › General; hidden, the app runs exactly as before and is
reached by opening it again (§10). The menu, rebuilt on every open:

- `LEDs: Auto`, `LEDs: Off` (check mark on the active one), plus a checked
  `LEDs: #rrggbb (forced)` or `LEDs: <name> (effect)` line when that is the mode
- `Open at Login` — also the crash-restart switch
- three status lines: strip (`name · n LEDs`, `· stalled`), sessions by state,
  age of the last hook event
- `Settings…` (⌘,) and `Quit MySidepulse` (⌘Q)

Quitting — from this menu, from ⌘Q, or from Settings › General — turns every
attached strip off first, then exits. A lit strip means something only while
MySidepulse is watching, so none is left behind. The wait for the strips is
bounded by `K.quitBlackoutSeconds` (1.5 s): a card that has stopped answering
never answers, and the app quits anyway. The exit is a clean one, so the launch
agent leaves MySidepulse stopped; the next login starts it again (§10).

## 10. Settings window

Opened from the menu-bar item (`Settings…`, ⌘,) and by opening the app again —
Finder, Spotlight, the Dock — which is the way back in when the menu-bar item
is hidden. While the window is open the app has a Dock icon, a ⌘-Tab entry and
a main menu with `Quit MySidepulse`; closing it removes them.

**A reinstall does not open it.** `scripts/install.sh` opens the bundle for its
own reasons, and the window that got was one nobody asked for, so it writes a
marker under `~/Library/Application Support/MySidepulse/` first. An update does
the same before it quits (§ Updates): the launch the helper makes is nobody's
request either, and the only window it opens is the one saying how the install
ended. An unread install outcome says it a second way, which holds whatever
version wrote it: a launch that finds one is that install's, marker or no
marker. The launch that
follows reads it, removes it and remembers the moment. **The open request
outlives the process it was sent to:** that launch bootstraps the agent and
hands over (*Handing over to launchd*), so it quits within the second and the
request is delivered again to the copy launchd starts in its place. An open
request within 15 s of a quiet launch is therefore that install's and opens
nothing; a marker lapses after two minutes, and neither is long enough to
swallow a double-click the user means (`QuietLaunch`).

**The copy that hands over does not remove the marker**, because it is not the
copy that will receive the request: it leaves it for the one launchd starts, and
whichever copy stays removes it, so the next launch, which is a person, opens
the window as it always did. And the installer writes the marker **before
anything can start the app**, and stops the running copy with `launchctl
bootout` rather than a signal: a signal is a non-zero exit, which is what
`KeepAlive` exists to restart, and launchd would bring the app back from the old
bundle mid-install, never having seen the marker.

Every title, label and sentence in this section is quoted in English. Each one
also exists in French, in `Sources/MySidepulseCore/Strings*.swift` (§15).

**Seven pages, picked from a toolbar** that draws each page's symbol above its
title: *General*, *Strip*, *Notifications*, *Playground*, *Health*, *Tip*,
*System*.
The window's title is the shown page's. The window is **640 pt** wide and **as
tall as the shown page**: it resizes around its top-left corner, animated, on a
page switch and whenever a page gains or loses a line, and never grows past the
display's visible height less **140 pt**, beyond which the page scrolls. It
opens on General, already at that page's height and centred.

| Page | Group | Control | Default |
|---|---|---|---|
| General | Startup | Open at login and reopen after a crash | on (the launch agent, §12) |
| General | Startup | Show in menu bar | on |
| General | Updates | `MySidepulse <version>` and one button (below); the app also checks on its own, and Update opens the update window | |
| General | Quit | `Quit MySidepulse` | |
| General | Uninstall | `Uninstall MySidepulse` under a hint, with a warning that always stands there | |
| Strip | Right now | the live strip, and a `Showing` row saying what it shows and why | |
| Strip | What the strip shows | Auto · Off · Colour · Effect; with Colour a colour picker, with Effect six picture tiles | Auto |
| Strip | Strip | one row per attached strip, `Available` or `Stalled`, each with a brightness slider (1–255, applied on release; 255 stores nothing) | 255 |
| Strip | Remembered brightness | the overrides of strips not plugged in, each with `Forget` | |
| Notifications | Phone | Notify my phone when Claude finishes or needs you | off |
| Notifications | Server | the ntfy server, applied on Return | `https://ntfy.sh` |
| Notifications | Topic | the masked topic; `Reveal Topic and QR Code`; `New Topic…` | |
| Notifications | Test | `Send a Test Notification`, and its result | |
| Playground | On the strip | the live strip, what is playing, `Keep It` and `Stop` | |
| Playground | States, Effects | nine state tiles and six effect tiles | |
| Health | Checks | seven of the `doctor` checks, `Check Again` | |
| Health | Right now | last hook event, battery, one row per session and per command | |
| Health | Report | `Copy Report` | |
| System | Claude Code | `Claude Code hooks`, `Set Up Hooks` or `Remove Hooks` (§4 *Source*) | |
| System | Terminal | `Terminal hook`, `Set Up Terminal Hook` or `Remove Terminal Hook` (§7) | |

Every change is written as it is made; there is no Apply. While the window is
open every row that reports the engine is re-read every **2 s**; the two hook
rows are re-read when the window opens, when System is shown and after each of
its buttons.

### How every page is built

**Every group is a title, a card of rows, and under the card — outside it — a
hint, then warnings, then notes.** A row is a control and its label and nothing
else, so what a setting does is said once, under its card. The **hint** says
what the group does, in the secondary colour. A **warning** asks the user to fix
something: an orange line behind a triangle, there only while the thing is
wrong. A **note** is the one thing the user must not miss: a blue line behind an
info mark. A group with nothing to say has none of the three.

**A state is always one row**: what is reported on the left, in ordinary text,
and at the trailing edge a symbol and one word — or a short sentence, which
wraps — both in the state's colour. Five marks, each keeping its symbol and its
colour on every page: a **green checkmark** for what is as it should be, a
**blue info mark** for what is worth knowing, an **orange triangle** for what is
to be fixed or did not work, a **red cross** for what was refused or is wrong,
and a **spinner** for what is still happening. The words are a fixed
vocabulary: Enabled / Disabled, Available / Missing, Valid / Invalid, Failed,
Sent, Downloaded, Stalled, Checking, Downloading.

**The copy has four rules.** Every text is the default size — body, bold for a
group's title, monospaced for what is code — and nothing is smaller. A keyboard
key is written symbol first. No sentence the user reads carries a dash other
than the keyboard's hyphen. And sentences are short, written for a person
rather than for a developer, and say what a switch costs wherever it costs
something.

**No choice is a radio group or a pop-up menu.** The mode is a segmented
control; the effect and the Playground's states and effects are picture tiles,
each tile the animated strip itself, three to a row, the selected one tinted
and ringed. The hint under a group of tiles describes the selected tile only.
A number the user sets — brightness, the glance's battery level — is a row with
a slider at the trailing edge and its value beside it. The rules in full, with
every spacing number, are the `building-settings-pages` skill.

### What the pages say

**General opens with the app's icon**, 144 pt, centred. Startup's switch reads
from and writes to the launch agent (§12): the hint says what Off costs (a
crash leaves the strip frozen and the phone silent), the note names the way
back to this window with the icon hidden (the Applications folder, Spotlight),
and while this process is not the one launchd started an orange warning says a
crash would not bring it back until the next login. **That warning should not be
what a fresh install shows**, and does not: see *Handing over to launchd* below.

**Strip's `Showing` row** carries the sentence of `StatusCopy` (Core) for the
display state, in the state's tone: blue for working, a job running, the
battery glance, a forced colour or effect and a dark strip; green for a finish;
orange for needs-you; red for a failed command or a critical battery. With
Colour chosen, the hex sits beside the picker; with Effect, the six tiles, the
shown one selected. Each attached strip is `<name>, <n> LEDs` **Available** in
green, with its mount path as the tooltip, or **Stalled** in orange with a
warning under the group saying the write will clear by itself or on a replug.
With no strip, the row is `SidePulse strip` **Missing** in orange and the hint
says to plug one into the SD card slot. Brightness of a strip that is not
plugged in stays as `<name>` and its value, with **Forget**.

**Notifications** shows Server, Topic and Test only while the switch is on;
turning it on reveals the topic (§6). The note under Phone says the ntfy app
must be subscribed to the topic. A server that cannot be posted to is an
orange warning under Server. Revealing shows the topic in monospace, the QR
code, `Copy Topic`, `Copy Link` and `Hide`, with a note that whoever scans the
code can read the notifications; the reveal ends when the page or the window
is left. `New Topic…` asks first, then reveals the new topic under an orange
warning that the phone is not subscribed to it yet, gone with Hide. The test's
row reads **Sent** in green or **Could not send: <reason>** in orange.

**Playground** previews any state or effect on the real strip for 30 s
(`Engine.previewSeconds`). A preview replaces what is painted only: alerts,
acknowledgement and pushes carry on underneath. Clicking a tile plays it and
selects it; clicking it again, `Stop`, leaving the page or closing the window
ends it. While playing, the row under the strip reads **Playing** with a spinner
and the seconds left, then **Ended** when the 30 s run out; the group's hint
under the tiles is the selected tile's sentence. Battery glance adds a battery
level slider, A colour adds a colour picker. `Keep It`, offered for an effect
or a colour, makes it the mode (§3).

**Health** shows seven of `doctor`'s nine checks as rows, each check's detail as
the row's tooltip: MySidepulse app (Available / Missing), Open at login and
crash restart (Enabled / Disabled), Claude Code hooks (Enabled / Disabled), Hook
command (Valid / Invalid, the installed command as the tooltip), Journal
(Available / Failed), SidePulse strip (Available / Stalled / Missing), Phone
notifications (Enabled, Disabled in green when off, Invalid). The `hook
command` check is that tooltip and the `last event` check is Right now's first
row. `Check Again` runs the doctor off the main queue; it also runs when the
page is shown. `Copy Report` puts the checks and the state on the clipboard with
the topic masked.

**System** holds the two hooks. `Claude Code hooks` is **Enabled** in green,
**Disabled** in orange with a warning to press Set Up Hooks, or **Invalid** in
red when `~/.claude/settings.json` cannot be read; the note says open sessions
pick new hooks up on their own. `Terminal hook` is **Enabled** in green or
**Disabled** in blue, because it is optional; the note says to open a new
terminal window after setting it up. A set-up or removal that fails shows the
installer's message as a warning under its group.

### Updates

The second group of General, and the only thing in the app, with ntfy, that
uses the network. Its first row is `MySidepulse <version>`
(`CFBundleShortVersionString`) and its second a single button, **Check for
Updates**.

**The app also looks on its own**: once `K.updateLaunchDelaySeconds` (10 s)
after launch, then `K.updateIntervalSeconds` (a week) after the last check that
got an answer, whoever asked (`UpdateSchedule`). The question is put on a
`K.updateTickSeconds` (30 min) tick and at every wake rather than on one
week-long timer, so a Mac asleep on the date is asked as soon as it is awake. A
check that could not reach GitHub is silent and tried again at the first tick
`K.updateRetryDelaySeconds` (an hour) or more later, so 60 to 90 minutes on.
Nothing is fetched or installed without a click.

Either kind of check sends one anonymous request to GitHub for the latest
release of `bambidotexe/my-sidepulse` (timeout `K.updateCheckTimeoutSeconds`,
15 s), and the answer is the version row's mark (`UpdatePanel`):

| The moment | The version row's mark | The button |
|---|---|---|
| before the first answer | none | Check for Updates |
| asking, because the button was pressed | a spinner and **Checking** | disabled |
| a release that is this version or older, or a running version that does not parse (any binary started outside its bundle), whoever asked | green **Up to date** | Check for Updates |
| a release whose tag is strictly newer, whoever asked | blue **Version <v> is available** | **Update**, prominent and blue |
| 404, to a press: no release, or a repository GitHub does not show anonymously | orange **No release published yet** | Check for Updates |
| any other status, no network, a reply that is not a release, to a press | orange **Could not check: <reason>** | Check for Updates |
| the last **Install and Relaunch** did not end with the new version running | orange **Update failed: <reason>** | Check for Updates, and **Update** again once a check has found the release |

An automatic check shows no spinner; its failure, and a 404, change nothing
here. A press while an automatic check is in flight adopts that check's answer
instead of starting a second request. The group has no hint.

A release counts only if its tag parses as a version (`v1.8.0` or `1.8.0`,
compared number by number, a missing part counting as 0) and it carries an
asset whose name ends in `.dmg`.

**An automatic check that finds a newer release posts one notification on this
Mac**, **Version <v> is available**, with an **Update** button; a later check's
notification replaces it. It is the only notification the app posts here: what
Claude Code is doing goes to the strip and to ntfy, never to Notification
Center. macOS asks for the permission the first time there is a release to
announce, not at launch; refused, the release shows in Settings all the same.
The button, and a click on the notification itself, do what **Update** does in
Settings. A notification left by an earlier run asks GitHub first, then opens
the update window on the answer, or Settings when nothing is newer.

**The update window.** **Update** opens one small window titled **Software
Update** and starts fetching at once: the app icon, `MySidepulse <v>`, one
status line, a bar, **Cancel** and **Install and Relaunch**, which stays
disabled until the update is ready. Pressing **Update** again, anywhere, shows
that same window (`UpdateSession`).

| Phase | The status line | The bar | The buttons |
|---|---|---|---|
| fetching | **Downloading: 1.2 MB of 2.8 MB**; **Downloading** when no total is known | follows the bytes | Cancel · Install and Relaunch, disabled |
| making it ready | **Preparing the update** | indeterminate | the same |
| ready | **Ready to install. MySidepulse will quit and reopen.** | full | Cancel · **Install and Relaunch** |
| it cannot replace itself | **MySidepulse cannot replace itself where it is installed. Open the disk image and drag MySidepulse to Applications, then quit and reopen it.** | none | Cancel · **Open Disk Image** |
| installing | **Installing** | indeterminate | both disabled; the window does not close |
| failed | **Update failed: <reason>** | none | Close · **Try Again**, which fetches again |

Everything that can refuse an update happens while making it ready, with the
app still running. The fetched file,
`~/Library/Application Support/MySidepulse/updates/MySidepulse-<v>.dmg`, is held
against the length and the SHA-256 GitHub states for the asset; the disk image
is mounted read-only and hidden; the app in it that carries MySidepulse's
bundle identifier is copied to `updates/staged/`; that copy must be strictly
newer than the running version, ask for no newer macOS than this one, and carry
an intact signature. The running app carries the Wooflab team's identifier, so
an update copy is additionally held to a requirement on that same team and is
refused otherwise, whatever else about it checks out. The app cannot replace
itself when it does not run from an `.app`,
runs translocated, cannot write to its folder or its bundle, or sits on another
volume than its Application Support folder; the window then offers the disk
image, which macOS mounts and shows with its Applications link. **Cancel** and
the window's close button stop the fetch and delete what was fetched.

**Install and Relaunch** starts a helper (`UpdateInstallScript`, a shell script
in a process group of its own) and quits the app the way every quit does, so
the strip goes dark first (§ Quitting). The helper touches nothing until the
app is gone. If the app is still there `K.updateStallNoticeSeconds` (20 s)
after the click, it stops the helper, so that a quit that comes later is only
ever a quit, and the window says **MySidepulse did not quit. Close its open
dialogs, then try again.** with the update still ready; the helper's own limit,
`K.updateQuitWaitSeconds` (30 s), only serves an app too hung to do that. Once
the app is gone the helper moves the installed bundle to
`updates/previous/`, moves the new one into its place (a failed move puts the
previous one back), writes the outcome, and starts the app: **through the launch
agent whenever the agent is installed** (`launchctl kickstart`), so the new
version has its crash restart and never has to change hands, and with `open`
when there is no agent or launchd will not start it. It looks for the new
executable among the running processes for `K.updateLaunchWaitSeconds` (15 s),
by the path it was installed at or by the one the system knows that folder by.
Seen, it looks once more `K.updateSettleSeconds` (2 s) later: still there, or
gone after having read the outcome (the user quit it, which is their business),
the previous copy is deleted. Gone without that mark it is looked for again, for
as long as the first look lasted, because an app that hands itself to launchd
quits so that the job's own copy can take its place and nothing runs in between.
Never seen, not startable, or still gone at the end of that second look (it
crashed on its way up), the new copy is moved out, the previous one moved back
and started the same way. Nothing is ever deleted to make room: when the
previous copy cannot be moved back it stays in `updates/previous/`, and the
outcome says so.

The install also writes the quiet-launch marker before it quits, so the launch
the helper makes opens no window of its own (§10).

The next launch reads the outcome, leaves `result.read` in its place for the
helper, and says how it ended in the update window, which is the whole news:
after an install, **MySidepulse 1.2.0** and **The update is installed.
MySidepulse is running the new version.** with one button, **Done**; after a
failure, the version that is still running and **Version 1.2.0 was not
installed.** followed by the reason, with one button, **Close**, and the Updates
group of Settings carries the same reason as its orange mark. **Nothing else
opens**: no Settings window behind it. The three reasons are **The new version
could not be put in place.**, **The new version did not start, so the previous
one was put back.** or **The new version did not start and the previous one
could not be put back. Download MySidepulse again.** An outcome older than
`K.updateResultShelfLifeSeconds` (10 min) was left behind by an install nobody
is waiting on any more: it is logged and opens nothing. The hooks and the launch agent name the bundle by its path, which does
not change. The shipped build's code identity is the Wooflab team's Developer
ID and stays the same across versions, so an update does not by itself give
macOS a reason to ask for the Automation permission again. Checks, the fetch,
the unpacking and the hand-over are logged with an `update` prefix; the helper
keeps its own account in
`updates/install.log`.

### Supporting the app

**Tip** is a page of its own, between Health and System, and it holds two cards.
The first has no title: the app's icon beside the sentence saying every feature is
free to everyone and always will be, and that a coffee is how the project is
supported. The second is **One-time tip**: the Ko-fi cup on a wash of its own red,
*A cup of coffee* with a line saying what it is, and a button naming the smallest
tip the page takes (`SupportLink.smallestTip`, 5 €). Under the card, one hint says
the browser opens and that any larger amount is typed on the page itself.

The button opens `https://ko-fi.com/bambidotexe` in the default browser and nothing
else moves: the app stores nothing about it, reads nothing back, pays nothing
itself, and shows the page whatever the state of anything else. The address and the
amount are `SupportLink` in Core, the same page for every app of this author.

These two cards hold pictures and sentences rather than controls, which no other
page does, and the first has no title at all. The owner asked for that look; every
other page keeps the rule that a row is a control and its label and that nothing
explanatory goes inside a card.

### Quitting

The last group of General is a single **Quit MySidepulse** button, styled as
destructive, with no hint and no note. It quits at once, with no confirmation,
through the same path as ⌘Q and the menu-bar item (§9): every strip goes dark,
the app exits zero, and the launch agent leaves it stopped until the next login.

### Uninstalling

Under Quit sits **Uninstall**, one destructive **Uninstall MySidepulse** button
under a hint, with an orange warning that always stands there. The warning is
not a state that can be put right but the hazard of the other way out:
**dragging the bundle to the Trash is not an uninstall.** It removes the app and
nothing else, and launchd goes on trying to start a binary that is not there at
every login, the Claude Code hooks fire at a missing command once per event, the
zsh line runs at every shell, and the journal, the settings and the ntfy topic
stay in Application Support.

The button asks for confirmation, then, in this order:

1. removes the Claude Code hooks, the zsh line and the settings backup the hooks
   left, while the binary they name is still inside the bundle;
2. deletes `~/Library/LaunchAgents/io.mysidepulse.agent.plist`, so nothing loads
   at the next login even if step 6 never runs, and unregisters any
   `SMAppService` login item an older install left;
3. resets the Apple Events grant and the notification authorization, while the
   bundle they name is still where they name it (`tccutil reset` against a
   bundle identifier with no bundle behind it fails, and nothing puts that right
   afterwards; the notification grant has no public reset at all, so its entry is
   dropped from usernoted's own preferences and the daemon restarted);
4. names `/usr/local/bin/mysidepulse` if it is there, with the one `sudo` line
   that removes it: `/usr/local/bin` is root-owned and the app cannot;
5. moves the bundle to the Trash, not to a delete: what was just removed is
   still there to put back;
6. starts a detached helper, says what it could not remove, and quits through
   the same path as ⌘Q, so every strip goes dark first.

**Steps 1 to 5 cannot do the last two things, and that is what the helper is
for.** This process is usually the launch agent's own job, so
`launchctl bootout` on it would kill it where it stands, before the strip had
been darkened; and removing the support folder while the app is still up only
means the journal writes it back. So the helper waits for the pid to go, for at
most a minute, then boots out both `io.mysidepulse.agent` and the former name's
`io.sidepulse.agent`, deletes the preferences domain and removes
`~/Library/Application Support/MySidepulse/`, the preferences file, the ByHost
preferences, the caches, the HTTP storage and the saved window state, all of
which are named after the bundle identifier and belong to nothing else. The
preferences are the helper's too because `cfprefsd` writes the domain out again
as a process exits, leaving an empty plist where a Mac that never had
MySidepulse has no file at all. It boots out and never disables:
`launchctl disable` writes an override that survives a reboot and that nothing
but `launchctl enable` clears (`pitfalls.md`).

## 11. CLI

Every command prints English, whatever the system language is, and that is a
rule rather than a gap (§15).

`mysidepulse`, at `/Applications/MySidepulse.app/Contents/MacOS/mysidepulse`.

| Command | Does | Exit |
|---|---|---|
| `hook` | Claude Code's hook entry; reads the payload on stdin | always 0 |
| `led auto\|off\|toggle\|#RRGGBB\|<effect>` | sets the mode; `toggle` flips off ↔ auto | 0; 1 app down; 2 bad argument |
| `status [--json]` | mode, display, battery, strips, sessions, jobs, notifications (topic masked) | 0; 1 app down |
| `doctor` | nine health checks | number of failures |
| `install-hooks` / `uninstall-hooks` | edits `~/.claude/settings.json`, after a backup to `settings.json.backup-mysidepulse`; foreign hooks and shapes it does not recognise are left alone; refused, file untouched, when the CLI is not inside an app bundle | 0; 1 if any of the 15 events was declined, or on error |
| `run …`, `job begin\|end …` | terminal jobs | the command's status; 2 bad usage |
| `notify [on\|off\|topic new\|topic T\|server URL\|test]` | notification settings; bare `notify` prints them, **including the full topic** | 0; 1; 2 |
| `autostart [on\|off]` | the launch agent | 0; 1; 2 |
| `shell-init zsh` | prints the zsh snippet | 0; 2 |

With no arguments it prints usage and exits 0.

`doctor` checks: app reachable; auto-start & restart (this process is the one
launchd supervises); hooks installed (all 15); hook binary exists; hook command
(informational); journal writable; last event age (informational); strips
(informational, shows `STALLED`); notifications (fails only on an unusable
server or topic).

## 12. Settings, permissions, failure modes

**Defaults:** mode `auto`; brightness 255; launch agent registered on first
launch; notifications off; server `https://ntfy.sh`; menu-bar item shown.
Storage is described in [architecture.md](architecture.md#persistence).

### Handing over to launchd

Any launch that did not come from the agent writes the plist and bootstraps the
job, so that it always points at the copy that is running. `RunAtLoad` then makes
launchd spawn the job at once, and **that spawn finds this instance already
running and terminates itself**, as any second copy must: two would fight over
the control socket and the journal. What is left is a job loaded with nothing
running, and an app that LaunchServices started, which `KeepAlive` does not
supervise. A crash would then cost the rest of the day, and `doctor` says
`agent installed, but this process was not started by it`.

So the app hands over. Straight after bootstrapping, and before the menu bar and
the strip are built, it starts a detached helper and quits: the helper waits for
the pid to go, runs `launchctl kickstart` on the job, and launchd starts the copy
it supervises. To the user this is a blink.

**A hand-over that fails must never leave a Mac with no MySidepulse on it.** If
the job has not come up five seconds after the kickstart, the helper opens the
bundle again, which puts things back exactly as they were: the app runs, and
Startup carries the orange warning. The hand-over is skipped when launchd started
this process (there is nothing to hand over) and when the switch is off (the
owner has said they do not want the agent).

**A hand-over during an update is not a crash.** The update helper reads a new
version that is gone without having read the outcome as one that crashed on its
way up, and puts the previous one back. A copy that is about to hand over has
started perfectly well, so it leaves the mark that says so (`result.read`) and
leaves the outcome itself for the copy launchd starts, which is the one that
opens the window saying how the install ended.

**Environment:** `MYSIDEPULSE_DISABLE=1` makes `hook` do nothing.
`MYSIDEPULSE_SKIP` and `MYSIDEPULSE_SHOW_AFTER` tune the zsh hooks.
`MYSIDEPULSE_REPLAY_JOURNAL` names a journal for `RealJournalReplayTests`.

**Permissions** (details in [macOS.md](macOS.md)):

| Permission | Used for | If denied |
|---|---|---|
| Removable volumes | writing `LEDS.LED` and `keepalive` | the strip stays as the device left it |
| Automation (Terminal, iTerm2) | asking which tab is in front | acknowledgement covers the whole terminal app instead of one tab; logged once |
| Network | ntfy; GitHub, for the update check (at launch, weekly, and on a press) and for the download a click on Update asks for | pushes fail and are logged; the version row under Updates says why a press could not check |
| Notifications | announcing a newer release found by an automatic check, and nothing else; asked for the first time there is one | no notification; the release shows in Settings all the same |

No Accessibility or Full Disk Access permission is used.

**The app does not:** subscribe to ntfy, or receive anything from the network
but the reply to an update check and the download a click on Update asked
for; fetch or install an update by itself (an automatic check only announces a
release);
read prompts, tool inputs or tool outputs (the hook drops them before writing);
change anything in Claude Code beyond its own hook entries, or in `~/.zshrc`
beyond its own block; push for terminal jobs; identify which session an alert
belongs to on the strip.

## 13. Every delay and threshold

| Constant | Value | Role |
|---|---|---|
| `alertSettleSeconds` | 1 s | alert must stand before it is painted |
| `doneVisibleSeconds` | 20 min | finished stays lit |
| `holdGraceSeconds` | 90 s | held finish → done after the last helper clears |
| `holdTTLSeconds` | 30 min | longest hold without an event |
| `agentStaleSeconds` | 240 s | silent subagent stops counting |
| `staleSeconds` | 2 h | silent session forgotten |
| `idleSignalMinQuietSeconds` | 50 s | quiet needed before `idle_prompt` counts as a lost Stop |
| `abandonQuietSeconds` | 20 s | quiet before Claude's registry is consulted |
| `abandonRecheckSeconds` | 15 s | registry / open-wait recheck |
| `abandonUndecidedDarkSeconds` | 90 s | dark when the transcript cannot decide |
| `dialogAnswerMinStampLeadSeconds` | 2 s | busy stamp must be this much newer than the dialog |
| `hooksSilentWarnSeconds` | 5 min | registry `busy` with no hook event → one log warning per session |
| `inputPollSeconds` | 0.5 s | input poll while an alert shows |
| `ttyProbeTimeoutSeconds` / `ttyProbeCacheSeconds` | 0.5 s / 2 s | front-tab probe |
| `notifyDebounceSeconds` | 15 s | alert age before a push |
| `notifyPresenceIdleSeconds` | 60 s | input idle that means "away" |
| `notifyDeferRecheckSeconds` | 30 s | push deferral while present |
| `notifyMaxLatenessSeconds` | 120 s | overdue push dropped |
| `notifyTimeoutSeconds` / `notifyMaxAttempts` / `notifyRetryDelaySeconds` | 5 s / 3 / 2 s | ntfy delivery |
| `updateCheckTimeoutSeconds` | 15 s | an update check's wait for GitHub |
| `updateLaunchDelaySeconds` / `updateIntervalSeconds` | 10 s / 7 days | the automatic check: after launch, then after the last answer |
| `updateRetryDelaySeconds` / `updateTickSeconds` | 1 h / 30 min | the wait before a failed check may be retried; how often the app asks whether a check is due, which puts the retry 60 to 90 min after the failure |
| `updateStallNoticeSeconds` | 20 s | an app still running that long after Install and Relaunch stops the helper and says it did not quit |
| `updateQuitWaitSeconds` / `updateLaunchWaitSeconds` / `updateSettleSeconds` | 30 s / 15 s / 2 s | the install helper: its own limit on the quit, for the new version to show, and when it looks once more |
| `updateResultShelfLifeSeconds` | 10 min | how long an install's outcome is news at a launch |
| `jobVisibleSeconds` / `jobStaleSeconds` | 20 min / 2 h | job outcome lit / orphaned job |
| `jobShowAfterDefaultSeconds` / `shellShowAfterDefaultSeconds` | 0 s / 5 s | delay before a job shows (`run` / zsh hooks) |
| `glanceSeconds` | 7 s | battery glance |
| `batteryCriticalPercent` / `batteryMidPercent` | 15 % / 50 % | battery bands |
| `keepaliveSeconds` | 60 s | keepalive touch |
| `keepaliveTouchTimeoutSeconds` / `keepaliveMaxOutstandingTouches` | 5 s / 3 | touch kill timer / outstanding cap |
| `writeWatchdogSeconds` | 2 s | LED write watchdog |
| `quitBlackoutSeconds` | 1.5 s | quitting waits this long for the strips to go dark |
| `deviceRescanSeconds` / `deviceSessionRetrySeconds` | 300 s / 30 s | `/Volumes` rescan / DiskArbitration retry |
| `ejectRemountRetrySeconds` | 5 s | remount after a vetoed eject |
| `powerRefreshSeconds` | 300 s | battery refresh |
| `controlRetrySeconds` | 30 s | control socket bind retry |
| `journalSoftMaxBytes` / `journalHardMaxBytes` | 5 MB / 20 MB | journal rotation |
| `journalLineMaxBytes` / `hookStdinMaxBytes` / `messageTailMaxChars` | 4096 / 8 MB / 500 | hook and journal caps |
| `playgroundPreviewSeconds` | 30 s | a Playground state or effect holds the strip this long, and the page's hint says the number |
| Settings status refresh | 2 s | the window re-reads the engine while open (`SettingsModel`) |

LED colours and animation timings are in [device.md](device.md).

## 14. Unconfirmed — ask the owner

- Whether macOS actually shows the removable-volumes consent prompt for this
  app has not been observed; `NSRemovableVolumesUsageDescription` is declared in
  case it does.
- Whether Claude Code fires `PostToolUse` or `PostToolUseFailure` when a
  standing dialog is cancelled with Esc is not established. If it does not,
  that amber stays up until the next prompt or the 2 h backstop
  ([pitfalls.md](pitfalls.md)).
- `Download and open…` has never met a real release: none is published, and
  the repository is private, which the anonymous check cannot see into.
  Whether macOS opens the app from a DMG this app downloaded without a
  Gatekeeper prompt is not established end to end, though the shipped build
  is signed with the Wooflab team's Developer ID and notarized, which is what
  a Gatekeeper prompt on a downloaded, quarantined file would otherwise need.

## 15. Language

Everything the app shows a person exists in **English and French**. Nothing is
half translated: a string cannot be added in one language without the other,
because every table answers for every language or the code does not compile.

**Which one.** At launch the app reads the system's preferred language and keeps
the answer for the rest of the run. French when its primary subtag is `fr`, so
`fr`, `fr-FR` and `fr-CA` are all French and `fry` (Frisian) is not. **Every
other language is English**, which is the fallback for everything. There is no
setting and nothing is persisted: change the system language, or launch with
`-AppleLanguages "(fr)"`, and the next start follows.

**What is translated.** The menu-bar menu (§9), the main menu the window puts up,
all six Settings pages and every sentence on them (§10), the `Showing`
sentences, the doctor's detail sentences and the hook-install outcomes as the
window shows them, and the phone push bodies (§6).

**What is not, and why.**

| Stays as it is | Because |
|---|---|
| Every word `mysidepulse` prints in a terminal (§11) | The CLI is English by rule, not by omission. The same code produces the doctor's details for both, and the language is read where the sentence is built, so the window is French while the terminal stays English. |
| The doctor's nine check names (`app`, `hooks installed`, `device`, …) | Identifiers the CLI prints and the Health page matches on, not prose. |
| The Health page's `Copy Report` text | A diagnostic dump to paste into a bug report, built like the CLI's output. |
| The push `Title` header (`Claude Code`) and the five tags | Wire values. A translated tag loses the notification's icon on the phone. |
| The block in `~/.zshrc` and the shell snippet | Shell code, read by zsh. |
| `MySidepulse`, `SidePulse`, `Claude Code`, `ntfy`, `LED`, `LEDs`, `Terminal`, `iTerm2`, `Finder`, `zsh`, `Dock`, `Spotlight` | Product names. |
| The log | Written for a bug report, in one language so it can be searched. |

**Where the words live.** `Sources/MySidepulseCore/Strings*.swift`, one table per
surface, each string a single accessor that switches over the language, so the
two versions sit next to each other. `Localization.swift` holds the rule that
turns a system language tag into one of ours and the ambient switch every table
reads. Core holds the words and the rule; only `MySidepulseApp` asks the system
what the language is, and only once, in `main.swift`. `LocalizationTests` pins
the rule and reads the tables off disk to check the window's text rules in both
languages.

**The two permission sentences** macOS itself shows
(`NSRemovableVolumesUsageDescription`, `NSAppleEventsUsageDescription`) cannot
live in a Swift table, because macOS reads them from the bundle rather than from
the running app. They ship as `Contents/Resources/{en,fr}.lproj/InfoPlist.strings`,
written by `scripts/make-app.sh`, with the `Info.plist` values left as the
English fallback.
