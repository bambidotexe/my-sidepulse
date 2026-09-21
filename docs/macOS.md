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
Claude process, its host app and its terminal tab, and how the app reads a
Claude process's `CLAUDE_CONFIG_DIR`.

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
removed from the same Hooks rows),
`<config>/sessions/*.json` and the session transcript (read only).

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
