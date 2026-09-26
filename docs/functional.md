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
things are visible at a glance: an agent is **working**, an agent has
**finished**, an agent **needs you**. The agents are Claude Code, Codex,
GitHub Copilot and OpenCode, in that order everywhere they are listed. Each
works in a colour of its own (Claude red, Codex blue, Copilot another blue,
OpenCode another red): a wave several agents share takes one colour per pass
wherever those passes fit the strip's program, and otherwise gives each LED
one agent's colour. Finished
and needs you are one colour whoever raised them, because they say that the
Mac wants the user, not which agent does. When nobody is at the machine, the
same finished / needs-you alerts go to a phone through ntfy, titled with the
agent's name. Around that core it also shows terminal jobs, the battery, and a
few decorative effects. It reads the agents through their hooks (§4): Claude
Code's and Codex's hook entries, Copilot's hook file and OpenCode's plugin. It
never talks to any agent and sends nothing but the ntfy
pushes off the machine. Everything it shows, and everything it
pushes, is in English or French, chosen from the system language (§15).

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

1. an agent session, whichever agent's, waiting for you → amber double blink;
2. a terminal job that failed → amber double blink;
3. an agent session that finished → green breath, 4.5 s;
4. a terminal job that succeeded → green breath.

**Work** is the first of these that exists:

1. an agent session working — or an *acknowledged* open wait that still has
   subagents or background shells running behind it → the rolling wave, in
   the working agent's colour: Claude's red, Codex's blue, Copilot's blue,
   OpenCode's red. When several agents work at once, **one pass in each
   one's colour, in turn, wherever those passes fit the strip's program**
   (512 bytes, 20 lines), and **one pass whose LEDs take their colours**,
   LED *i* in the colour of agent *i* mod *n*, **where they do not**. On the
   Pro's eight LEDs two agents keep their passes and three or four alternate
   by LED (three passes would be 741 bytes); on the Dot's two LEDs every
   number of agents keeps its passes (four are 294 bytes). The agents go in
   their order, Claude's first, and the rhythm is unchanged;
2. a terminal job running → rolling violet wave.

Every agent shares every rung: the strip says that an agent wants the user,
not which one. The Showing sentence (§10) and the push (§6) name the agent.

In a split, a needs-you alert takes `K.alertZoneLedsNeedsYou` (3) LEDs and a
finished alert `K.alertZoneLedsFinished` (2); at least one LED always stays
with the work. The amber zone blinks in the same 1.5 s rhythm as the full-strip
blink; the green zone holds steady. A roll shared by several agents under a
zone alternates its colour **by LED**, whatever their number: two passes of
blink lines and roll lines would not fit in the strip's program
([device.md](device.md)). Two agents alternate from the roll's first LED,
Claude's first; three or four give LED *i* agent *i* mod *n*'s colour, the
colour it has on the whole strip's roll by LED, so a zone opening or closing
over that roll leaves every LED with its agent.

With several sessions the strip does not say which one: the most urgent alert
and the most active work win. `mysidepulse status` lists them individually.

**Settle.** An alert must stand for `K.alertSettleSeconds` (1 s) before it
reaches the strip; until then the strip keeps showing what it showed. An alert
that is gone within that second is never seen. Going to `working` has no
settle: it shows on the event that caused it.

**Colours.** Every colour named in this section is a default. The Colours page
(§10) sets eleven of them, and the strip paints what is set: Claude working
(red by default), Codex working (blue, `#0a00ff`), Copilot working (another
blue, `#0e5cff`), OpenCode working (another red, `#ff0043`), needs you
(amber), done (green), command running (violet), battery critical (red), and
the battery bar's three bands (red, amber, green). Needs you and done are the
same colours for every agent. A failed
command takes the needs-you colour and a succeeded one the done colour. Every
colour is a true colour, the same hex on the strip and in the window; a strip's
brightness (§10, Strip) is what dims it, never a darker hex. The six effects
follow the same rule and are not recoloured.

**Carrying an animation on.** The strip takes whole programs and every program
starts from its first line, so a rewrite restarts what the strip shows. When
the animation continues through a change, it is not restarted: the strip gets
the rest of its current loop from the point it has reached, and the loop itself
when that rest ends. Two changes carry on this way, at once, never waiting for
the loop's end:

1. **A brightness change** during any looping display: the same animation,
   at the new brightness, from where it is.
2. **The roll under a zone that opens, closes or changes**: work → split with
   the same work, split → work, and split → split with the same work (a
   finish becoming a question, a question becoming a finish). The roll's LEDs
   carry on from where they are; a green zone is set at once, an amber zone
   starts its double blink at once; a zone that closes goes dark at once and
   its LEDs join the roll when the loop restarts.

3. **Off and back within `K.resumeFromDarkSeconds` (2 s)**, the brightness
   cycle's off step and the press after it, or `led off` then `led auto`: the
   same animation resumes where it would have been had it kept playing in the
   dark, its lit LEDs fading in from black. Later than that, or another
   animation, starts from scratch.

4. **The full-strip roll changing colour**: Claude's roll becoming a shared
   one when another agent starts, a shared one becoming one agent's when the
   others finish, and every other change of agents, between a roll by pass
   and a roll by LED as well. The wave carries on from
   where it is and takes the new colours at its next pass. Under a zone the
   roll's agents changing starts the split anew.

On a roll of several passes a tail ends at the loop's end when it fits in the
strip's program, and otherwise at the end of the pass under way, where every
LED is dark; the loop then starts with the first agent's pass, so a brightness
change during that pass can show its colour twice in a row, once. A roll by
LED is one pass, and its tail ends at the loop's end like one agent's.

A change of animation (working → done alone, a different roll) starts the
new one from its first line: there is nothing to carry on. The exact cut, and
what a mid-pulse cut costs, are in [device.md](device.md).

Colours, shapes and exact program text are in [device.md](device.md).

## 4. Agent status: Claude Code, Codex, GitHub Copilot and OpenCode

### Source

`mysidepulse install-hooks` subscribes one command — `<bundle>/Contents/MacOS/mysidepulse hook`,
matcher `*`, timeout 5 s — to 15 Claude Code events in
`~/.claude/settings.json`: `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
`PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `PreCompact`, `PostCompact`.

The same command subscribes `<bundle>/Contents/MacOS/mysidepulse hook --agent codex`
to the 12 Codex events in `~/.codex/hooks.json`, which holds the same shape
under the same `hooks` key: `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `SubagentStart`,
`SubagentStop`, `PreCompact`, `PostCompact`, `Interrupt`. A Codex entry has no
matcher (Codex reads a missing one as match-all) and a timeout of 5 s, 3 s for
`SessionEnd` and `Interrupt`, the most Codex allows them; each goes after every
group already in the event's list. Codex is on this Mac
when `~/.codex` exists. **Codex runs a hook only once it is trusted**: a
`[hooks.state."<key>"]` table in `~/.codex/config.toml` whose `trusted_hash`
is the hash Codex computes for the entry. So the set-up also writes that table
for each of the 12 hooks, with Codex's own key (`<Codex's home, symlinks
resolved>/hooks.json:<event in snake_case>:<group index>:0`) and hash, after
the rest of the file, which it leaves as it is; both files are backed up first
(`hooks.json.backup-mysidepulse`, `config.toml.backup-mysidepulse`), and
`config.toml` is written only when the trust changes it. A `config.toml` that
cannot be read as text, or that holds a hook state written as an inline table,
stops the set-up before either file is written; the second says to trust the
hooks from Codex's `/hooks` screen instead. Removing the hooks
removes their trust first, whichever copy of the app wrote them; a
`config.toml` that cannot be read is left as it is and said, and the hooks
still go. A Codex hook counts as set up only while it is in `hooks.json`
**and** trusted, and not switched off in Codex.

GitHub Copilot CLI reads every file in `~/.copilot/hooks/` at each start, with
no trust step. `install-hooks` writes `~/.copilot/hooks/mysidepulse.json` whole,
creating the folder, with seven entries in Copilot's `exec` form (no shell):
each runs `<bundle>/Contents/MacOS/mysidepulse` with the arguments
`hook --agent copilot --event <name>`, 5 s at most, for `sessionStart`,
`userPromptSubmitted`, `postToolUse`, `postToolUseFailure`, `notification`,
`agentStop` and `sessionEnd`. Copilot's payloads name no event, so each entry
names its own. **Never `preToolUse` or `permissionRequest`**: Copilot denies
the tool when either hook fails or its binary is missing, so a file that
outlived the app would block every Copilot tool call. Copilot is on this Mac
when `~/.copilot` exists. `disableAllHooks: true` in Copilot's `settings.json`
or `config.json` turns every user hook off, ours included.

OpenCode runs no command hooks. `install-hooks` writes a plugin,
`~/.config/opencode/plugins/mysidepulse.js`, creating the folder; a running
OpenCode server loads it, reloads it when it changes and drops it when it is
deleted, within a second, with no registration and no trust step. It runs
`<bundle>/Contents/MacOS/mysidepulse hook --agent opencode` once for each
OpenCode event it forwards, one at a time in OpenCode's order, 2 s at most
each, with one small JSON object on the hook's stdin: the event's type, its
session, the top session a subagent's session runs under (however deep, and
even once a session between them is deleted), the server's pid, and a few words (a tool's name, a permission's action, the
reply, whether a form is a question, a reason); never a prompt, an answer, a
tool's input or output, or a path. OpenCode is on this Mac when
`~/.config/opencode`, `~/.opencode` or `/Applications/OpenCode.app` exists.
The plugin is set up when the file is byte for byte what this app writes.

Copilot's file and OpenCode's plugin are MySidepulse's whole: a file at either
path that holds anything else is neither replaced nor deleted, and
`install-hooks` says so and fails. Every agent but Claude Code is set up only
when it is on this Mac; `install-hooks` says which were not, and
`uninstall-hooks` removes every agent's hooks, on the Mac or not. The
`--agent` flag is how a journal line says who fired the hook, and it always
wins; a hook without it is Claude Code's, whose hooks carry no flag, and
records the nearest Claude Code process its ancestry shows, never an agent of
another kind.

Settings › System › Claude Code does the same from the window: `Set Up Hooks`
subscribes, `Remove Hooks` unsubscribes. The `Claude Code hooks` row reads
`Enabled` only when all 15 events run the CLI of the app showing the window;
hooks that run another copy of it count as `Disabled`, and `Set Up Hooks`
replaces them. A `settings.json` that cannot be parsed reads `Invalid` in red,
with a warning naming the file, and is never written. Claude Code re-reads
`settings.json` while it runs: sessions already open follow a change within
seconds, without a restart, which the group's note says. Settings › System ›
Codex is the same group for Codex, shown only while Codex is on this Mac or
its hooks are set up; its `Codex hooks` row reads `Enabled` when all 12 events
run this CLI with `--agent codex` and Codex trusts every one of them,
`Disabled` in orange otherwise (Codex is optional), and `Invalid` in orange
when `hooks.json` cannot be parsed or `config.toml` cannot be read.

Each event becomes one trimmed line in the journal, enriched with the agent
(`claude`, `codex`, `copilot` or `opencode`; a line without it is Claude's),
the agent's process id, the hosting app's bundle id, and the terminal tab's
tty. Only the agent's own events count: a Claude Code or Codex payload naming
an event outside that agent's list above is written as a `ParseError` line,
which changes nothing. The app follows the journal. Every session id seen gets its own state,
and keeps the agent of its lines.

Copilot's and OpenCode's events carry their own names, and each is written
under the journal's name for what it means:

| Copilot | Journal |
|---|---|
| `sessionStart` | `SessionStart` |
| `userPromptSubmitted` | `UserPromptSubmit` |
| `postToolUse`, `postToolUseFailure` | `PostToolUse`, `PostToolUseFailure` |
| `notification` | `Notification`, with Copilot's `notification_type`: `permission_prompt` (a permission), `elicitation_dialog` (an `ask_user` question), `shell_completed` and the rest (nothing) |
| `agentStop` | `Stop` |
| `sessionEnd` | `SessionEnd`: at every interactive exit, and after every `copilot -p` turn |

A Copilot event whose session has no folder under Copilot's session state
(`~/.copilot/session-state/<id>/`, or under `$COPILOT_HOME` for a Copilot run
with it) is a subagent's own prompt or stop, which carries the subagent's id,
and writes no line, so a subagent's stop never finishes its parent's turn;
when that session-state folder does not exist at all, every line is written.
A Copilot start, prompt or stop names the session's `events.jsonl` when its
payload names none. Answering a Copilot permission or question fires no hook:
the next `postToolUse` is the answer.

| OpenCode | Top session | Subagent's session (its events are its top session's helper events) |
|---|---|---|
| `session.created`, `session.forked` | `SessionStart` | `SubagentStart` |
| `session.inbox.enqueued` (a user's prompt), `session.execution.started` | `UserPromptSubmit` | `UserPromptSubmit` |
| `session.tool.called` | `PreToolUse`, with the tool's name | `PreToolUse` |
| `session.tool.success` | `PostToolUse` | `PostToolUse` |
| `session.tool.failed` | `PostToolUseFailure` | `PostToolUseFailure` |
| `permission.asked` | `PermissionRequest`, the permission's action as the tool | `PermissionRequest`: the top session waits |
| `permission.replied` `once` or `always` | `PostToolUse` | `PostToolUse` |
| `permission.replied` `reject` | `PermissionDenied` | `PostToolUse` |
| `form.created`, a question | `Notification` `elicitation_dialog`: `waiting(question)` | `PermissionRequest` |
| `form.created`, any other form | nothing | nothing |
| `form.replied`, `form.cancelled` | `PostToolUse` | `PostToolUse` |
| `session.compaction.started` | `PreCompact` | `PreCompact` |
| `session.compaction.ended`, `.failed` | `PostCompact` | `PostCompact` |
| `session.execution.succeeded` | `Stop` | `SubagentStop` |
| `session.execution.failed` | `StopFailure` | `SubagentStop` |
| `session.execution.interrupted`, whatever its reason | `Interrupt` | `SubagentStop` |
| `session.deleted` | `SessionEnd` | `SubagentStop` |
| anything else, or an event of no session | nothing | nothing |

"Nothing" writes no line. OpenCode names no turn. A subagent's question
raises its top session's `waiting(permission)`, not `waiting(question)`: it
goes the way of a subagent's permission request, so the subagent's next event
clears it. `permission.asked` fires
even for a permission granted at once, whose reply comes about 3 ms later:
the settle keeps that wait off the strip and its push is disarmed with it.

### States

`idle`, `working`, `done`, and `waiting` with a reason: `question`,
`permission`, `plan` or `error`.

| Event | Result |
|---|---|
| `SessionStart` | `idle`; forgets the session's subagents and background shells. With `source: compact`: no change, and they are kept, a held `Stop` stays held and the state `PreCompact` remembered is kept — the mid-flight marker of a compaction already under way. Copilot's changes nothing, not even when the main agent was last at work: Copilot fires it with the first prompt, after it, so it only records the session's pid and `events.jsonl` path and proves the hook alive. |
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `AskUserQuestion` or Codex's `request_user_input` → `waiting(question)`; `ExitPlanMode` → `waiting(plan)`; any other tool → `working` |
| `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `working` |
| `PreCompact` | `working`, remembering the state it found; a second `PreCompact` with no `PostCompact` and no turn boundary since keeps what the first remembered. A turn boundary — a prompt, a `Stop`, an `Interrupt`, a `SessionStart` that is not a compaction's — forgets it. |
| `PostCompact` | the state `PreCompact` found, or `working` when it found none: a compaction inside a turn leaves it working, one at the prompt leaves it idle, finished or waiting, a finish or a wait with its alert — since when, seen or not, its push, whether a helper raised it, its settle — untouched |
| `PermissionRequest` | `waiting`, reason from the tool name: `AskUserQuestion` or `request_user_input` → `question`, `ExitPlanMode` → `plan`, else `permission`. A subagent's request raises the same wait, and that subagent's next event answers it, whatever it asked. |
| `Notification` `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` | `waiting(permission)`, unless the session already waits for a `question` or a `plan`; a Copilot or OpenCode `elicitation_dialog` is `waiting(question)`. A repeat over a standing wait re-stamps it (its push re-armed) and keeps whose it is: a wait a subagent raised is still answered by that subagent's next event. |
| `Notification` `idle_prompt`, `agent_needs_input` | Never an alert. See "lost Stop" below. |
| other `Notification` types | nothing |
| `Stop` | `done` — or held, see below |
| `StopFailure` | `waiting(error)` |
| `Interrupt` (Codex and OpenCode) | `idle`: the user stopped the turn, dialog or not; the turn delivered nothing, its helpers and background shells are forgotten, and the strip goes dark with no alert |
| `SubagentStart`, other subagent events | mark that subagent live |
| `SubagentStop` | that subagent is no longer live; for a session no longer known (an OpenCode subagent that outlives its deleted top session), nothing, and no session is made for it |
| `SessionEnd` | the session is forgotten |

Every event of a turn carries the turn's id: Claude Code's `prompt_id`,
Codex's `turn_id`; Copilot's and OpenCode's carry none. An `Interrupt`, or a verdict that the turn is over (*When
hooks say nothing*), closes the turn named by the last main-agent event that
carried an id: the prompt that opened it, or the later event of a turn
followed from mid-turn or going on under a new id. A finish held behind
helpers or background shells is not over yet and closes nothing, whether a
`Stop` or a verdict found it. Any event that arrives for
a closed turn, but a prompt, a `SessionStart` or a `SessionEnd`, only proves
the hook alive and changes nothing: the end of a tool Codex aborted, seconds
or minutes later, its `Stop`, its notifications, its compaction, and every
helper event of that turn. A `Stop` ends the turn but does not close it: a
Stop hook that blocks it keeps the turn running, and its later events count.
A prompt always opens a turn, whatever id it carries, a closed one included,
whose events then count again. A main-agent `PreToolUse` reopens a turn a
verdict closed, and counts, since a new tool call is never the straggler of
an aborted tool and Claude Code carries one `prompt_id` across consecutive
turns; a turn an `Interrupt` closed is reopened by a prompt only. For `K.abortQuarantineSeconds` (120 s) after an
`Interrupt`, and until a prompt, a tool or permission event without a turn id
changes nothing either. A line without a turn id otherwise follows the rules
above.

A turn that ends in prose is **finished**, questions included: "Want me to
commit?" is green. Amber is raised only by the explicit signals above.

Subagent events (those carrying an `agent_id`) never speak for the main agent,
with two exceptions: a subagent's permission request blocks the turn and shows
amber until that subagent acts again (whatever the dialog asked: a permission, a
question or a plan) or the main agent moves on, and subagent activity after
`done` re-opens the turn as `working`, unless that turn is closed. Subagent
activity never answers a wait the main agent raised.

### Finishing, and holds

A `Stop` means `done` only if nothing is still out. If the session has a live
subagent or a background shell (from the payload's `background_tasks`, entries
of type `shell` or of no type, the first sixteen of them once the others are
left out), the strip stays on `working` and the finish is *held*:

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
- A session whose agent process exits is forgotten at once (kqueue on the
  pid), except that a Codex session hosted by the TUI is hosted by Codex's
  managed daemon, one per user, alive across every TUI: the pid its hooks
  record is the daemon's, and only the daemon's death forgets its sessions.
  The desktop app's `codex` is a shared app-server too, alive for every
  thread of the app, so its pid proves no single session either; only
  `codex exec` records a process of its own. At launch, a replayed session
  is kept only while its pid is alive, runs its agent and, for a Claude
  session, when a registry record exists for the pid, names the same
  session: a Claude process hosts one session at a time, so a record naming
  another means the pid has moved on. A Codex session whose pid is a shared
  app-server is kept, and the launch check below decides it. So is a
  Copilot session whose `copilot` runs: one Copilot process can hold
  several sessions, and each is decided by its `events.jsonl` below; the
  process's exit still forgets every session it held.

### When hooks say nothing

Esc and Ctrl-C end a Claude Code turn without any hook, and hook delivery can
stop mid-session. For Claude Code sessions, the rescues below read Claude
Code's own registry and transcript. The registry alone says whether a quiet
turn is over: `idle` stamped after the last main-agent event ends it at once.
The transcript only says how it ended: a completed answer is the lost `Stop`,
anything else, a transcript that cannot be read included, is dark.

Copilot fires nothing either for Ctrl+C or Esc Esc, nor for an answered
prompt, nor any end for a turn that fails; its `events.jsonl` says each
(below). OpenCode
ends every busy period with exactly one of `succeeded`, `failed` or
`interrupted`, so it needs no such rescue: a terminal event that never came
is covered by its server's exit, which forgets every session the server
hosted, and by the 2 h backstop.

Codex has no registry, but every Codex hook names the session's rollout file
(`transcript_path`). A working Codex session quiet for `K.abandonQuietSeconds`
with nothing out is checked against it every `K.abandonRecheckSeconds` and
once at launch: a `task_complete` stamped after the last main-agent event is
the lost `Stop` (`done`, with its push); a `turn_aborted` stamped after it is
the interrupt (`idle`, dark), with no push; a `task_started` with no end keeps the session
alive; an unreadable rollout decides nothing. An end marker that names the
turn of the last main-agent event ends that turn however it is stamped: with
the `Interrupt` hook lost, the aborted tool's late `PostToolUse` arrives after
the `turn_aborted`. While the rollout says the turn runs, the 2 h backstop
counts from its last line. A recorded path is read only when its file name
names the session and it lies under `~/.codex/sessions/`; otherwise, and for
a session no line gave a path, the newest `rollout-…-<session id>.jsonl`
there is read. Only the last 64 KB of the file are read, and of them only
each line's type, the turn markers' turn ids and stamps, and the last line's
stamp (when Codex last wrote to the session).

Copilot has neither a registry nor a daemon, but writes every step of a
session into `~/.copilot/session-state/<session id>/events.jsonl`, whose path
the hook records on a Copilot start, prompt or stop. A working Copilot
session quiet for `K.abandonQuietSeconds` with nothing out is checked against
it every `K.abandonRecheckSeconds` and once at launch, and the last turn
marker in it decides, when it is stamped after the last main-agent event
(Copilot names no turn): an `abort` is the interrupt, Ctrl+C or Esc Esc
(`idle`, dark), with no push; the `hook.start` Copilot writes when it runs
the session's own `agentStop` hook is the lost `Stop` (`done`, with its
push); a `session.error` is the failed turn, which takes the outcome a
`StopFailure` gives (`waiting(error)`, with its push); a `session.shutdown`,
Copilot closing the session, is dark (`idle`), with no push, unless the
turn's own end comes before it, which then says how the turn ended. A
shutdown stamped after the last main-agent event ends the turn whatever
older end precedes it: an end stamped at or before that event is an earlier
turn's, and the turn is dark. A step of the turn
at work (`user.message`, `assistant.turn_start`, `assistant.message`,
`tool.execution_start`, `tool.execution_complete`, `permission.requested`,
`permission.completed`) keeps the session alive, and the 2 h backstop then
counts from the file's last line; an unreadable file, or one with no marker,
decides nothing. An `agentStop` naming another session is a subagent's,
mirrored into its parent's file, and ends nothing; `assistant.turn_end` ends
every model call, not the turn. A recorded path is read only when it is
exactly `<session-state>/<session id>/events.jsonl` under
`~/.copilot/session-state`, absolute, with no `.` or `..`; otherwise, and for
a session no line gave a path, that session's own file there is read. Only
the last 64 KB of the file are read, and of them only each line's type and
stamp and, for a `hook.start`, the hook's name and the session its payload
names.

A Copilot session waiting on a permission or a question (`waiting(permission)`
or `waiting(question)`, never a failed turn's `waiting(error)`) is checked
against the same file every `K.abandonRecheckSeconds` from the moment the wait
began, with no quiet gate, and once at launch, and the file's latest turn
marker decides. Ctrl+C or Esc Esc at the prompt fires no hook, and an `abort`
stamped after the wait began ends the turn as a working turn's abort does
(`idle`, dark), with no push. Answering the prompt fires no hook either
(approving or denying a permission writes `permission.completed`): with the
turn still at work, a latest permission line that is `permission.completed`,
stamped after the wait began, is the answer, and the session is back to
`working`, its push disarmed, as the answered dialog of a Claude Code session
is. A latest `permission.requested` is a prompt still open, a second one asked
right after the first was answered included, and a tool called beside the
prompt finishing while it is open is no answer; a finish, a failure or a close
is no answer; a `permission.completed` or an `abort` stamped at or before the
wait began, an unreadable file, or one with no marker, changes nothing. The
permission line's own stamp is what counts, never the file's last line: the
wait's own `notification` hook writes a line after the wait began, answered or
not. A question's answer needs none of this: it ends its `ask_user` tool, and
`postToolUse` fires.

When Codex's daemon is running it is asked first (`thread/read` on its
control socket): a thread it has not loaded, or has idle, has nothing
running; an active one keeps the session alive; the rollout decides when the
daemon does not answer. Only a session whose recorded pid is Codex's managed
daemon is asked: a `codex exec` thread runs in its own process and a
desktop-app thread in the app's own `codex`, and the daemon would call either
one not loaded while it works, so those keep the rollout alone. When nothing
runs, the rollout tells how the turn ended: a `task_complete` that ends it is
the lost `Stop` (`done`, with its push); a `turn_aborted`, or no end of this
turn at all, is dark, with no push. Any other status, or an answer about a
thread other than the one asked about, decides nothing, and the rollout
decides that session for the next `K.abandonRecheckSeconds`. Every
question has 1 s to be answered, and an answer that arrives after a
main-agent hook moved the session is dropped.

Every verdict of these rescues, Claude's, Codex's and Copilot's, takes effect
as of when the turn ended — the registry's stamp, the rollout's or the
`events.jsonl`'s end marker, or, when the
daemon says nothing runs and the rollout shows no end of the turn, the
`updatedAt` of the daemon's thread record; never before the last main-agent
event — not when it was found, exactly as a replayed
`Stop` would: `done` stays lit for what is left of `K.doneVisibleSeconds`
counted from the end, and a finish found more than
`K.notifyMaxLatenessSeconds` after its push was due, at launch after the app
was away for instance, shows `done` without a push; so does a failure found
that late show `waiting(error)` without one.

At launch, after the journal is replayed, the time rules run first (a
session silent past the 2 h backstop is forgotten); then, when a working
session is hosted by Codex's daemon and its socket exists, the daemon is
asked which threads it holds (`thread/loaded/list`, never `thread/read`): a
working hosted session whose thread is missing from the complete list has
nothing running and is decided by its rollout at once, dark when the rollout
says nothing, while a partial list or no answer decides nothing; then every
working Claude Code, Codex or Copilot session, and every Copilot session
waiting on a permission or a question, is checked at once, with no quiet
gate, before the strip is painted. The paint waits for the daemon's answer, 1 s at
most.

| Situation | Signal | Result | Latency |
|---|---|---|---|
| Lost `Stop` | `idle_prompt` / `agent_needs_input` on a `working` session whose main agent has been quiet ≥ `K.idleSignalMinQuietSeconds` (50 s) | treated as the `Stop` | ~60 s |
| Lost `Stop` | `working`, nothing out, quiet ≥ `K.abandonQuietSeconds` (20 s); Claude's registry says `idle`; the transcript ends on a completed assistant answer (`end_turn` / `stop_sequence`) | `done`, with its push | 20–35 s |
| Interrupted turn | same, but the transcript ends on an unanswered entry, or cannot be read | `idle` (dark) | 20–35 s |
| Dialog answered with no hook | a wait, a failed turn's `waiting(error)` included; the registry says `busy`, stamped more than `K.dialogAnswerMinStampLeadSeconds` (2 s) after the wait began | `working` | ≤ 15 s + |
| Codex: lost `Stop` | `working`, nothing out, quiet ≥ `K.abandonQuietSeconds` (20 s); the rollout's last turn marker is a `task_complete` stamped after the last main-agent event, or naming its turn | `done`, with its push | 20–35 s |
| Codex: interrupted turn, `Interrupt` lost | same, but the marker is a `turn_aborted` | `idle` (dark), no push | 20–35 s |
| Codex, a TUI session: the turn ended with no hook | same quiet gate; Codex's daemon says the thread is `notLoaded` or `idle` | `done` with its push when the rollout ends the turn on `task_complete`, else `idle` (dark), no push | 20–36 s |
| Codex, a TUI session: the turn runs with no hook | same quiet gate; the daemon says `active` | stays `working`, kept alive | — |
| Copilot: interrupted turn (Ctrl+C, Esc Esc) | `working`, nothing out, quiet ≥ `K.abandonQuietSeconds` (20 s); the last marker of `events.jsonl` is an `abort` stamped after the last main-agent event | `idle` (dark), no push | 20–35 s |
| Copilot: lost `Stop` | same, but the marker is the session's own `agentStop` hook starting | `done`, with its push | 20–35 s |
| Copilot: failed turn | same, but the marker is a `session.error` | `waiting(error)`, with its push | 20–35 s |
| Copilot: session closed mid-turn | same, but the marker is a `session.shutdown` stamped after the last main-agent event, with no end of this turn before it (none, or only an earlier turn's) | `idle` (dark), no push | 20–35 s |
| Copilot: a permission or question cancelled (Ctrl+C, Esc Esc at the prompt) | `waiting(permission)` or `waiting(question)`, from the moment the wait began; the last marker of `events.jsonl` is an `abort` stamped after the wait began | `idle` (dark), no push | ≤ 15 s |
| Copilot: a permission answered | same wait; the turn is at work and the latest permission line of `events.jsonl` is `permission.completed`, stamped after the wait began | `working`, the push disarmed | ≤ 15 s after the answer |

While the registry says `busy`, a quiet session is kept alive and stays
`working`. The registry of a quiet turn and of a waiting Claude Code session
is re-read every `K.abandonRecheckSeconds` (15 s) while the condition lasts:
`busy` after the wait began is the agent at work, whatever the wait was.

The registry is Claude Code's own `<config>/sessions/<pid>.json`, where
`<config>` is the directory the session's transcript lives in
(`<config>/projects/<slug>/<session>.jsonl`), so a relocated
`CLAUDE_CONFIG_DIR` is found; for a session no line has named a transcript
for, it is the process's own `CLAUDE_CONFIG_DIR` when macOS lets it be read,
then `~/.claude`. Transcript entries marked `isSidechain` are ignored.

The app records its own verdicts in the journal — a turn abandoned, a finish
recovered, a turn failed, a dialog answered, whether the registry, a rollout,
Codex's daemon or a Copilot `events.jsonl` gave it — each stamped when it took effect, so a relaunch replays
them and never resurrects a turn it had already closed: a replayed verdict
applies the outcome it recorded as of its stamp, and is not decided again. A
finish held behind a helper still out is not recorded; the hold rules end it,
and a relaunch checks that turn afresh. A recorded verdict changes nothing
when a main-agent event of its session came after it, and never brings a
session back. A replayed finish is a replayed `Stop`: it
pushes again only while its push is still inside
`K.notifyMaxLatenessSeconds`.

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
- A session with no focusable host is acknowledged by any activity: one hosted
  by the Claude Code daemon, whose terminal has quit, hosted by Codex's
  managed daemon (a TUI session with no window of its own), or an OpenCode
  session, whose server runs under launchd with no terminal tab or host app —
  so a "needs you" or "finished" from any of these is acknowledged by the next
  keystroke or click anywhere on the Mac.

Every unknown widens acknowledgement; none can strand an alert.

Acknowledging clears the strip *and* cancels the pending push. It is written to
the journal, so a restart does not resurrect it. A new alert on the same
session is unacknowledged again. Terminal jobs are acknowledged by host app
only, and written to the journal the same way.

## 6. Phone notifications (ntfy)

Publish only. One HTTP `POST` per alert to `<server>/<topic>`:

| Part | Value |
|---|---|
| `Title` header | the agent's product name: `Claude Code`, `Codex`, `GitHub Copilot` or `OpenCode` |
| `Tags` header | `white_check_mark` (finished), `speech_balloon` (question), `lock` (permission), `clipboard` (plan), `rotating_light` (turn failed) |
| `Click` header | `https://claude.ai/code/<bridgeSessionId>` when Claude's session record has one, else `https://claude.ai/code`; `https://chatgpt.com/codex` for a Codex session, `https://github.com/copilot` for a Copilot one, `https://opencode.ai` for an OpenCode one |
| Body | English: `Finished`, `Asking you something`, `Needs permission`, `Plan ready`, `Turn failed`. French: `Terminé`, `Vous pose une question`, `Demande une permission`, `Plan prêt`, `Échec du tour` |

The title and the tags are protocol values and are never translated; only the
body is (§15). The bodies are the same words for every agent: the title says
who. No priority, actions or authorization header. The topic is the only secret: a
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

**Muted:** Claude sessions whose Claude record has kind `bg`, `daemon` or
`daemon-worker` light the strip but never push; Codex has no such record, so
every Codex session pushes. Terminal jobs never push.

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
  `watch`, `tig`, `lazygit`, `su`, `login`, `grok`, `mysidepulse`,
  `koffeelid` (the sibling app's command) and the like, and the agents,
  shown through their own hooks: `claude`, `codex`,
  `copilot` and `opencode`. Leading `VAR=value` words and the prefixes
  `sudo`, `time`, `command`, `builtin`, `exec`, `nice`, `nohup`, `env`,
  `noglob` and `caffeinate`, each with the `-` flags after it (and the
  argument of `sudo -u`, `-g`, `-h`, `-p`, `-C`, `-D`, `-T`, `-U`, `-r`, `-t`,
  `nice -n`, `env -u`, `-C`, `-S`), are skipped before a segment's head is
  read: `sudo -u root vim` is `vim`, `sudo make` shows as `make`. A line of
  prefixes alone (`sudo -i`, `sudo -s`) opens an interactive shell and begins
  no job, nor does a line with no program (`FOO=1`). The shells in the list
  (`zsh`, `bash`, `sh`, `fish`, `dash`, `ksh`) are skipped only when they run
  interactively, every word after the shell's name being a flag (`zsh`,
  `bash -l`, `zsh -f -i`); a shell that runs a script (`bash build.sh`,
  `sh -c '…'`, `zsh script.zsh`) is a job like any other.
- A shell under an agent is never a job: a shell with Claude Code, Codex (its
  CLI or its app-server daemon), Copilot or OpenCode (its CLI or its server)
  anywhere on its process chain is that agent's tool shell, or one a script
  it started opened, and its commands are the agent's own work, which the
  agent's session already shows. `job begin` and `run` write no line for
  such a shell (`run` then writes no end either), and the app drops a begin
  line from one when it reads it, live or replayed while the shell's pid
  can be read, so a line an older CLI wrote begins nothing either, even
  after the agent's session has ended and the command runs on (OpenCode's
  server keeps a tool's process running after a Ctrl+C in its window). A
  terminal pane opened in a desktop app is the user's: the app's own window
  process is not the agent.
- A shell that re-reads the snippet (`source ~/.zshrc`), or is replaced by
  `exec` (`exec zsh`), ends the job it was running: an interactive shell
  loading the snippet ends its own slot's job as a cancellation (`job end
  --id zsh-<pid> --exit 130`), so an orphan never shows as an outcome.
- While a job runs, its shell is asked whether it still runs a command, from
  the job's begin on and at least every `K.jobProbeSeconds` (15 s). A shell
  gone clears the job at once (kqueue), and so does a shell pid now held by a
  process started after the job began. A shell back at its prompt with no
  child it started since the job began clears it once seen so again
  `K.jobPromptSettleSeconds` (5 s) later, the end having been lost; a child
  older than the job (Powerlevel10k's `gitstatusd`, an earlier `&` job) says
  nothing about it. A shell replaced by its program keeps the job until that
  program exits. Such a clear leaves no outcome and is logged `job <id> ended
  without a hook (<reason>)`. A command that blocks the shell without a
  child (`read`, `wait`, a long `for` loop of builtins) looks the same as a
  shell at its prompt, so its job is cleared while it runs: 5 s after the
  first probe that sees it, which comes up to 15 s after it began, so 5 to
  20 s in all.
- A job reaches the app as journal lines: `job begin` (and `run`) appends a
  `JobBegin` line, `job end` (and `run`, with the command's status) a
  `JobEnd` line carrying the exit status, each one write the CLI makes
  without waiting on the app. The app follows them like every other line
  and, at launch, replays this boot's with the rest, the outcomes and their
  acknowledgements included: a restart keeps a command that still runs and
  an outcome not yet seen. At launch each replayed running job's shell is
  asked once before anything shows: a shell gone, or a pid now held by a
  process started after the job began, leaves nothing to show, and one at
  its prompt goes through the settle below. If the app is not running, the
  command runs all the same, and the app started later in the same boot
  picks the job up.
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
whose owner process dies is removed; a running job with an owner process is
never timed out, however long it runs; a running job without one expires
after `K.jobStaleSeconds` (2 h).

An agent outranks a job at every rung, so a running job's colour is hidden
while an agent works; a job *outcome* takes the alert zone over the
agents' roll.

## 8. Battery

Read from IOKit (internal battery only), on change and every
`K.powerRefreshSeconds` (300 s). Critical is ≤ 15 % while not plugged, charging
or charged. The glance bar takes the Colours page's colour for its band, ≤ 15 %,
≤ 50 % or above, red, amber and green by default (§3 *Colours*). A reading
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

## 10. Onboarding, and the Settings window

### The onboarding wizard

The first window a user ever sees. **540 pt wide, titled and closable, nothing
else**: the normal window level, the default collection behaviour, no
miniaturise button and no resize. It comes up in front because it is the last
window to open, and from then on it takes its turn like any other window: a
permission prompt and System Settings both open over it and stay there. Unlike
the Settings window it does **not** give the app a Dock icon; the main menu is
there all the same, so ⌘W and ⌘C work.

**It opens by itself on a launch that is a person's and has not been walked to
its end**, and on no other: a launch the installer or the update helper asked
for is silent, by the same marker that keeps the Settings window shut (above).
The last page's button is what records it as done, so a window closed before
that brings the wizard back at the next launch. **Settings › System › Welcome ›
`Show Onboarding Again`** opens it at any time, from page one, with every row
re-read.

**Three pages, one button at the bottom right of each.**

1. The app icon, *Know when Claude is working, finished, or needs you.* with
   **Claude** in the app's own working red, two lines saying what the strip does
   and that the same alerts reach a phone, and three capsules: *Working*,
   *Finished*, *Needs you*. `Continue`.
2. **Setting up**: one grey paragraph, then five rows, then the button.
3. **All set**: slide the card into the slot, the app lives in the menu bar,
   everything here can be changed again in Settings. `Finish`.

Each row is a title, one grey line saying what it gets the user, and a trailing
control. The title is **exactly what System Settings calls the switch, or
exactly what the Settings window already calls the same thing**; a row the app
cannot work without carries an orange triangle after its title.

| Row | Required | Done when | The button does |
|---|---|---|---|
| `Claude Code hooks` | yes | all 15 events are in Claude Code's settings | adds them, after a backup (§4 *Source*); once set up, `Remove` |
| `Startup` | no | the launch agent is registered | registers it (§12 *Handing over to launchd*) |
| `Terminal hook` | no | the block is in `~/.zshrc` | adds it (§7); once set up, `Remove` |
| `Notifications` | no | macOS has granted them | asks macOS, and nothing else |
| `Phone alerts` | no | the phone switch is on | turns it on and opens Settings › Notifications, where the QR code the phone scans is (§6) |

The page's button reads **`Skip`** until every required row is done and
**`Continue`** from then on. While a row's flow runs, that row keeps its button,
disabled, with a small spinner beside it.

**Every permission prompt in MySidepulse follows a click, and there is no
exception.** The `Notifications` row is the only thing in the app that asks; an
automatic update check that finds a release reads the authorization and stays
quiet without it, and the release shows in Settings all the same. Nothing tells
an app that a grant was made in System Settings, so while the window is up each
row is re-read every **2 s**, and a row that moves redraws its own trailing
control; the page itself is built only when the step changes.

**Who is in front.** A button that hands over to System Settings or to a system
prompt changes nothing: the wizard stays where it is, under what it opened. It
comes back to the front when the app it sent the user to **quits**, for up to
five minutes after the press, and when the app is activated for any other reason
while the wizard is the app's only window. Opening MySidepulse again while the
wizard is up brings the wizard forward, not Settings: with no Dock icon that is
the way to fetch it back.

### The Settings window

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

**Eight pages, picked from a toolbar** that draws each page's symbol above its
title: *General*, *Strip*, *Colours*, *Notifications*, *Playground*, *System*,
*Health*, *Tip*.
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
| Strip | Strip | one row per attached strip, `Available` or `Stalled`, each with a brightness slider in perceived percent, 5 % to 100 % in steps of 5 % (`K.brightnessSliderStepPercent`, each a change the eye can see; 5 % is the strip's lowest) (§11 *Brightness is perceived*; applied on release; 100 % stores nothing; `brightness cycle` sets the same value) | 100 % |
| Strip | Remembered brightness | the overrides of strips not plugged in, each with `Forget` | |
| Colours | Preview | the live strip playing the picked colour's state, what is playing, and `Stop` while it plays | |
| Colours | Colours | one row per colour, eleven (§3 *Colours*): its small strip, its hex, a colour well, `Reset`; then `Reset All Colours` | the defaults of §3 *Colours* |
| Notifications | Phone | Notify my phone when an agent finishes or needs you | off |
| Notifications | Server | the ntfy server, applied on Return | `https://ntfy.sh` |
| Notifications | Topic | the masked topic; `Reveal Topic and QR Code`; `New Topic…` | |
| Notifications | Test | `Send a Test Notification`, and its result | |
| Playground | On the strip | the live strip, what is playing, `Keep It` and `Stop` | |
| Playground | States, Effects | thirteen state tiles and six effect tiles | |
| System | Claude Code | `Claude Code hooks`, `Set Up Hooks` or `Remove Hooks` (§4 *Source*) | |
| System | Codex | `Codex hooks`, `Set Up Hooks` or `Remove Hooks` (§4 *Source*); the group is there only while Codex is on this Mac or its hooks are set up | |
| System | Copilot | `Copilot hooks`, `Set Up Hooks` or `Remove Hooks` (§4 *Source*); the group is there only while Copilot is on this Mac or its hooks are set up | |
| System | OpenCode | `OpenCode plugin`, `Set Up Plugin` or `Remove Plugin` (§4 *Source*); the group is there only while OpenCode is on this Mac or the plugin is set up | |
| System | Terminal | `Terminal hook`, `Set Up Terminal Hook` or `Remove Terminal Hook` (§7) | |
| System | Notifications | `Notifications permission`, and `Allow Notifications` while it is not granted | |
| System | Welcome | `Show Onboarding Again`, which opens the wizard at page one (above) | |
| Health | Health | the checks, green, orange or red (below); `Check Again` | |
| Health | Information | four readings, blue (below) | |

Every change is written as it is made; there is no Apply. While the window is
open every row that reports the engine, and the notification permission, is
re-read every **2 s**; the two hook rows are re-read when the window opens, when
System or Health is shown and after each of System's buttons; the doctor and the
crash reports of the Health page when it is shown and on `Check Again`.

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
to be fixed or did not work without stopping MySidepulse, a **red stop sign**
for what was refused or is wrong and stops it, and a **spinner** for what is
still happening. The words are a fixed
vocabulary: Enabled / Disabled, Granted / Denied, Available / Missing, Valid /
Invalid, Failed, Sent, Downloaded, Stalled, Checking, Downloading. **One colour
rule holds on every page**: something MySidepulse needs set up (the hooks, the
terminal hook, the notification permission) reads green while it is there and,
missing, red when the wizard marks it required (only the Claude Code hooks) and
orange otherwise; a switch of the app's own that the user turned off reads
blue.

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
every spacing number, are the `macos-building-settings-pages` skill.

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

**Colours** plays what it recolours. Clicking a row's name or its small strip,
or changing its colour, selects the row and plays its state on the real strip
for 30 s through the Playground's preview, restarted at every change: Claude
working the working roll, Codex working, Copilot working and OpenCode working
their agent's roll, needs you the double blink, done the breath, command running the violet roll, battery critical its
breath, and the three battery bars the glance at 15 %, 50 % and 100 %, the top
of each band. `Stop`, leaving
the page or closing the window ends it. The large strip in Preview plays the
selected row's state on screen, and before any row is picked shows the real
state; under it, **Showing** and the `StatusCopy` sentence, then once a row is
picked **Playing** with a spinner and the seconds left, then **Ended**. The hex
field takes `#` and six hex digits, applied on Return or when the field is left;
anything else is put back. The colour well applies once it has paused for
0.3 s; the pictures follow it at once. `Reset` puts one colour back to its
default and is disabled at the default; `Reset All Colours` puts back all
eleven. A colour at its default stores nothing, so it follows the default. The
hint under the colours says that needs you and done are one colour for every
agent and which colour a failed and a succeeded command take; the note says
brightness is set on Strip. With no strip mounted, a note under
Preview says the colour plays on screen only. Every picture in the window, on
Strip and Playground too, draws each colour exactly as its hex, at full
brightness.

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

**Health** answers, at a glance, whether MySidepulse works, and it is two
tables and nothing else. It reports and changes nothing. **Health** holds the
checks: what has to be in place or running for MySidepulse to work, each green,
orange or red, never blue, its detail (the doctor's sentence, a path, a date) as
its tooltip; under the table, while a line is orange or red, a warning saying
where it is put right; its last row is `Check Again`, with a spinner beside it
until the doctor has answered and for at least half a second
(`K.healthMinimumBusy`). **Information** holds a few readings, blue. A
preference is on neither table, and neither are the version and updates (they
are General's), the mode, the battery, how long the app has run, its memory or
where it is installed.

**A hook line is on the table only once something of MySidepulse's is at the agent's hook file: never set
up, or removed, is no line at all**, whether or not the agent itself is on this Mac — the owner may simply
not use it, and an orange line for an agent nobody has set up would say nothing worth a glance. Claude
Code's hooks are the one exception that can still show empty: they are the required line, and stay it while
no other agent's hooks have something of ours instead; once another agent's do (Codex's, Copilot's or
OpenCode's) and Claude Code's do not, the Claude Code line leaves too — the owner may be using that agent
instead of Claude Code. With no agent at all set up, the Claude Code line stays red: the strip then follows
nothing. The terminal hook follows the same rule on its own single flag: no zsh block is no line, not an
orange one.

| Health line | When | Reads |
|---|---|---|
| Claude Code hooks | always, once the hook files are read, except while another agent's hooks have something of ours and Claude Code's have nothing | Enabled; Disabled in red (also while nothing of any agent's is set up); Invalid in red when `~/.claude/settings.json` cannot be read, or when the hooks run a copy of MySidepulse that is gone (the command as the tooltip); Failed in red when the hooks cannot append to the journal |
| Codex hooks | once something of ours is at `~/.codex/hooks.json` | Enabled, only while every event is there and trusted in `~/.codex/config.toml`; Disabled in orange (optional) when an event is missing, or when Codex does not trust one of them or has it switched off, with a fix saying Codex never runs it and to press Set Up Hooks; Invalid in orange when either file cannot be read, or when the hooks run a copy of MySidepulse that is gone; Failed in orange when the hooks cannot append to the journal |
| Copilot hooks | once something of ours is at Copilot's hook file | Enabled; Disabled in orange (optional) when an event is missing, when `disableAllHooks` turns them off in `~/.copilot/settings.json` or `~/.copilot/config.json`, or when the file belongs to another copy of MySidepulse (its events do not match); Invalid in orange when the hook file cannot be parsed as JSON; Failed in orange when the hooks cannot append to the journal |
| OpenCode plugin | once something of ours is at OpenCode's plugin path | Enabled; Invalid in orange when the plugin file is not this copy's — a stale plugin of another copy of MySidepulse, which Set Up replaces, or a foreign file, which Set Up refuses and must be removed by hand; Failed in orange when the plugin cannot append to the journal |
| Terminal hook | only while the zsh block is there | Enabled, in green |
| Notifications permission | always, once read | Granted, or Denied in orange |
| SidePulse strip | always, once the engine has answered | Available (each strip's name, LEDs and mount path as the tooltip); Missing in orange with none plugged in; Stalled in orange |
| Open at login and reopen after a crash (the launch agent) | always, once the engine has answered | Enabled; Disabled in orange (a crash would leave the strip frozen); Opened by hand in orange while this process is not the one launchd supervises, with the General page's warning |
| Phone notifications | only while the phone half is switched on | Enabled, or Invalid in orange when the topic or the server cannot be posted to, the masked topic and the server as the tooltip |
| The mysidepulse command | only while a command cannot reach the app over its socket | Failed in orange |
| Crashes in the last 7 days | only while there is one (`K.healthCrashWindow`, read from `~/Library/Logs/DiagnosticReports`) | the count in orange, the last one's date as the tooltip |

Four lines on a Mac where nothing is set up (Claude Code's red among them), five where Claude Code's and the
terminal's hooks work, up to eight with every agent's set up and working, eleven at most (`HealthLimits`).

| Information line | When | Reads |
|---|---|---|
| Last hook event | while any hook is set up | `12 s ago`, `5 min ago`, or `None yet` |
| Agent sessions | while any agent's hooks or plugin are set up | how many, or **None**; each session's agent, its state in the user's words and since when as the tooltip |
| Terminal commands | while the terminal hook is set up | how many, or **None**; each command's state as the tooltip |
| Showing | while a strip is plugged in | the `StatusCopy` sentence |

The doctor's checks run off the main queue, through the real socket, when the
page is shown and on `Check Again`; everything else on the page is the engine's
status and the notification permission, re-read every 2 s while the window is
open, the hook files, and the crash reports, read with the doctor.

**System** holds what MySidepulse needs from outside itself, each beside the
button that gives it. `Claude Code hooks` is **Enabled** in green, **Disabled**
in red with a warning to press Set Up Hooks, or **Invalid** in red when
`~/.claude/settings.json` cannot be read; the note says open sessions pick new
hooks up on their own. `Codex hooks`, in its own group while Codex is on this
Mac or its hooks are set up, is **Enabled** in green while every hook is in
`hooks.json` and trusted, **Disabled** in orange with a warning to press Set
Up Hooks (a warning saying Codex has not trusted them, so it never runs them,
when they are there untrusted or switched off in Codex), or **Invalid** in
orange when `~/.codex/hooks.json` or `~/.codex/config.toml` cannot be read,
with a warning naming the file; the note says Codex runs a hook only once it
is trusted, and that Set Up trusts these. `Copilot hooks`, in its own group while
Copilot is on this Mac or its hooks are set up, is **Enabled** in green,
**Disabled** in orange with a warning to press Set Up Hooks (also the reading
while `disableAllHooks` turns every hook off, with a warning naming both files
it can be in, `~/.copilot/settings.json` and `~/.copilot/config.json`, or when
the file belongs to another copy of MySidepulse, whose events do not match
this one's), or **Invalid** in orange when the hook file cannot be parsed as
JSON, with a warning to fix or remove `~/.copilot/hooks/mysidepulse.json` by
hand, since Set Up refuses a file it does not recognise; the note says Copilot
picks new hooks up at its next start, with no trust step of its own.
`OpenCode plugin`, in its own group while OpenCode is on this Mac or the
plugin is set up, is **Enabled** in green, **Disabled** in orange with a
warning to press Set Up Plugin, or **Invalid** in orange when the plugin file
is not this copy's: a stale plugin of another copy of MySidepulse, which Set
Up replaces, or a foreign file, which Set Up refuses and the warning says to
remove by hand; the note says a running server picks the plugin up within a
second, with no restart. `Terminal hook` is **Enabled** in green or **Disabled**
in orange with a warning to press Set Up Terminal Hook; the note says to open a
new terminal window after setting it up. A set-up or removal that fails shows
the installer's message as a warning under its group. `Notifications
permission` is **Granted** in green, or **Denied** in orange with `Allow
Notifications` (the same ask as the wizard's row, and the only other button
that may ask) and a warning saying where to turn them on in System Settings
once macOS has stopped asking; the hint says they only announce a newer
version.

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

**Tip** is a page of its own, the last, after Health, and it holds two cards.
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
every login, every agent's hooks fire at a missing command once per event, the
zsh line runs at every shell, and the journal, the settings and the ntfy topic
stay in Application Support.

The button asks for confirmation, then, in this order:

1. removes every agent's hooks (Claude Code's and Codex's entries, with
   Codex's trust of them, and Copilot's hook file and OpenCode's plugin
   whichever copy of the app wrote them), the zsh line and the backups the
   hooks left, while the binary they name is still inside the bundle;
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
| `hook [--agent claude\|codex\|copilot\|opencode] [--event NAME]` | the hook entry Claude Code, Codex and GitHub Copilot run, and OpenCode's plugin runs; reads the payload on stdin. The flag says who fired it and always wins; without it, Claude Code, with the nearest Claude Code process in the ancestry. `--event` names a Copilot event, which its payload does not; an unknown value or flag is ignored | always 0 |
| `led auto\|off\|toggle\|#RRGGBB\|<effect>` | sets the mode; `toggle` flips off ↔ auto | 0; 1 app down; 2 bad argument |
| `brightness cycle [--steps N]` | one step brighter on every plugged-in strip, off after the last step, then the first step again (below) | 0; 1 app down or no strip; 2 bad argument |
| `status [--json]` | mode, display (an agent state names its agents: `working (claude+codex)`), battery, strips, sessions with their agent, jobs, notifications (topic masked) | 0; 1 app down |
| `doctor` | twelve health checks | number of failures |
| `install-hooks` / `uninstall-hooks` | edits `~/.claude/settings.json`, after a backup to `settings.json.backup-mysidepulse`, and `~/.codex/hooks.json` the same way (backup `hooks.json.backup-mysidepulse`) when `~/.codex` exists, with their trust in `~/.codex/config.toml` (backup `config.toml.backup-mysidepulse`; removed first by `uninstall-hooks`); writes `~/.copilot/hooks/mysidepulse.json` when `~/.copilot` exists, and `~/.config/opencode/plugins/mysidepulse.js` when OpenCode is on this Mac, or deletes them (`uninstall-hooks` does every agent's, on the Mac or not); foreign hooks, shapes it does not recognise and a file at the last two paths that is not MySidepulse's are left alone; refused, file untouched, when the CLI is not inside an app bundle | 0; 1 if any event was declined, a file was not ours (`install-hooks` only: it refuses to touch a Copilot or OpenCode file it does not recognise; `uninstall-hooks` leaves such a file alone and still returns 0), or on error |
| `run …`, `job begin\|end …` | terminal jobs, each a line appended to the journal (§7) | the command's status; 2 bad usage |
| `notify [on\|off\|topic new\|topic T\|server URL\|test]` | notification settings; bare `notify` prints them, **including the full topic** | 0; 1; 2 |
| `autostart [on\|off]` | the launch agent | 0; 1; 2 |
| `shell-init zsh` | prints the zsh snippet | 0; 2 |

With no arguments it prints usage and exits 0.

**Brightness is perceived.** The strip's brightness (1–255) scales the LEDs'
power in a straight line, and the eye does not: a third of the power already
looks like most of full. So every brightness the owner sets, by the Strip
page's slider or by `brightness cycle`, is a perceived percent, and the
strip's value is `255 · (percent / 100)^γ`, never below 1 (`BrightnessCurve`);
every colour sent is scaled by it ([device.md](device.md) *Brightness*).
`K.brightnessGamma` is 2.0, measured by the owner's eye on a white strip: a
third of full looked like `brightness 30`, two thirds like 110. What is stored is
still the strip's 1–255. At the dim end one unit of the strip is a percent or
more to the eye, so a value can read back a percent off the one it was set from.

**`brightness cycle`** walks that brightness up in `N` steps even to the eye,
`k/N` of full for step `k`, then off, then the first step again. `N` is 1 to
`K.brightnessCycleMaxSteps` (10: beyond it the smallest steps land on the same
value), and 4 when `--steps` is left out (`K.brightnessCycleDefaultSteps`):
25 %, 50 %, 75 %, 100 %, off. A press goes to the first step brighter than now
by more than `K.brightnessCycleSlackPercent` (1 %), so a brightness a unit under
a step counts as that step and the press always moves visibly. Past the last
step it sets the mode `off`, exactly as `led toggle` does, and remembers the
mode it replaced (`config.json`, `ledModeBeforeOff`); the next press sets the
first step and brings that mode back, a forced colour or an effect as well as
`auto`. Any other change of mode forgets it, and with nothing remembered the
press brings back `auto`. Every plugged-in strip takes the same step, counted
from the brightest of them. With 3 steps from 50 %: 67 %, 100 %, off, 33 %,
67 %. It prints `brightness: 67% (LEDs: auto)` or `LEDs: off`, the percent read
back from the value set.

**The white LED.** On a strip that shows nothing, a press that lands on a step
lights LED 1, the leftmost, white at the new brightness (`#ba5eff`, which reads
as white on the strip, where `#ffffff` reads yellow) for
`K.brightnessPreviewSeconds` (2 s), restarted by each press, so the brightness
can be seen between presses. While the strip shows anything else, that shows
the new brightness itself, carried on from where it is (§3 *Carrying an
animation on*), and nothing is added: a white LED over an animation would
restart it when it left. The white is paint only, like the Playground preview;
the off step lights nothing.

`doctor` checks: app reachable; auto-start & restart (this process is the one
launchd supervises); hooks installed (all 15, except a "not set up" word while
another agent's hooks have something of ours and Claude Code's have nothing —
the owner may be using that agent instead — or a failure once nothing of any
agent's is set up); hook binary exists; hook command (informational); codex
hooks (a "not set up" word when nothing of ours is at `~/.codex/hooks.json`,
whether or not Codex itself is on this Mac; with something there, all 12
subscribed to a binary that exists and trusted in a readable
`~/.codex/config.toml`, naming the ones Codex does not trust); copilot hooks
(the same "not set up" word when nothing of ours is at Copilot's hook file;
with something there, all 7
subscribed to a binary that exists, and `disableAllHooks` fails the check even
then); opencode plugin (the same "not set up" word when no plugin file is at
OpenCode's plugin path; with one there, present and written by this copy of
MySidepulse); journal writable; last event age
(informational); strips (informational, shows `STALLED`); notifications (fails
only on an unusable server or topic).

## 12. Settings, permissions, failure modes

**Defaults:** mode `auto`; brightness 255; the colours of §3 *Colours*; launch
agent registered on first launch; notifications off; server `https://ntfy.sh`;
menu-bar item shown; the onboarding wizard not yet walked, so a first launch
opens it (§10).
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

**Environment:** `MYSIDEPULSE_DISABLE=1` makes `hook` do nothing, and `job` and `run` write no line (`run` still runs its command).
`MYSIDEPULSE_SKIP` and `MYSIDEPULSE_SHOW_AFTER` tune the zsh hooks.
`MYSIDEPULSE_REPLAY_JOURNAL` names a journal for `RealJournalReplayTests`.

**Permissions** (details in [macOS.md](macOS.md)):

| Permission | Used for | If denied |
|---|---|---|
| Removable volumes | writing `LEDS.LED` and `keepalive` | the strip stays as the device left it |
| Automation (Terminal, iTerm2) | asking which tab is in front | acknowledgement covers the whole terminal app instead of one tab; logged once |
| Network | ntfy; GitHub, for the update check (at launch, weekly, and on a press) and for the download a click on Update asks for | pushes fail and are logged; the version row under Updates says why a press could not check |
| Notifications | announcing a newer release found by an automatic check, and nothing else; **asked only by the onboarding's `Notifications` row**, never by the app on its own (§10) | no notification; the release shows in Settings all the same |

No Accessibility or Full Disk Access permission is used.

**The app does not:** subscribe to ntfy, or receive anything from the network
but the reply to an update check and the download a click on Update asked
for; fetch or install an update by itself (an automatic check only announces a
release);
read prompts, tool inputs or tool outputs (the hook drops them before writing);
change anything in Claude Code beyond its own hook entries, in Codex beyond
its own hook entries and their trust tables in `config.toml`, in GitHub
Copilot beyond its own hook file, in OpenCode beyond its own plugin, or
in `~/.zshrc` beyond its own block; push for terminal
jobs; identify which session an alert belongs to on the strip, beyond the
agent's colour while it works.

## 13. Every delay and threshold

| Constant | Value | Role |
|---|---|---|
| `alertSettleSeconds` | 1 s | alert must stand before it is painted |
| `doneVisibleSeconds` | 20 min | finished stays lit |
| `holdGraceSeconds` | 90 s | held finish → done after the last helper clears |
| `holdTTLSeconds` | 30 min | longest hold without an event |
| `agentStaleSeconds` | 240 s | silent subagent stops counting |
| `staleSeconds` | 2 h | silent session forgotten |
| `abortQuarantineSeconds` | 120 s | after an `Interrupt`, a tool or permission event without a turn id changes nothing |
| `idleSignalMinQuietSeconds` | 50 s | quiet needed before `idle_prompt` counts as a lost Stop |
| `abandonQuietSeconds` | 20 s | quiet before Claude's registry, a Codex rollout or a Copilot `events.jsonl` is consulted about a working turn; a Copilot wait has no quiet gate |
| `abandonRecheckSeconds` | 15 s | registry / rollout / `events.jsonl` / open-wait recheck |
| `CodexRolloutTail.tailBytes` | 64 KB | how much of a Codex rollout's end is read |
| `CopilotTranscriptTail.tailBytes` | 64 KB | how much of a Copilot `events.jsonl`'s end is read |
| `CodexDaemonClient.deadlineSeconds` | 1 s | the whole of one question to Codex's daemon, connection included |
| `dialogAnswerMinStampLeadSeconds` | 2 s | busy stamp must be this much newer than the dialog |
| `hooksSilentWarnSeconds` | 5 min | the registry, a rollout or an `events.jsonl` says the turn runs with no hook event → one log warning per session |
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
| `jobVisibleSeconds` / `jobStaleSeconds` | 20 min / 2 h | job outcome lit / running job with no owner pid |
| `jobProbeSeconds` | 15 s | a running job's shell asked whether it still runs a command |
| `jobPromptSettleSeconds` | 5 s | a shell seen at its prompt with no child of the job, seen so again this much later, clears the job |
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
| `jobLabelMaxChars` | 60 | a job's label, as its line records it |
| `pathMaxChars` | 1024 | a transcript path the hook records; identifiers stay at 200 |
| `playgroundPreviewSeconds` | 30 s | a Playground state or effect, or a Colours row, holds the strip this long, and each page's hint says the number |
| `brightnessGamma` | 2.0 | perceived brightness to the strip's `brightness N`, measured on the owner's strip |
| `brightnessCycleDefaultSteps` / `brightnessCycleMaxSteps` | 4 / 10 | `brightness cycle` without `--steps`; the most it takes, beyond which the dim end's steps land on the same value |
| `brightnessSliderStepPercent` | 5 % | the Strip page's brightness slider's step: twenty positions, each visibly different at the measured γ |
| `brightnessCycleSlackPercent` | 1 % | a step this close above the current brightness counts as reached |
| `brightnessPreviewSeconds` | 2 s | the white LED on a dark strip after a `brightness cycle` press, restarted by each press |
| `LedContinuation.frameMs` | 17 ms | what a program line with no timing lasts on the strip, counted in a loop's length |
| `resumeFromDarkSeconds` | 2 s | off and back within this resumes the same animation where it would have been |
| `LedContinuation.bridgeMs` | 60 ms | the longest bridge line, on which every lit LED moves to where it goes on from at the new brightness |
| `LedContinuation.riseToPeakFrom` | 0.5 | a rising pulse at or past this share of its peak rises to the peak on the bridge; below it, it starts over from black |
| Colour well pause | 0.3 s | a colour dragged in the colour panel is saved and written once it has paused this long (Colours, and the Playground's A colour) |
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
- Whether Codex fires `PreToolUse` for its `request_user_input` tool, and so
  whether a Codex question shows amber, is not established: the tool is
  mapped, and nothing has been observed.
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
all eight Settings pages and every sentence on them (§10), the `Showing`
sentences, the doctor's detail sentences and the hook-install outcomes as the
window shows them, and the phone push bodies (§6).

**What is not, and why.**

| Stays as it is | Because |
|---|---|
| Every word `mysidepulse` prints in a terminal (§11) | The CLI is English by rule, not by omission. The same code produces the doctor's details for both, and the language is read where the sentence is built, so the window is French while the terminal stays English. |
| The doctor's twelve check names (`app`, `hooks installed`, `device`, …) | Identifiers the CLI prints and the Health page matches on, not prose. |
| The push `Title` header (`Claude Code`, `Codex`, `GitHub Copilot` or `OpenCode`) and the five tags | Wire values. A translated tag loses the notification's icon on the phone. |
| The block in `~/.zshrc` and the shell snippet | Shell code, read by zsh. |
| `MySidepulse`, `SidePulse`, `Claude Code`, `Claude`, `Codex`, `GitHub Copilot`, `Copilot`, `OpenCode`, `ntfy`, `LED`, `LEDs`, `Terminal`, `iTerm2`, `Finder`, `zsh`, `Dock`, `Spotlight` | Product names. |
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
