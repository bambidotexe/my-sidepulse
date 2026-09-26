# macOS boundary

Where MySidepulse meets the operating system: the card slot, volumes, sleep,
permissions, launchd, signing. The strip's protocol is in
[device.md](device.md); the traps behind many of these choices are in
[pitfalls.md](pitfalls.md).

## The card slot and volumes

The strip is a mass-storage device in the SD slot. macOS mounts it under
`/Volumes` like any card; the app never opens a raw device, a serial port or a
HID interface.

**Discovery** (`DeviceMonitor`, DiskArbitration):

| Callback | Handling |
|---|---|
| disk appeared, description changed (with a volume path) | probe the mount for `LEDS.LED`, off the main queue; report it if its identity is new |
| description changed (no volume path) | a bare unmount: `reconcile()` — re-probe every known mount by identity |
| disk disappeared | drop the device recorded at that path; without a description, `reconcile()` |
| eject approval | the eject guard, below |

On top of the callbacks: a `/Volumes` scan at start, a rescan every
`K.deviceRescanSeconds` (300 s, 30 s leeway), and — if `DASessionCreate` fails —
a scan plus a session retry every `K.deviceSessionRetrySeconds` (30 s).

Callbacks arrive on the main queue. Every `stat` and `fileExists` runs on
`mysidepulse.deviceprobe`, because those calls block uninterruptibly on a dying
volume.

**Identity** is `(st_dev, st_ino)` of the mount point. The same path with a new
identity is a new device: the old one is retired and the new one painted.

**Eject guard.** When DiskArbitration asks to approve an eject and the disk's
description says the reader is the built-in one — device protocol containing
`Secure Digital`, or device model containing `SDXC` (`EjectGuard`) — the app
returns a dissenter (`kDAReturnNotPermitted`, "MySidepulse is keeping the SD card
attached") and starts remounting: every `K.ejectRemountRetrySeconds` (5 s) it
asks the session for a fresh `DADisk` by BSD name and calls `DADiskMount`, until
the disk has a volume path again or no longer exists. Ejects on any other
reader are approved. The match is on the reader, not the volume.

**Power.** `Keepalive` touches `<mount>/keepalive` every 60 s through
`/usr/bin/touch`, so the reader is never idle long enough for macOS to power it
down.

**Removal.** Pulling the card is the supported way to remove it.

## Sleep and wake

- The engine's deadline timer is scheduled with `wallDeadline`, so time asleep
  counts.
- `NSWorkspace.didWakeNotification` calls `Engine.machineWoke()`, which is one
  `sync()`: every rule is re-evaluated against the wall clock at once. A
  `done` older than 20 min becomes `idle`, holds past their grace or TTL
  resolve, sessions silent for 2 h are forgotten, and a push more than
  `K.notifyMaxLatenessSeconds` (120 s) overdue is dropped instead of sent.
- Nothing special is done for the card. If it lost power or was ejected during
  sleep, DiskArbitration reports it (and the eject guard remounts it); otherwise
  the 300 s rescan finds it. The keepalive, rescan, power-refresh and
  DiskArbitration-retry timers run on the monotonic clock and do not advance
  during sleep.
- A plug or unplug noticed after wake shows the 7 s battery glance like any
  other.

## Battery

`PowerMonitor` adds an `IOPSNotificationCreateRunLoopSource` to the main run
loop and re-reads every `K.powerRefreshSeconds` (300 s). It reads the internal
battery only (`kIOPSInternalBatteryType`): percent, plugged, charging, charged.
A source without a current-capacity value yields no reading.

## User presence and focus

| Input | API | Permission |
|---|---|---|
| Frontmost app | `NSWorkspace.didActivateApplicationNotification`, `frontmostApplication` | none |
| Seconds since any input | `HIDIdleTime` on the `IOHIDSystem` registry entry | none |
| Screen locked | `CGSessionCopyCurrentDictionary`, key `CGSSessionScreenIsLocked` | none |
| Whether a host app can be focused | `NSRunningApplication`, activation policy `.regular` | none |
| Front terminal tab | `/usr/bin/osascript` → Terminal (`tty of selected tab of front window`) or iTerm2 (`tty of current session of current tab of current window`) | Automation |

Input idle time is polled every 0.5 s, and only while an alert is on the strip.
The tab probe runs at most once per 2 s per terminal, with a 0.5 s timeout.

## Process inspection

All through `sysctl` and `libproc`, with no subprocess and no permission:
`KERN_PROC_PID` for parent, name and controlling tty; `proc_pidpath` and
`KERN_PROCARGS2` for the executable path and environment; `KERN_BOOTTIME` for
the boot time; kqueue `EVFILT_PROC` for exits. This is how the hook finds the
agent's process (the nearest ancestor running the agent it speaks for, its
`--agent` or else Claude Code: Claude by a `claude` name or
path component, Codex by a `codex` one, which covers the standalone release
under `~/.codex/packages`, the `~/.local/bin` launcher and the copy inside
`ChatGPT.app`, Copilot by an executable named `copilot`, OpenCode by one
named `opencode`, `opencode-cli` or `.opencode`; the name, then the resolved
path, then the exec path), its host app and its terminal tab, and how the app
tells Codex's daemon by its arguments.

**A shell at its prompt owns its terminal's foreground process group.**
`kinfo_proc.kp_eproc` carries the process group (`e_pgid`) and its terminal's
foreground group (`e_tpgid`, 0 without a terminal; `ps -o pid,pgid,tpgid`).
At the prompt the two are equal; while the shell runs a foreground command it
has handed the group to the command's (a zsh running `claude` showed
`claude`'s pid as its `tpgid`), and the command is its child
(`proc_listchildpids`). A shell's children are not only its commands:
Powerlevel10k starts a `gitstatusd` (`~/.cache/gitstatus/gitstatusd-darwin-arm64`)
in the shell's own process group when the shell starts and keeps it for the
shell's life, and an earlier `&` job stays a child too; only a child forked after a
command began belongs to that command. `ProcWalk.info` reads the groups and
the fork time (`p_starttime`, `ProcInfo.startedAt`), `ProcWalk.childStartTimes`
each child's fork time. A builtin that blocks (`wait`, `read`, a loop of
builtins) keeps the group and forks nothing: it looks like the prompt. `exec`
keeps the pid and the fork time and changes `p_comm`; a login shell's `p_comm`
starts with `-` (`-zsh`).

**Re-reading the snippet.** `source ~/.zshrc` runs the snippet again inside the
`source` command, between its `preexec` and its `precmd`; `exec zsh` starts a
new image under the same pid that reads it from scratch. Any variable the
snippet assigns at load is reset in both, so it declares its job variable
without assigning it (`(( ${+_mysidepulse_job} )) ||
typeset -g _mysidepulse_job=`), and an interactive shell loading it sends
`job end --id zsh-$$ --exit 130`, which ends whatever job an earlier image of
that pid began (a `job end` for an unknown id changes nothing). A subshell that
re-reads it (`(source ~/.zshrc; make)`) is still interactive and its `$$` is
the parent's, so its load ends the parent's running job.

Claude Code's registry, `<config>/sessions/<pid>.json`, lives in the config
directory, which `CLAUDE_CONFIG_DIR` relocates (an account switcher such as
cswap sets it per account). The app finds it from the transcript path the
hooks name, `<config>/projects/<slug>/<session>.jsonl`: the parent of the
last `projects` folder at least two levels above the file
(`ClaudeProcessRegistry.configDir(fromTranscriptPath:)`). Only for a session
no line has named a transcript for is the process's own `CLAUDE_CONFIG_DIR`
read from `KERN_PROCARGS2`, then `~/.claude` taken. Another same-user
process's environment is not relied on: `ps -E` prints a running Claude's
here, but a reader has been seen to get none.

Codex's TUI does not run its sessions' hooks itself: Codex's managed daemon
does, `codex app-server --listen unix:// --managed-daemon`, installed under
`~/.codex/packages/app-server-daemon/releases/<version>/bin/codex`, one per
user, started by the first TUI, parented by launchd and alive across every
TUI. It keeps a thread loaded for 30 min after its last
subscriber is gone, so a killed TUI does not stop a running turn. The nearest
`codex` in a TUI hook's ancestry is therefore the daemon, and every TUI
session records the daemon's pid; `ProcWalk.isCodexDaemon` recognises it by an
`app-server` argument (`KERN_PROCARGS2`) or, when the arguments cannot be
read, by the `/app-server-daemon/` folder. The ChatGPT app's threads run under
the app's own `codex`, which is a shared app-server too (it carries an
`app-server` argument) and lives as long as the app, so its pid proves no
single thread either. Only `codex exec` runs in a process of its own.

Codex writes one rollout per session,
`~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<session id>.jsonl`, and names
it in every hook payload as `transcript_path`. Each line is a JSON object with
a `timestamp` (ISO 8601, milliseconds, UTC) and a `type`; the turn-level lines
are `type: "event_msg"` with `payload.type` `task_started`, `task_complete` or
`turn_aborted`, each carrying `payload.turn_id`, and they balance exactly (399
started, 392 complete, 7 aborted across the 55 rollouts of 2026-09-25).
`item_completed`, `token_count` and `thread_settings_applied` are item-level,
and an `item_completed` can follow a `turn_aborted` for the same turn. The rest
of a line is the conversation; the app reads the last 64 KB of the file, keeps
the types, turn ids and stamps, and nothing else. Codex sends the same
`turn_id` on every hook event but `SessionStart` and `SessionEnd`. It fires
`SessionStart` lazily, at the first prompt rather than when the TUI opens, so a
thread quit before any prompt sends a `SessionEnd` alone; `SessionEnd` fires at
thread shutdown, every clean TUI exit, and its `reason` is always `other`.

Codex's managed daemon answers on a control socket:
`~/.codex/app-server-control/app-server-control.sock` (`Paths.codexControlSocket`)
is a symlink to the daemon's socket, `/private/tmp/codex-daemon-<uid>/<hash>`,
mode `0600`, present while the daemon runs; a stale link can outlive it, so
the link is resolved and the target must be a socket. It speaks WebSocket over
the unix socket, with no token: an HTTP/1.1 `GET /` with `Host: localhost`,
`Upgrade: websocket`, `Connection: Upgrade`, a 16-byte base64
`Sec-WebSocket-Key` and `Sec-WebSocket-Version: 13` is answered `101 Switching
Protocols` (with `sec-websocket-accept` and
`x-codex-websocket-max-unfragmented-message-bytes` headers), then JSON-RPC 2.0
in text frames, masked from the client, unmasked from the daemon. The app does
not check `Sec-WebSocket-Accept`: the socket is the user's own `0600` local
socket, and a `101` is all the exchange needs. The daemon's answers carry `id`
and `result` (or `error`) and no `jsonrpc` field, and it sends notifications
(`method`, `params`, `emittedAtMs`, no `id`) between them, one of them
(`remoteControl/status/changed`) between the `initialize` answer and the next.
The app sends three methods and one notification, and nothing else:
`initialize` `{clientInfo: {name, title, version}}`, answered `{userAgent,
codexHome, platformFamily, platformOs}`; then `initialized`; then either
`thread/read` `{threadId, includeTurns: false}`, answered `{thread: {id,
status: {type}, path, createdAt, updatedAt, recencyAt, cwd, originator, …}}`
with the stamps in Unix seconds, where `status.type` is `notLoaded` (not in
memory; the thread is still read from its rollout on disk), `idle` (loaded, no
turn) or `active` (a turn runs, with `activeFlags` naming a pending approval
or question); or `thread/loaded/list` `{}`, answered `{data: [<thread id>…],
nextCursor}`, the threads held in memory (all of them in one page when no
`limit` is given; `nextCursor` is `null` then). The daemon holds the TUI's
threads only: a `codex exec` thread runs in its own process and a desktop-app
thread in the app's own `codex app-server` (no `--managed-daemon` argument,
which `ProcWalk.isManagedCodexDaemon` reads), so what the daemon says of
either proves nothing. Captured by a read-only probe against Codex 0.157;
`CodexDaemonClient`, `CodexThreadRecord` and `WebSocketFrame` hold it.

## Codex: its hooks and their trust

Codex reads the user's hooks from `~/.codex/hooks.json`, the same `hooks`
object as Claude Code's `settings.json`, under a root that may also hold a
`description`. A missing `matcher` matches everything (`"*"` does too; any
other matcher is a regular expression). Hooks can also live in `config.toml`
under `[hooks]`; loading both draws a warning, so only the JSON file is
written.

**Codex runs a user hook only while it is trusted**: `~/.codex/config.toml`
holds `[hooks.state."<key>"]` with a `trusted_hash` equal to the hash Codex
computes for the hook, and `enabled` not `false` (its `/hooks` screen writes
the table, and switches a hook off with `enabled = false` in it). The key is
`<hooks.json path>:<event label>:<group index>:<handler index>`, the label
the event's snake_case name (`PreToolUse` → `pre_tool_use`), the path Codex's
home with symlinks resolved, then `hooks.json` (`Paths.codexHooksTrustName`).
The hash is `sha256:` and the SHA-256 of the canonical JSON (keys sorted, no
spaces) of `{"event_name": <label>, "hooks": [<the entry, normalised>]}`; a
normalised command entry is `{"async": false, "command", "timeout", "type":
"command"}`, plus the matcher when there is one, and Codex clamps the timeout
of `SessionEnd` and `Interrupt` to 1–3 s before hashing. A hook whose hash no
longer matches reads as modified in the `/hooks` screen and stops running.
Read from Codex's source (`codex-rs/hooks/src/lib.rs`, `engine/discovery.rs`,
`config/src/fingerprint.rs`) and checked against Codex CLI 0.157.0: its
`hooks/list` answer reported the hashes `CodexHookTrustTests` pins, and a hook
trusted by a table of this shape fired on a real turn. `CodexHookTrust`
reproduces key and hash, with Core's own `SHA256`.

Codex writes each state as a `[hooks.state."<key>"]` table; a state written
as an inline table (`state = { … }` under `[hooks]`, or `"<key>" = { … }`
under `[hooks.state]`) is valid TOML too, and a second definition of the same
key beside it would make the file invalid, which is why the set-up refuses
such a file rather than add to it.

`CODEX_HOME` moves the whole folder for a Codex started with it set. Like
`CLAUDE_CONFIG_DIR`, it is invisible to the app, which launchd starts, so the
installer, its trust and the app's pages all use `~/.codex`.

## GitHub Copilot CLI: its hooks and its process

Observed with Copilot CLI 1.0.88 on this Mac (`copilot -p`, interactive runs,
an offline run against a local model).

**User hooks** load from every `*.json` file in `~/.copilot/hooks/` (or
`$COPILOT_HOME/hooks/`), read at each `copilot` start, with no trust step and
no flag; hooks from every source add up. The folder does not exist until
something creates it. A file is `{"version": 1, "hooks": {"<event>": [entry…]}}`;
an entry in the `exec` form, `{"type": "command", "exec": "<abs path>",
"args": [...], "timeoutSec": N}`, runs the program with no shell, as a direct
child of the `copilot` process. An unknown event key is ignored and the rest
of the file still loads. `disableAllHooks: true` in `~/.copilot/settings.json`,
or in `~/.copilot/config.json` (JSON whose first lines are `//` comments, and
which Copilot rewrites itself), turns every user hook off.

**Events and payloads.** A hook keyed in camelCase gets a camelCase payload:
`sessionId` (a UUID, the name of the session's folder
`~/.copilot/session-state/<id>/`), `timestamp` in ms, `cwd`, and no event
name; `toolName` on tool events; `notification` carries snake-case
`notification_type` (`permission_prompt`, `elicitation_dialog` for an
`ask_user` question, `shell_completed`) and a `message` and `title`;
`agentStop` carries `transcriptPath` (the session's `events.jsonl`) and
`stopReason`; `sessionStart` carries `source` (`new`, `resume`, `startup`),
`sessionEnd` a `reason` (`complete` after every `-p` turn, `user_exit` at an
interactive exit). `sessionStart` is lazy: it fires with the first prompt,
after `userPromptSubmitted`, and an interactive exit fires `sessionEnd` for a
session that never started. A subagent's own `userPromptSubmitted` and
`agentStop` carry the subagent's id, which has no folder under
`session-state`, and the parent's `transcriptPath`. Answering a permission or
a question fires no hook; Ctrl+C or Esc Esc fires none either, and a turn
whose model call fails fires only `errorOccurred`, with no `agentStop`.

**Exit codes.** `preToolUse` is fail-closed: a non-zero exit, a crash or a
missing binary denies the tool, and exit 2 denies for `preToolUse` and
`permissionRequest` alike; every other event is fail-open. Hooks run in
sequence and the agent waits for them (5 s at most for ours). Stdout that is
JSON is read as a decision; ours prints nothing.

**The process.** One `copilot` process per invocation, the hook's direct
parent: `~/.local/bin/copilot`, or for GitHub Copilot.app
(`/Applications/GitHub Copilot.app`, executable `github`) a pooled copy at
`~/Library/Caches/github-copilot-sdk/cli/<version>/copilot`. `p_comm` and the
executable's last component are `copilot` in both. One process can hold
several sessions; there is no daemon, and nothing outlives the process that
hosts a session. Copilot's own package, unpacked under
`~/Library/Caches/copilot/pkg/`, holds other programs, so only the last
component names Copilot. While a session is open,
`session-state/<id>/inuse.<pid>.lock` names its process; a killed process
leaves it behind.

**The session's log.** `~/.copilot/session-state/<id>/events.jsonl`, one JSON
object per line, `{type, data, id, timestamp, parentId}`, `timestamp` in ISO
8601 with milliseconds. A turn at work writes `user.message`,
`assistant.turn_start`, `assistant.message`, `tool.execution_start`,
`tool.execution_complete`, `permission.requested` and `permission.completed`;
`assistant.turn_end` ends every model call, not the turn. A permission prompt
answered (approved or denied) writes `permission.completed` and fires no hook;
a second prompt can open 2 ms later, still with no hook between. Its ends: `abort`
(`data.reason` `user_initiated` for Ctrl+C or Esc Esc), `session.error` (a
failed turn: the retries of a model call write only their `errorOccurred`
hook's mirror, and only the last failure writes it), and `session.shutdown`
(the session closing: after every `-p` turn, at an interactive exit).
Every hook that runs is mirrored as a `hook.start` (`data.hookType`, and
the hook's payload in `data.input`) and a `hook.end`, so with MySidepulse's
hooks set up a natural end is the `hook.start` of the session's `agentStop`;
a subagent's `agentStop` is mirrored into its parent's file under the
subagent's id (`data.input.sessionId`), before the parent's own. There is no
finished marker without hooks: `session.idle` and `assistant.idle` are never
written. A turn's opening `system.message` is up to 91 KB, and a `/compact`
writes about 95 KB of model lines; everything else written after a turn's end
came to at most 6.7 KB in the five probe sessions of 2026-09-25. MySidepulse
reads the last 64 KB of the file of a quiet working session, and of a
session in an open wait (`CopilotTranscript`, a regular file only, opened without blocking), and of
its lines only the type, the stamp, and a `hook.start`'s hook name and
session.

## OpenCode: its plugin and its server

Observed with OpenCode 2.0.17 on this Mac.

**One server.** The TUI, `opencode run` and OpenCode.app are all clients of
one background server, `opencode serve --service`, parented by launchd, whose
working folder is the home folder; it hosts every session of every client and
every folder. `--standalone` runs a private `opencode-cli serve --stdio`
under its client instead, which dies with it. The server's executable is
`opencode` (`~/.opencode/bin/opencode`), `opencode-cli` (inside
`/Applications/OpenCode.app/Contents/Resources/`, and the copy the app stages
under `~/Library/Application Support/ai.opencode.desktop/cli/<version>/`) or
`.opencode` (the npm package's). A turn survives its client: only the
server's exit ends its sessions.

**Plugins.** OpenCode has no command hooks. Every `.js` or `.ts` file in
`~/.config/opencode/plugins/` (or `plugin/`) is loaded by the server, with no
registration and no trust step; a file written, changed or deleted is
loaded, reloaded or dropped within a second. OpenCode 2's shape is `export
default { id, setup(ctx) }`; a v1 plugin (the one OpenCode's public
documentation still describes) fails to load, and a second plugin with an id
already loaded is refused. The server starts one instance per open folder,
and every instance receives every folder's events, so a plugin has to
de-duplicate them; `globalThis` is shared by all of them. A plugin's failure
is a line in `~/.local/share/opencode/log/opencode.log`, and nothing else
breaks.

**Events.** `ctx.event.subscribe()` yields `{id, created, type, data}`. A
busy period opens with `session.execution.started` and ends with exactly one
of `session.execution.succeeded`, `.failed` or `.interrupted` (`reason`
`user`, `shutdown`, `inactivity`); `session.idle` and `session.status` are
never published. A prompt is `session.inbox.enqueued` with an item of type
`user`; a tool is `session.tool.called` then `.success` or `.failed`, its name
only on the `session.tool.input.started` before them; a permission is
`permission.asked` then `permission.replied` (`once`, `always`, `reject`),
about 3 ms apart when the permission is granted by rule or by `--auto`; the
question tool is `form.created` with `metadata.kind == "question"`, then
`form.replied` or `form.cancelled`; a subagent is a session created with a
`parentID`. A process the plugin spawns has the server as its parent. A
standalone server is torn down before its last events when its client quits
mid-turn.

## Permissions

The app is not sandboxed (`Resources/MySidepulse.entitlements`,
`com.apple.security.app-sandbox` false: the app writes to the LED strip,
which mounts as a removable volume, and reads the Claude Code journal under
Application Support). `Info.plist` declares two usage strings, and each also
ships translated in `Contents/Resources/{en,fr}.lproj/InfoPlist.strings`:
macOS reads a usage string from the bundle, not from the running app, so
these two are the one piece of user-facing text the Swift string tables
cannot hold. The `Info.plist` values are the fallback for a system that is
neither.

| Key | Asked when | If denied |
|---|---|---|
| `NSRemovableVolumesUsageDescription` | first access to the strip's volume, if macOS asks at all | `LEDS.LED` and `keepalive` cannot be written; the strip stays as the device left it |
| `NSAppleEventsUsageDescription` | first tab probe of Terminal or iTerm2 | AppleScript errors `-1743` / `-1744` are remembered for the process, a warning is logged once, and acknowledgement falls back to the whole terminal app |

User notifications are the one permission the app asks for through an API
rather than through first use, and **`UNUserNotificationCenter.requestAuthorization`
is called in exactly one function, `OnboardingCatalog.requestNotifications`,
reached from two buttons only**: the onboarding's `Notifications` row and
Settings › System's `Allow Notifications`. Nothing else in the app may call it.
A request API returns the state at the moment of the call and prompts as a side
effect, so using one to read a grant behind the wizard's 2 s poll would be a
prompt every two seconds; `UpdateNotifier`, the wizard's rows and the Settings
window's 2 s tick all read with `getNotificationSettings`. A refusal macOS has recorded is permanent, which is
why no prompt may ever arrive unasked.

Granting Automation is not enough on its own: the entitlements file also
carries `com.apple.security.automation.apple-events` true. The Hardened
Runtime refuses to send an Apple Event without that entitlement whatever the
user has allowed under Automation in System Settings — `TerminalTabProber`'s
question to Terminal or iTerm2 would fail with `errAEEventNotPermitted` and
every tab would look visible. `scripts/release.sh` asserts the entitlement is
present in the built app rather than trusting it.

Not used: Accessibility, Full Disk Access, Input Monitoring, location, camera,
microphone.

Network: outbound HTTPS (or HTTP) to the configured ntfy server, only when
notifications are on; HTTPS to `api.github.com` for the update check, shortly
after launch, weekly after that and when **Check for Updates** is pressed; and
HTTPS to the release asset's host only after a click on **Update**. Nothing
listens on the network; the control socket is a
Unix-domain socket with mode `0600`.

Files touched outside the app's own directory: `~/.claude/settings.json`
(read and written by `install-hooks` / `uninstall-hooks` and by Settings ›
General › Hooks, after a backup), `~/.zshrc` (the app's own block, written and
removed from the same Hooks rows), `~/.codex/hooks.json` and
`~/.codex/config.toml` (MySidepulse's entries in the first and their trust
tables in the second, each file backed up before it is written),
`<config>/sessions/*.json` and the session transcript (read only), and a Codex
session's rollout under `~/.codex/sessions/` (its last 64 KB, read only).
Sockets connected to outside the app's own: Codex's managed daemon's control
socket, for `thread/read` and `thread/loaded/list` only, 1 s per call.

## launchd

`~/Library/LaunchAgents/io.mysidepulse.agent.plist`, written by
`LoginService.install()`:

| Key | Value |
|---|---|
| `Label` | `io.mysidepulse.agent` |
| `ProgramArguments` | the absolute path of the running GUI binary |
| `RunAtLoad` | `true` |
| `KeepAlive` | `{ SuccessfulExit = false }` — restart after a crash, a signal or a kill; leave a deliberate Quit alone |
| `ProcessType` | `Interactive` |
| `LimitLoadToSessionType` | `Aqua` |
| `AssociatedBundleIdentifiers` | `[io.mysidepulse.app]` — System Settings › General › Login Items files the agent under MySidepulse, with its name and icon; without it Background Task Management groups a legacy agent by its signing team and the row reads "Wooflab" |

It is bootstrapped with `/bin/launchctl bootout gui/<uid>/io.mysidepulse.agent`
followed by `bootstrap gui/<uid> <plist>`. This one registration is both "open
at login" and "restart on crash".

- On every launch that launchd did not start, the app rewrites and
  re-bootstraps the agent so it points at the running copy — unless the user
  turned it off (`autoRestartWanted == false`).
- `launchedByOwnAgent` is `XPC_SERVICE_NAME == io.mysidepulse.agent`. When true,
  install and remove only touch the plist: booting the job out would kill the
  process doing it.
- Reported state: `disabled` (no plist), `enabled` (plist, and this process is
  the agent's), or `agent installed, but this process was not started by it —
  no crash restart`.
- At every launch `migrateFromLoginItem()` unregisters an `SMAppService` login
  item or bundled agent if one is still enabled.
- A second instance terminates itself at launch.
- launchd restarts a dead process, not a hung one.
- **Install and Relaunch** puts the new copy at the same path and starts it
  the way the copy that quit had been started: `launchctl kickstart
  gui/<uid>/io.mysidepulse.agent` when that one ran as the agent's job, so the
  new version is the job too (`XPC_SERVICE_NAME` is the label, measured on a
  job that had exited 0: kickstart starts it again and answers 0), and `open`
  otherwise. An update dragged in from a DMG by hand is a manual launch:
  reopened by hand it re-registers the agent for the new copy, and is itself
  unsupervised until the next login.
- When a job's main process exits, launchd kills whatever is left in the job's
  process group (measured: a plain `posix_spawn` child of a job that exits is
  gone before it runs; a child spawned with `POSIX_SPAWN_SETPGROUP` and group
  0 runs on). The install helper is spawned that way (`DetachedProcess`).

## Bundle and signing

`scripts/make-app.sh` assembles `build/MySidepulse.app`:

```
Contents/Info.plist
Contents/PkgInfo                 APPL????
Contents/MacOS/MySidepulseApp      GUI; CFBundleExecutable
Contents/MacOS/mysidepulse         CLI
Contents/Resources/AppIcon.icns    flat icon, behind CFBundleIconFile
Contents/Resources/Assets.car      Liquid Glass icon, behind CFBundleIconName
Contents/Resources/en.lproj/InfoPlist.strings   the two usage strings, English
Contents/Resources/fr.lproj/InfoPlist.strings   the two usage strings, French
```

signed with `Resources/MySidepulse.entitlements` (not sandboxed, the
Automation Apple Events entitlement — see *Permissions* above).

`Info.plist`: `CFBundleIdentifier` `io.mysidepulse.app`, `CFBundleName` and
`CFBundleDisplayName` `MySidepulse`, `LSUIElement` `true`,
`LSMinimumSystemVersion` `26.0`, version from `VERSION`, `CFBundleIconFile` and
`CFBundleIconName` both `AppIcon`, `CFBundleLocalizations` `en` and `fr` (which
is also what puts the app in System Settings › Language & Region's per-app
language list), and the two usage strings above.

The deployment target is macOS 26 for the window's sake as much as the icon's:
SwiftPM records the target as the binary's SDK version, and AppKit draws the
Liquid Glass design only for a binary whose recorded SDK is 26 or later
([pitfalls.md](pitfalls.md)).

Both icon forms ship. `CFBundleIconName` resolves inside `Assets.car`, which is
what macOS renders; the `.icns` behind `CFBundleIconFile` is kept for whatever
reads that key instead. The `.icns` is rasterised from the 1024 px
master rather than taken from `actool`, whose output carries 16 px and 128 px
only. An `.icns` has to bake in its own rounded mask — macOS does not apply one
— which is why the master used for it is the masked preview.

The GUI binary is named `MySidepulseApp` because `Contents/MacOS` is on a
case-insensitive volume, where `MySidepulse` and `mysidepulse` are the same file.

Signing is with the Wooflab team's Developer ID Application certificate
(`scripts/signing.env`'s `SIGN_IDENTITY`, looked up in the keychain by team
identifier `TEAM_ID`), under the Hardened Runtime, on each binary and then
the bundle, innermost first so the outer bundle's seal is applied last.
`scripts/release.sh` additionally notarizes and staples the app and the disk
image it ships in. `SIGN_IDENTITY="-"` in the environment signs ad-hoc
instead — no entitlements, no Hardened Runtime, no notarization — for a
throwaway build that cannot be shipped. `Info.plist` does not set
`LSFileQuarantineEnabled`, so a DMG the app downloads is not quarantined by
the app; one fetched with a browser is, but a notarized, stapled build opens
without a Gatekeeper prompt either way. Because a Developer ID build's code
identity is the same across rebuilds, `make install`'s repeated installs do
not by themselves give macOS a reason to ask for the Automation permission
again; an ad-hoc build's does change on every build and may.

`LSUIElement` apps have no Dock icon and no main menu. The app builds a minimal
App / Edit / Window menu so the settings window's text fields and ⌘W work, and
switches to a regular activation policy — Dock icon, ⌘-Tab entry — for as long
as the settings window is open. The status item's visibility is
`NSStatusItem.isVisible`, driven by the `showInMenuBar` default.

## The release disk image

`scripts/make-dmg.sh` builds the disk image a release ships, and Finder does
not scale its background: it draws it at natural size from the top-left of
the icon view's content area, and Finder's own bars (title, tab, status/path)
can cover up to about 120 points at the bottom of the window. The canvas
`scripts/dmg-background.swift` renders is 660×480 with every mark inside the
top 340 points and a plain field below, matching the window
`scripts/dmg-settings.py` lays out (660×480 at (200,200), 128 px icons,
`MySidepulse.app` at (165,246) and `Applications` at (495,246), labels at the
bottom, no sidebar, toolbar or status bar). The background is rendered at 1x
and 2x and combined into one Retina TIFF with `tiffutil -cathidpicheck`,
because that is the one file Finder reads a disk image's Retina background
from.

The volume's own icon is not the bundled `AppIcon.icns`: that file is
rasterised by `make-app.sh` from a static 1024 px preview PNG and is a flat
stand-in. The real icon, built from the Icon Composer document and compiled
into `Assets.car`, exists only as the system's own rendering of the bundle —
`scripts/dmg-volume-icon.swift` asks `NSWorkspace` for that rendering and
builds the volume's iconset from it.

## Updates: disk images, signatures, the helper

- GitHub's anonymous `GET /repos/<owner>/<repo>/releases/latest` lists each
  asset with `size` and `digest: "sha256:<hex>"`, and `browser_download_url`
  answers 302 to a 200 that carries `content-length`. A repository that is
  private, or has no release, answers 404.
- A file this app fetches itself is not quarantined (the bundle does not set
  `LSFileQuarantineEnabled`), so the copy taken out of its disk image opens
  without a Gatekeeper prompt regardless; a release built by
  `scripts/release.sh` is notarized and stapled as well.
- `hdiutil attach <dmg> -nobrowse -readonly -noautoopen -mountpoint <folder>`
  mounts a release's one volume on a folder of our choosing, so nothing of its
  output is parsed. On macOS 27 it still works and prints a deprecation notice
  naming `diskutil image attach --readOnly --nobrowse --mountPoint <folder>`,
  which the stager falls back on. `hdiutil detach <folder> -force` unmounts;
  `diskutil eject` is the fallback. `diskutil eject <plain folder>` names the
  volume the folder sits on, which is the Mac's own, so only a folder whose
  device differs from its parent's is detached.
- `FileManager.copyItem` out of the mounted image keeps the bundle's signature
  valid. `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures |
  kSecCSCheckNestedCode | kSecCSStrictValidate` is what `codesign --verify
  --deep --strict` checks, and it passes on this app's bundle, the CLI nested
  in it included; a tampered copy fails with `errSecCSBadResource`. The
  running app's team identifier (`SecCodeCopySigningInformation`,
  `kSecCodeInfoTeamIdentifier`) is the Wooflab team's, so an update copy is
  additionally held to a requirement on that same team (`anchor apple generic
  and certificate leaf[subject.OU] = "<team>"`); an ad-hoc copy, an unsigned
  one or one signed by a different team refuses with `errSecCSReqFailed`. A
  running app with no team identifier — an ad-hoc or unsigned build — has no
  signer to compare with, so its replacement only has to carry an intact
  signature.
- `ps -axo comm=` prints each process's full executable path, which `grep -Fx`
  matches exactly: that is how the helper sees the new version running.
- Moving a bundle is one `rename(2)` when source and destination are on the
  same volume, which is why the update is unpacked under Application Support
  and refused when the app lives on another volume.
- `UNUserNotificationCenter.current()` traps in a process with no bundle, which
  a binary run out of `.build` is. A notification's action button belongs to
  its `UNNotificationCategory`; with `.foreground` the click brings the app
  forward. Both the button and a click on the notification reach
  `userNotificationCenter(_:didReceive:withCompletionHandler:)`, the second as
  `UNNotificationDefaultActionIdentifier`. The permission is kept per bundle
  identifier, so an ad-hoc rebuild does not lose it.

## Logging

One `Logger`: subsystem `io.mysidepulse.app`, category `app`. Device arrival and
departure, stalls and recoveries, rescues, sent pushes, hook and update actions
from the settings window, and the menu-bar item being hidden or shown are logged
at `notice`, the lowest level macOS persists:

```
/usr/bin/log show --predicate 'subsystem == "io.mysidepulse.app"' --last 1h
```

`log` alone is a zsh builtin, hence the full path.

The ntfy topic is never logged.
