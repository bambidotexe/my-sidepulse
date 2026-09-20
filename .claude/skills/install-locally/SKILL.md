---
name: install-locally
description: Use when the owner asks to install MySidepulse on this Mac, to apply a change, to rebuild, to reinstall, to "run the app", to see a change working, or to get the newest build into /Applications. This is one of only two ways a build of this app ever reaches a Mac; the other is publish-release. Also use when about to build the app for any reason, to check first whether a build is even the right action.
---

# Install locally

**This app reaches a Mac in exactly two ways.** This skill is the first: a production build, installed in
`/Applications`, registered with launchd, leaving nothing behind. The second is `publish-release`, which does
the same and puts the disk image on GitHub as well.

```bash
make install
# or directly:
sh scripts/install.sh
```

That is the whole action. It takes a few minutes, most of it Apple's notary service.

## What it does, and why each part is not optional

1. **Checks the version rule** (`scripts/version.sh`): the tree is always one patch ahead of the newest
   release on GitHub. So the copy on this Mac is always newer than anything published, and is never offered
   an update that would replace it with something older.
2. **Builds the real thing** (`scripts/release.sh`) — signed with the Wooflab team's Developer ID under the
   Hardened Runtime, notarized by Apple, stapled, wrapped in the disk image. Not a shortcut, not an ad-hoc
   build. What lands in `/Applications` is byte-for-byte what a stranger would download.
3. **Installs the bundle from inside the disk image**, so what runs is what a release would hand out,
   stapled ticket and all.
4. **Registers the launch agent and the hooks, and hands the live process to launchd** — see below. Skipping
   any of this leaves the strip working today and silently unsupervised after the first crash.
5. **Leaves nothing behind.** No `.app` and no `.dmg` anywhere under the repository when it returns,
   including when it fails. `scripts/no-leftovers.sh` holds that rule.

## The launch-agent sequence, and why it is not just `ditto`

Copying the bundle into `/Applications` is not enough to make MySidepulse a supervised process:

1. **The running copy is stopped with `launchctl bootout`, never a signal.** `killall` is a SIGTERM, which
   is a non-zero exit, which is exactly what `KeepAlive/SuccessfulExit = false` exists to restart: launchd
   would bring the app back from the old bundle while the script was still replacing it. `bootout` unloads
   the job and takes its process with it.
2. **The quiet-launch marker is written before anything can start the app.** A reinstall is not a person
   asking for the Settings window, and the launch below would otherwise open one nobody asked for.
3. **One `open`, and the app hands itself to launchd.** It writes and bootstraps
   `~/Library/LaunchAgents/io.mysidepulse.agent.plist` on any launch that did not come from the agent
   itself, then starts a helper and quits; the helper waits for the pid and `launchctl kickstart`s the job,
   so what runs is what launchd supervises. An app started by `open` is nobody's job: `KeepAlive` only
   supervises the instance launchd spawned itself, and without the hand-over the first crash after an
   install takes the strip and the phone notifications down until the next login. **The hand-over is the
   app's own job, not the script's**, because a copy dragged out of the disk image has no script behind it.
   The script only waits for the job to have a pid, and says so plainly if it never does.
4. **`install-hooks` subscribes Claude Code's events** in `~/.claude/settings.json`, which is how the app
   learns Claude Code is working, has finished, or needs you.
5. **`doctor` is the health check that closes the loop**, run once the process is launchd's job: it reports
   whether the app answers on its control socket, whether auto-start & restart is registered, whether every
   hook is installed and points at the binary that is actually running, and whether the journal is writable.
   A clean `doctor` after install is what confirms the sequence worked, not just that a `.app` exists in
   `/Applications`.

`scripts/install.sh` runs all five steps in order, from the bundle mounted inside the disk image rather than
straight from `build/`, and cleans up on every exit path with a trap.

## The rule about leftovers, which is the point

A signed bundle sitting in `build/` is a complete, working application. Spotlight indexes it, the Finder
opens it, and it runs **beside** the copy in `/Applications` as a second instance with the same bundle
identifier, the same config directory and its own registration attempt for the same launch agent label.

So: **only `/Applications/MySidepulse.app` exists.** A build is a step on the way there, never a thing left
lying about. `scripts/install.sh` and `scripts/publish.sh` both clean up on every exit path. If you ever
build by another route (`make app`, `make dmg`), delete the bundle yourself before you finish.

## Never do these

| Never | Instead |
|---|---|
| Build ad-hoc to "try something" | `scripts/install.sh`. An ad-hoc build is refused without `DEBUG_OK=1`, and **you must ask the owner first** — see below |
| `open` a `.app` from `build/` | Install it. Launching a build bundle is what creates a second instance |
| Leave a built bundle behind "for next time" | There is no next time; the next build makes its own |
| Skip notarizing "because it is only local" | Then the installed copy is not what a release ships, and the release path goes untested until it matters |
| Copy the bundle into `/Applications` without the launch-agent sequence | The strip works until the first crash, then goes dark until the next login with nothing to say why |

## Ad-hoc builds

An ad-hoc build (`SIGN_IDENTITY="-"`, the fallback when no Developer ID certificate is in the keychain)
exists to read something a signed build will not show — a crash, a symbol, a log line. It is **never
installed**, and it gives the app a new code identity on every build, so macOS asks for the Automation
permission again each time. `scripts/make-app.sh` refuses one unless `DEBUG_OK=1`, which is there to make the
decision deliberate, not to be worked around.

If you think an ad-hoc build would help, **ask the owner and say why.** If they agree:

```bash
DEBUG_OK=1 sh scripts/make-app.sh
```

and delete `build/MySidepulse.app` when you are done with it.

## Checking it worked

```bash
codesign -dvv /Applications/MySidepulse.app 2>&1 | grep -E 'Authority=Developer|flags='
/Applications/MySidepulse.app/Contents/MacOS/mysidepulse status
/Applications/MySidepulse.app/Contents/MacOS/mysidepulse doctor
launchctl print "gui/$(id -u)/io.mysidepulse.agent" | grep -E 'pid|state'
```

The authority is `Developer ID Application: Wooflab (85F6AC5QZF)` and the flags include `runtime`. `doctor`
exits 0 with every check `[OK]`; a `[FAIL]` on "auto-start & restart" means the agent is not registered, and
one on a hook means `install-hooks` did not run or a rename left it stale. The version is whatever
`scripts/version.sh`'s rule gave, one patch above the newest GitHub release.

## The one thing the install cannot do for itself

**`/usr/local/bin/mysidepulse`** needs `sudo` to create, since `/usr/local/bin` is usually root-owned. The
script prints the one-liner at the end; call the binary inside the bundle meanwhile, or `mysidepulse` if the
symlink is already there.

## What is at stake if this is skipped

MySidepulse has no armed state and no kernel flag to protect — installing it never risks putting the Mac to
sleep or unlocking anything. What it does risk is going quiet without saying so: the LED strip is the whole
signal that Claude Code is working, has finished, or needs you, and a process that launchd is not supervising
goes dark at the next crash with nothing on screen to explain it. The launch-agent sequence above is what
keeps that from happening silently.

## Taking it off again

There is one way, and it is not the Finder. **Settings › General › Uninstall** removes what MySidepulse put
outside its own bundle, moves the bundle to the Trash and quits. Dragging the bundle to the Trash removes
the app and nothing else, and what is left goes on running against an app that is gone.

The last removals belong to a detached helper that waits for the pid: anything taken away while the app is
still up is written back as it exits. Never suggest removing the pieces by hand instead, and never suggest
`launchctl disable` for the launch agent — it is permanent, and nothing but `launchctl enable` undoes it.
