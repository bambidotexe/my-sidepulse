# Manual test checklist

What only a person at the Mac can verify, with the strip in the slot and the
app installed with `make install`. Each row is one thing to do and what to
expect. `swift test` covers the rules; this file covers what they cannot reach.

## 1. Settings window

| | Do this | Expect |
|---|---|---|
| [ ] | Open Settings (⌘, from the menu-bar item, or open the app again) and click through the eight toolbar items | **General, Strip, Colours, Notifications, Playground, System, Health, Tip**, each a symbol above its title, the shown one drawn as a glass pill, and the window's title following it. The window opens on General at its size and centred, with no jump. On every switch its bottom edge moves, animated, and its top-left corner does not |
| [ ] | Read any page | Every group is a bold title, a card of rows, and under the card a grey hint, then orange warnings, then blue notes, never text inside a card. Nothing is smaller than the body text, there is no radio button and no pop-up menu, and no sentence carries a long dash |
| [ ] | General | The app icon alone at the top, 144 pt. Startup: two switches, a grey hint, one blue note naming the Applications folder and Spotlight. No hint under Updates or under Quit |
| [ ] | General › Updates, press **Check for Updates** | `MySidepulse <version>` on the left of the row; then a spinner and **Checking**; then an orange **No release published yet**. The button stays Check for Updates. Log (`app`): one `update check (asked): no release published` line |
| [ ] | Quit, reopen, and read the log 15 s later | One `update check (automatic): …` line about 10 s after launch, nobody having pressed anything, and no orange mark in Settings when it fails |
| [ ] | Strip | The live strip and a **Showing** row whose sentence matches what the strip does. Switch to **Colour**: a hex and a colour picker appear and the strip goes solid. Switch to **Effect**: six animated tiles in two rows, the shown one tinted and ringed; click another and the strip follows. Back to **Auto** |
| [ ] | Strip, with the strip in the slot | `SidePulse, 8 LEDs` **Available** in green, its mount path as the tooltip, and a brightness slider. Drag it and let go: the strip dims at once and `mysidepulse status` shows the override. Slide back to 255: the override is gone |
| [ ] | Strip, pull the card | Within a few seconds the row is `SidePulse strip` **Missing** in orange, the hint says to plug one in, and the window shrinks. Put it back: the row returns |
| [ ] | Notifications, with the switch on | Server, Topic and Test appear and the window grows. **Reveal Topic and QR Code**: the topic in monospace, the QR code centred, Copy Topic, Copy Link and Hide, and a blue note under the group. Switch pages and back: the topic is hidden again. **Send a Test Notification**: the Test notification row reads **Sent** in green and the phone rings within seconds |
| [ ] | Notifications › **New Topic…** | A sheet asks first. After it, the new topic is revealed and an orange warning says the phone is not subscribed yet. Hide: the warning goes |
| [ ] | Colours, with the strip plugged in: click **Needs you**, then drag its colour well, then type a hex and press Return | Clicking plays the double blink on the strip and in Preview, **Playing** with a spinner and a countdown. Dragging moves the pictures at once and the strip a moment after the drag pauses, each change restarting the 30 s. A malformed hex is put back. **Reset** returns the default and greys out; **Stop** or leaving the page puts the strip back at once. Unplug and replug the power cord: the battery bar uses the chosen band colour |
| [ ] | With the strip plugged in at full brightness and Strip open, run `mysidepulse brightness cycle --steps 3` five times, with nothing showing on the strip | It prints `LEDs: off` first (the strip goes dark, the menu says off, no white), then 33 %, 67 %, 100 %, and off again. At each step LED 1 lights white for 2 s and then goes, and the three steps look clearly different: the first dim, the second about half, the third full. The Strip page's slider follows each step in percent |
| [ ] | Force a colour or an effect, then press the cycle key until it goes off, then once more | Off is dark; the next press brings back the colour or effect at the first step, not Auto. While the colour or effect shows, a press adds no white LED |
| [ ] | With Claude working (the red roll), press the brightness key, and drag the Strip slider | The roll dims or brightens from where it is, every lit LED at once: no restart, no hole in the wave, no LED left lit after its pass. On that pass the wave's two dimmest LEDs peak a little late. The same for the green breath, the amber blink and every effect |
| [ ] | With one session working, let a second finish; then let a session ask a question while another works; then acknowledge each | Done + working: the two green LEDs light at once and the roll keeps rolling on the rest. Needs you + working: the amber pair starts at once over the rolling wave. Acknowledged: the zone goes dark at once, the roll carries on and its LEDs rejoin at the next pass |
| [ ] | With the roll on, cycle the brightness key past 100 % to off and press again within 2 s | The roll comes back where it would have been, its lit LEDs fading in from black. Wait longer than 2 s before the press, or force another mode in between: it starts from its first line |
| [ ] | Leave one animation running for 10 minutes, then press the brightness key | Still no restart: the host's clock has not drifted from the strip's enough to cut the wrong place |
| [ ] | Strip page: drag a strip's brightness slider slowly from the far left to 100 % on a white strip | It moves in 5 % notches, 5 % to 100 %, and every notch changes the strip visibly; the strip brightens evenly to the eye along the whole travel, rather than jumping at the start and barely changing after |
| [ ] | Colours, change a colour, then quit and reopen | The colour is still set, on the strip and on every page's picture; **Reset All Colours** brings back all eleven defaults |
| [ ] | Colours, click **Codex working** | The strip rolls blue (`#0a00ff`), the row is selected and Preview plays the same |
| [ ] | Colours, click **Copilot working**, then **OpenCode working** | The strip rolls in `#0e5cff`, then in `#ff0043`, each row selected in turn and Preview playing the same; each reads apart from Codex's blue and Claude's red on the strip |
| [ ] | Playground, click **Codex working**, **Copilot working**, **OpenCode working**, then **All agents working** | Codex's blue roll, Copilot's, OpenCode's; then on the Pro one pass whose LEDs are Claude's red, Codex's blue, Copilot's blue and OpenCode's red in turn, round again from LED 4, and on the Dot one pass in each of the four colours in turn, the rhythm unchanged, on the strip and on the tile alike. |
| [ ] | Run a Codex turn while Claude works, then let Codex finish, then let Claude ask a question while Codex works | The red wave turns two-coloured at its next pass, without restarting; Codex's finish opens the green zone over the red roll; Claude's question blinks amber over a blue roll. Strip › Showing reads `Claude and Codex are working`, then `Codex has finished, and other work is still running`, then `Claude needs you, and other work is still running` |
| [ ] | With both working, press the brightness key | The wave dims from where it is, and at most one colour shows twice in a row on that pass |
| [ ] | Stop a Codex turn with Esc | The strip goes dark at once (Codex's `Interrupt`), no push |
| [ ] | Ctrl-C a Codex turn while its `sleep 60` runs; then switch MySidepulse's hooks off in Codex's `/hooks` and interrupt another turn | The first goes dark at the `Interrupt` and stays dark when the aborted tool's late `PostToolUse` arrives. The second, with no hook arriving, goes dark within ~35 s, and `/usr/bin/log show --predicate 'subsystem == "io.mysidepulse.app"' --last 5m` says `Codex daemon says thread … has nothing running`, then `turn abandoned: Codex session … the rollout ends on turn_aborted` (with the daemon stopped, `codex app-server daemon stop`, only the second line, reading `— rollout ends on turn_aborted`) |
| [ ] | Start `copilot --allow-all-tools` (or approve `sleep` for the session first: an approval fires no hook, and the session reads amber until the check reads the answer, the row below), ask for `sleep 60`, and press Ctrl+C while it runs | The blue roll goes dark within ~35 s, with no push, and `/usr/bin/log show --predicate 'subsystem == "io.mysidepulse.app"' --last 5m` says `turn abandoned: Copilot session … events.jsonl ends on abort`. `make install` within a minute after it: the strip does not roll for that session after the relaunch, and the journal holds a `MySidepulseVerdict` `turn-abandoned` line for it |
| [ ] | In an interactive `copilot` without `--allow-all-tools`, ask for `sleep 60` and press Ctrl+C at its permission prompt | The amber goes dark within ~15 s, with no push, and the log says `turn abandoned: Copilot session … ends on abort at …, during its wait` |
| [ ] | In an interactive `copilot` without `--allow-all-tools`, ask for `sleep 60` and approve its permission prompt | The amber gives way to Copilot's blue roll within 15 s of the approval, however soon after the prompt appeared, while `sleep` still runs, with no push, and the log says `wait answered: Copilot session … events.jsonl shows the prompt answered at …`. The journal holds a `MySidepulseVerdict` `dialog-answered` line for it |
| [ ] | Make a Copilot turn fail: `COPILOT_OFFLINE=true` with a BYOK model pointed at a port nothing listens on, and one prompt, with nobody at the Mac | Within ~35 s of the last retry the strip blinks amber, the log says `turn failed: Copilot session … events.jsonl ends on session.error`, and the phone's notification is titled **GitHub Copilot** and says `Turn failed`. The next prompt rolls blue again |
| [ ] | Fake a quiet Copilot turn with no file to read: `printf '{"sessionId":"mysidepulse-probe-1","cwd":"/tmp"}' \| COPILOT_HOME=/tmp/mysidepulse-probe /Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent copilot --event userPromptSubmitted` (`/tmp/mysidepulse-probe` holding no `session-state` folder, or the hook drops the fake id as a subagent's); wait 40 s; then clean up with the same line and `--event sessionEnd` | The strip rolls blue at once; within ~35 s the log says `quiet Copilot turn undecidable: session mysidepulse-probe-1` exactly once and the roll stays; the `sessionEnd` clears it |
| [ ] | Under cswap (`CLAUDE_CONFIG_DIR` set to another account's folder), press Esc on a Claude Code turn while a tool runs | Dark within ~35 s, and the log says `turn abandoned: session … reports idle`, with no `quiet turn undecidable … no registry record` |
| [ ] | Press Esc on a Claude Code turn, wait for `turn abandoned` in the log, then `make install` within a minute | After the relaunch the strip does not roll for that session, not even for the first seconds, and the journal holds a `MySidepulseVerdict` line for it |
| [ ] | A Codex TUI session started with MySidepulse's hooks on, then switched off in Codex's `/hooks`: at its prompt after a turn, mid-turn, and after quitting the TUI; then at the prompt with Codex's daemon stopped | Record what the daemon reports in each case (`thread/read`'s `status.type`, `idle`, `active`, `notLoaded` expected) against the log: mid-turn nothing is ended and the roll stays; at the prompt and after quitting, `Codex daemon says thread … has nothing running` within ~36 s; with the daemon stopped, no daemon line at all: a link that resolves to no socket is never asked. `Codex daemon not answering; using the rollout` appears at most once per launch, and only when the link resolves to a socket file that nothing answers on, or the daemon refuses, times out or answers something malformed. A status other than those three appears once as `Codex daemon reports an unknown thread status …` and must be added to `CodexThreadRecord.verdict()` or left to the rollout |
| [ ] | Let Codex finish with nobody at the Mac | The phone's notification is titled **Codex**, says `Finished`, and its click opens `chatgpt.com/codex` |
| [ ] | System, with Codex installed | A **Codex** group after Claude Code: `Codex hooks` **Enabled** in green, a hint saying what the 12 hooks do and that Set Up trusts them in Codex's `config.toml`, a blue note saying Codex runs a hook only once it is trusted. **Remove Hooks** turns it orange **Disabled** with a warning; **Set Up Hooks** brings it back. `mysidepulse doctor` agrees both times (`codex hooks`) |
| [ ] | Codex runs the hooks MySidepulse trusted | After **Set Up Hooks**, Codex's `/hooks` screen lists the 12 MySidepulse hooks as trusted, not new or modified; one prompt in a new Codex session puts `codex` lines in the journal (`agent`), and the strip rolls Codex's blue. `~/.codex/config.toml` keeps everything it held before, with 12 `[hooks.state."…"]` tables added at its end; **Remove Hooks** takes those tables out and nothing else |
| [ ] | Codex, a hook switched off in its `/hooks` screen | `Codex hooks` turns orange **Disabled** on System and Health, with a warning that Codex has not trusted the hooks and never runs them; `mysidepulse doctor`'s `codex hooks` fails naming the event; **Set Up Hooks** trusts it again and the row turns green |
| [ ] | Health, with Codex installed | A `Codex hooks` line right after `Claude Code hooks`, green; **Agent sessions** in Information lists each session with its agent in the tooltip |
| [ ] | Health, remove Codex's hooks with **Remove Hooks** (System), then open Health | The `Codex hooks` line is gone, not orange: nothing of ours is at `~/.codex/hooks.json`. `Claude Code hooks` stays green (something of Claude's is still set up). `mysidepulse doctor`'s `codex hooks` passes with a "not set up" sentence |
| [ ] | Health, remove Claude Code's hooks too (System), with Codex's still removed | `Claude Code hooks` turns red **Disabled**: no agent at all is set up, so the strip follows nothing. Set Codex's hooks back up (System, **Set Up Hooks**): `Claude Code hooks` disappears from Health (the owner may be using Codex instead) and `Codex hooks` turns green. `mysidepulse doctor`'s `hooks installed` follows the same two turns |
| [ ] | System, with GitHub Copilot installed | A **Copilot** group after Codex: `Copilot hooks` **Enabled** in green, a hint naming `~/.copilot/hooks/mysidepulse.json`, a blue note that Copilot picks new hooks up at its next start. **Remove Hooks** turns it orange **Disabled**; **Set Up Hooks** brings it back. `mysidepulse doctor` agrees both times (`copilot hooks`) |
| [ ] | With Copilot's hooks set up, add `"disableAllHooks": true` to `~/.copilot/settings.json` | `Copilot hooks` turns orange **Disabled** with a warning naming that exact line; `mysidepulse doctor`'s `copilot hooks` fails the same way. Remove the line: green again |
| [ ] | System, with OpenCode installed | An **OpenCode** group after Copilot: `OpenCode plugin` **Enabled** in green, a hint naming `~/.config/opencode/plugins/mysidepulse.js`, a blue note that a running server picks it up within a second. **Remove Plugin** turns it orange **Disabled**; **Set Up Plugin** brings it back. `mysidepulse doctor` agrees both times (`opencode plugin`) |
| [ ] | With OpenCode's plugin set up, hand-edit one character in `~/.config/opencode/plugins/mysidepulse.js` | `OpenCode plugin` turns orange **Invalid**; **Set Up Plugin** overwrites it and turns it green again |
| [ ] | Health, with Copilot and OpenCode installed | `Copilot hooks` and `OpenCode plugin` lines, each green, in that order after `Codex hooks`; **Agent sessions** in Information names each of the four agents in its tooltip once a session of each has run |
| [ ] | Health, remove Copilot's hooks and OpenCode's plugin (System, **Remove Hooks** / **Remove Plugin**) | Both lines are gone from Health, not orange, whether or not Copilot and OpenCode are still on this Mac; `mysidepulse doctor`'s `copilot hooks` and `opencode plugin` pass with a "not set up" sentence. Re-run Set Up: both lines return, green |
| [ ] | Health, with the terminal hook never set up (no `~/.zshrc` block) | No `Terminal hook` line at all; set it up (System, **Set Up Terminal Hook**): the line appears, green, at once on Health's next read |
| [ ] | Playground, click **Claude working** | The strip rolls red for up to 30 s, the row reads **Playing** with a spinner and a countdown, the hint under the tiles is that tile's sentence, and **Stop** ends it. Click **Rainbow**, then **Keep It**: the mode is the effect (Strip shows Effect, the menu shows `LEDs: rainbow (effect)`). Back to Auto from Strip |
| [ ] | Playground, click **Battery glance**, then **A colour** | A Battery level slider row appears; moving it and letting go repaints the fill on the strip. Then a colour row with a hex and a picker |
| [ ] | Playground, leave the page mid-preview | The strip is back to its real state at once |
| [ ] | Health | Two tables and nothing else. **Health**: Claude Code hooks, Terminal hook, Notifications permission, SidePulse strip, Open at login and reopen after a crash, each green, then **Check Again**, which greys out with a spinner beside it for about half a second (longer the first time, until the doctor has answered). Hovering a line shows its detail. **Information**: Last hook event, Agent sessions, Terminal commands, Showing, in blue, counting up. No preference, no battery, no mode, nothing about updates |
| [ ] | Health, with something wrong | Pull the strip: `SidePulse strip` **Missing** in orange and a warning under the table to plug one in; the Showing reading goes. Remove the hooks on System: `Claude Code hooks` **Disabled** in red with its stop sign, and the Agent sessions reading goes if no other agent's hooks are set up. Put both back |
| [ ] | System › Welcome, press **Show Onboarding Again** | The wizard opens at page one, in front, with every row re-read. Settings stays open behind it; closing the wizard leaves the app active and Settings where it was |
| [ ] | System, press **Remove Hooks** | `Claude Code hooks` turns red **Disabled** behind a stop sign, an orange warning says to press Set Up Hooks, and the button is Set Up Hooks. Press it: green **Enabled**, the warning is gone, the note stays. `mysidepulse doctor` agrees both times |
| [ ] | General, turn **Show in menu bar** off, close the window, open the app from Applications | The menu-bar icon is gone, the window comes back, the Dock icon is there while it is open and gone once it closes |
| [ ] | **Tip** | The toolbar shows a mug; the first card has no title and carries the app icon beside the sentence; **One-time tip** shows the Ko-fi cup on its red wash, *A cup of coffee*, its grey line, and **Tip €5**, with the hint under the card |
| [ ] | Press **Tip €5** | The Ko-fi page opens in the default browser at `https://ko-fi.com/bambidotexe`. Nothing else moves: the window stays open, the strip does not change, and the `app` log stays silent |
| [ ] | General › **Quit MySidepulse** | The strip goes dark, the app leaves the Dock and the menu bar, and `pgrep MySidepulseApp` finds nothing. Open the app again: it comes back with Settings |
| [ ] | General › **Uninstall** | A grey hint, and under it an orange warning that always stands there: it is the hazard of the Trash, not a state to fix |
| [ ] | Press **Désinstaller MySidepulse**, confirm | The strip goes dark, an alert says MySidepulse is in the Trash, and the app exits |
| [ ] | About 5 s after that uninstall | `/Applications/MySidepulse.app` is in the Trash, `~/Library/LaunchAgents/io.mysidepulse.agent.plist` is gone, `launchctl list \| grep sidepulse` is empty, `launchctl print-disabled gui/$(id -u) \| grep sidepulse` shows nothing (the helper boots out, it never disables), `~/Library/Application Support/MySidepulse` is gone, `defaults read io.mysidepulse.app` fails and `~/Library/Preferences/io.mysidepulse.app.plist` does not exist at all (not an empty one), `~/Library/Caches/io.mysidepulse.app` and `~/Library/HTTPStorages/io.mysidepulse.app` are gone, `~/.claude/settings.json` has no MySidepulse hook and no `settings.json.backup-mysidepulse` beside it, and `.zshrc` has no MySidepulse block |

## 2. Language

The strings are pinned by `LocalizationTests`, but only a person can see whether
a sentence reads well and whether it still fits the row. Run the app in one
language with `-AppleLanguages`, which overrides the system's choice for that
launch only:

```sh
/Applications/MySidepulse.app/Contents/MacOS/MySidepulseApp -AppleLanguages "(fr)"
```

The installed monitor has to be down first, since the app refuses a second copy
of itself.

| | Do this | Expect |
|---|---|---|
| [ ] | Launch with `-AppleLanguages "(fr)"` and open the menu-bar menu | `LED : Auto`, `LED : Éteintes`, `Ouvrir à la connexion`, `Réglages…`, `Quitter MySidepulse`, and the three status lines in French |
| [ ] | Walk the eight pages in French | The toolbar reads **Général, Ruban, Couleurs, Notifications, Bac à sable, Système, Santé, Don**. Every sentence is French, no sentence wraps to a third line, and no row's label runs into its control. French runs about 20 % longer than English, so this is where it shows |
| [ ] | Strip › **Affiche** in French | The three that matter: `Claude travaille`, `Claude a besoin de vous : une question, une permission ou un plan`, `Claude a terminé. S'efface quand vous regardez le terminal`; and with Codex, `Codex travaille`, `Claude et Codex travaillent`, `Codex a terminé. S'efface quand vous regardez le terminal` |
| [ ] | Santé in French, hover each line | Two tables, **Santé** and **Informations**; French labels and words, the doctor's details in French, none with a long dash |
| [ ] | With French running, let a push fire with nobody at the Mac | The phone says `Terminé`, `Vous pose une question`, `Demande une permission`, `Plan prêt` or `Échec du tour`, and the notification still carries its icon (the tag is untranslated) |
| [ ] | With French running, `mysidepulse doctor` and `mysidepulse status` in a terminal | Both still English, every line. This is the rule, not a miss |
| [ ] | Launch with `-AppleLanguages "(de)"` | Everything English. Any language that is not French falls back, never half translated |

## 3. Updating, with a stand-in release

No release is published, so the update is walked against a stand-in: `make dmg`
with a higher `VERSION` in `scripts/make-app.sh` (put it back afterwards), a
`latest.json` naming that image by a `file://` URL, and the **installed** app
started with `MYSIDEPULSE_UPDATE_FEED=file:///…/latest.json` in its environment
(`CLAUDE.md`, *Commands*). The helper's own account is
`~/Library/Application Support/MySidepulse/updates/install.log`.

| | Do this | Expect |
|---|---|---|
| [ ] | Start the app with the stand-in and wait 10 s | macOS asks to allow notifications, once; allowed, a notification **Version … is available** with an **Update** button when hovered. Settings › General shows the blue mark and a blue **Update** without having been asked |
| [ ] | Press the notification's **Update**, then **Update** in Settings | The same **Software Update** window both times, brought forward the second time and not opened twice |
| [ ] | Watch the window | **Downloading: … of …** with the bar moving, **Preparing the update**, then **Ready to install. MySidepulse will quit and reopen.** and **Install and Relaunch** turning blue. Log: `update: downloaded`, `update: staged`, `update: ready to install` |
| [ ] | **Cancel**, and the window's close button, mid-fetch | The window goes, `update: cancelled` in the log, and `updates/` holds no `.dmg` and no `staged` |
| [ ] | A wrong `digest` in `latest.json` | **Update failed: The download is damaged.** and **Try Again** |
| [ ] | An image whose version is not higher | **Update failed: The disk image does not hold a newer version.** |
| [ ] | **Install and Relaunch**, the app having been started by its launch agent | The strip goes dark, and a few seconds later it shows its state again: one window, **The update is installed. MySidepulse is running the new version.** with **Done**, and **no Settings window behind it**; `mysidepulse doctor` still reports the app as launchd's job, `install.log` has `started through launchd` and ends with `version … is running`, `updates/previous` is gone |
| [ ] | The same, the app having been opened by hand, with the agent installed | `install.log` still has `started through launchd`: the job is how it comes back whenever there is one, so nothing has to change hands. With the agent removed first, `open` instead, and the copy that starts bootstraps the job and hands over; the update still ends installed |
| [ ] | Quit the new version within two seconds of its relaunch (Settings › General › **Quit MySidepulse**) | It stays quit and stays updated: `install.log` still ends with `version … is running`, and reopening it shows the new version |
| [ ] | An image whose `MySidepulseApp` has been replaced by `exit 1` before signing | The previous version comes back by itself and the strip lights again, its window says **Version … was not installed. The new version did not start, so the previous one was put back.** with **Close**, Settings › General carries the same reason as an orange mark once opened, and `install.log` has `did not start; putting the previous one back` |
| [ ] | The app run from a read-only folder | After the fetch the window offers **Open Disk Image** and the sentence about dragging MySidepulse to Applications |

## 4. The onboarding wizard

None of this has an automated test. Start from a Mac where the wizard has not
been walked: `mysidepulse` quit, `onboardingDone` removed from
`~/Library/Application Support/MySidepulse/config.json`, then open the app. Use
Settings > System > **Show Onboarding Again** for the rest.

| | Do this | Expect |
|---|---|---|
| [ ] | Open the app with `onboardingDone` absent | The wizard opens by itself, in front, 540 pt wide, titled MySidepulse, with a close button and no minimise and no resize handle. **No Dock icon appears**, and no Settings window opens |
| [ ] | `make install` over that same Mac, with the flag set | No wizard, and no Settings window. The same for a launch the update helper makes |
| [ ] | Page one | The app icon at the top, the headline with **Claude** in the app's working red, two grey lines under it, three red capsules reading Working, Finished, Needs you, and **Continue** at the bottom right, pressed by Return |
| [ ] | Continue to **Setting up** | The window grows downward: the title bar does not move. Five rows, separated by hairlines, `Claude Code hooks` carrying an orange triangle. The button reads **Skip** while the hooks are not set up and **Continue** once they are, and nothing else on the page moves when it changes |
| [ ] | Press **Set Up…** on `Claude Code hooks` | The button greys out with a small spinner beside it, then the row reads **Set up** with a **Remove** button. Only that row changed: the header, the intro and the four other rows did not move or flicker. `mysidepulse doctor` agrees |
| [ ] | Press **Turn On** on `Startup` | The row reads **Enabled**. `launchctl list \| grep sidepulse` finds the job |
| [ ] | Press **Allow…** on `Notifications` | **Only** the macOS permission dialog. System Settings does **not** open beside it. Allow it: the row reads **Granted** |
| [ ] | Press **Allow…** again after having refused once | Nothing visible happens, and System Settings still does not open. That is the cost of the rule: only a click asks, and macOS has already recorded the refusal |
| [ ] | From the dialog, go to System Settings, grant the permission there, and leave the pane open | The row ticks over on its own within about 2 s, with the wizard still behind the pane. Close the System Settings window: the wizard comes back in front of what it was in front of |
| [ ] | Grant it, then leave System Settings open and click another app instead | The wizard does not move |
| [ ] | Press **Turn On** on `Phone alerts` | Settings opens on **Notifications**, with the topic revealed and its QR code, in front of the wizard. The wizard stays where it is. Close Settings: the app stays active and the wizard is still there |
| [ ] | Click another app's window while the wizard is up | It goes behind and **stays** there. Switch to another Space and back: still in front of exactly what it was |
| [ ] | `open -b io.mysidepulse.app` with the wizard up | The wizard comes forward, not Settings. With Settings also open, activating the app brings Settings forward, not the wizard |
| [ ] | Continue to **All set**, then close the window with its close button instead of **Finish** | `onboardingDone` is still absent from `config.json`, and the next launch opens the wizard again |
| [ ] | Walk it again and press **Finish** | The window closes, the front goes back to whoever had it and keystrokes reach that app, `config.json` has `"onboardingDone": true`, and the next launch opens nothing |
| [ ] | Reach the last page having granted nothing, finish, quit, and launch again twice | **No permission prompt appears by itself**, at launch or while the window sits open. Every prompt in the whole walk followed a click of yours |
| [ ] | Run it in French (`-AppleLanguages '(fr)'`) | Every sentence is French, **Claude** is still the accented word, and each row's title reads exactly as the Settings window's own row for the same thing (`Hooks Claude Code`, `Hook de terminal`, `Démarrage`). No row's title or explanation is cut off |

## 5. Terminal jobs

In a new Terminal tab with the hook set up, and no agent working, so a running
job's violet shows. Watch the log:
`/usr/bin/log stream --predicate 'subsystem == "io.mysidepulse.app"'`.

| | Do this | Expect |
|---|---|---|
| [ ] | `ps -o pid,pgid,tpgid,comm -p $$` at the prompt, then the same for that shell from another tab while `sleep 60` runs in it | At the prompt `pgid` and `tpgid` are equal; while `sleep` runs `tpgid` is the `sleep`'s group, in Terminal and in every other terminal in use |
| [ ] | `exec zsh`, then type nothing for 20 s; the same with `source ~/.zshrc` | The strip never turns violet, and `mysidepulse status` lists no running job |
| [ ] | Ask Codex (or OpenCode) to run `sleep 30` | The strip shows the agent working and never violet; `mysidepulse status` lists no job, and the log has `job ignored: shell <pid> runs under Codex`. A `sleep 30` typed in Terminal meanwhile still turns violet |
| [ ] | `sleep 300`, then close the tab | The violet goes at once |
| [ ] | `sudo -v`, then `sudo sleep 20`; then `sudo -i` and `exit` | `sudo sleep 20` shows, labelled `sleep` in `mysidepulse status`; `sudo -i` never shows |
| [ ] | A lost end: `sleep 20; _mysidepulse_job=` (the assignment empties the job the hook would end) | Within about 20 s of the prompt coming back the violet goes, with no green, and the log has `job zsh-<pid> ended without a hook (shell at its prompt)` |
| [ ] | `sleep 7300` | Still violet after 2 h |
| [ ] | `sleep 120`; while it runs, quit MySidepulse from its menu and open it again | The violet comes back with the app and stays until `sleep` ends; then the green |
| [ ] | `sleep 60`; quit the app, close the tab, open the app again | Nothing violet at any point after the relaunch, and the log has `job zsh-<pid> ended without a hook (shell gone)` |
| [ ] | `mysidepulse run -- sh -c 'sleep 2; exit 3'`, then `mysidepulse run -- true`, ten times each | Amber after every failing one and green after every passing one, never nothing: the wrapper's end line always lands before its exit |
| [ ] | `sh -c 'sleep 8; exit 1'`, focus another app until the amber shows, focus the terminal to see it, then quit and reopen the app | The amber does not come back |
