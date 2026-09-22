# Manual test checklist

What only a person at the Mac can verify, with the strip in the slot and the
app installed with `make install`. Each row is one thing to do and what to
expect. `swift test` covers the rules; this file covers what they cannot reach.

## 1. Settings window

| | Do this | Expect |
|---|---|---|
| [ ] | Open Settings (⌘, from the menu-bar item, or open the app again) and click through the seven toolbar items | **General, Strip, Notifications, Playground, System, Health, Tip**, each a symbol above its title, the shown one drawn as a glass pill, and the window's title following it. The window opens on General at its size and centred, with no jump. On every switch its bottom edge moves, animated, and its top-left corner does not |
| [ ] | Read any page | Every group is a bold title, a card of rows, and under the card a grey hint, then orange warnings, then blue notes, never text inside a card. Nothing is smaller than the body text, there is no radio button and no pop-up menu, and no sentence carries a long dash |
| [ ] | General | The app icon alone at the top, 144 pt. Startup: two switches, a grey hint, one blue note naming the Applications folder and Spotlight. No hint under Updates or under Quit |
| [ ] | General › Updates, press **Check for Updates** | `MySidepulse <version>` on the left of the row; then a spinner and **Checking**; then an orange **No release published yet**. The button stays Check for Updates. Log (`app`): one `update check (asked): no release published` line |
| [ ] | Quit, reopen, and read the log 15 s later | One `update check (automatic): …` line about 10 s after launch, nobody having pressed anything, and no orange mark in Settings when it fails |
| [ ] | Strip | The live strip and a **Showing** row whose sentence matches what the strip does. Switch to **Colour**: a hex and a colour picker appear and the strip goes solid. Switch to **Effect**: six animated tiles in two rows, the shown one tinted and ringed; click another and the strip follows. Back to **Auto** |
| [ ] | Strip, with the strip in the slot | `SidePulse, 8 LEDs` **Available** in green, its mount path as the tooltip, and a brightness slider. Drag it and let go: the strip dims at once and `mysidepulse status` shows the override. Slide back to 255: the override is gone |
| [ ] | Strip, pull the card | Within a few seconds the row is `SidePulse strip` **Missing** in orange, the hint says to plug one in, and the window shrinks. Put it back: the row returns |
| [ ] | Notifications, with the switch on | Server, Topic and Test appear and the window grows. **Reveal Topic and QR Code**: the topic in monospace, the QR code centred, Copy Topic, Copy Link and Hide, and a blue note under the group. Switch pages and back: the topic is hidden again. **Send a Test Notification**: the Test notification row reads **Sent** in green and the phone rings within seconds |
| [ ] | Notifications › **New Topic…** | A sheet asks first. After it, the new topic is revealed and an orange warning says the phone is not subscribed yet. Hide: the warning goes |
| [ ] | Playground, click **Claude working** | The strip rolls red for up to 30 s, the row reads **Playing** with a spinner and a countdown, the hint under the tiles is that tile's sentence, and **Stop** ends it. Click **Rainbow**, then **Keep It**: the mode is the effect (Strip shows Effect, the menu shows `LEDs: rainbow (effect)`). Back to Auto from Strip |
| [ ] | Playground, click **Battery glance**, then **A colour** | A Battery level slider row appears; moving it and letting go repaints the fill on the strip. Then a colour row with a hex and a picker |
| [ ] | Playground, leave the page mid-preview | The strip is back to its real state at once |
| [ ] | Health | Two tables and nothing else. **Health**: Claude Code hooks, Terminal hook, Notifications permission, SidePulse strip, Open at login and reopen after a crash, each green, then **Check Again**, which greys out with a spinner beside it for about half a second (longer the first time, until the doctor has answered). Hovering a line shows its detail. **Information**: Last hook event, Claude sessions, Terminal commands, Showing, in blue, counting up. No preference, no battery, no mode, nothing about updates |
| [ ] | Health, with something wrong | Pull the strip: `SidePulse strip` **Missing** in orange and a warning under the table to plug one in; the Showing reading goes. Remove the hooks on System: `Claude Code hooks` **Disabled** in red with its stop sign, and the Claude sessions reading goes. Put both back |
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
| [ ] | Walk the seven pages in French | The toolbar reads **Général, Ruban, Notifications, Bac à sable, Système, Santé, Don**. Every sentence is French, no sentence wraps to a third line, and no row's label runs into its control. French runs about 20 % longer than English, so this is where it shows |
| [ ] | Strip › **Affiche** in French | The three that matter: `Claude travaille`, `Claude a besoin de vous : une question, une permission ou un plan`, `Claude a terminé. S'efface quand vous regardez le terminal` |
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
