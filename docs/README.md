# MySidepulse documentation

These documents describe the system as it is. They are written from the code,
in the present tense; history lives only in `pitfalls.md`.

## How to start

1. Read `CLAUDE.md` at the root of the repository, whole. It is the operating
   manual: what the project is, who decides what, the workflow for changing
   behaviour, where each kind of change lands, the commands, the rules.
2. Read the section of `functional.md` that governs what you are about to
   touch. For the strip's text, read `device.md`; for anything that leans on
   macOS, `macOS.md`; and the matching section of `pitfalls.md` before you
   design anything.
3. `swift build && swift test` — both test bundles print a summary line; read
   both.

## The sync rule

**The code and `functional.md` describe the same app at every commit.** A change
to behaviour replaces the rule it changes, in the same commit; an outdated rule
is never kept, annotated or crossed out. A number changes in its section and in
`functional.md` §13. When a request contradicts a written rule, the rule is
quoted back to the owner and the question is whether it is overruled — the
request wins only after the owner has said so.

## The documents

| Document | Read it for |
|---|---|
| [functional.md](functional.md) | What the app does: the strip's states and precedence, how Claude Code's and Codex's status is read, acknowledgement, phone notifications, terminal jobs, battery, menu, settings, CLI, language, permissions, and every delay and threshold. **Authoritative for behaviour and constants** — update it when behaviour changes. |
| [architecture.md](architecture.md) | How it is built: targets, the status / device / notification layers, the engine's single `sync()` path, who watches what, threading, the control socket, persistence, the hook path, build and signing. |
| [device.md](device.md) | The strip as the host sees it: recognition, LED count, the program text format, the exact program for every display state, brightness, write mechanics, keepalive. |
| [macOS.md](macOS.md) | The operating-system boundary: DiskArbitration and the eject guard, sleep and wake, battery, presence and focus inputs, process inspection, permissions, launchd, the bundle and signing, logging. |
| [pitfalls.md](pitfalls.md) | Traps already fallen into — card slot, LED protocol, Claude Code and Codex detection, acknowledgement, ntfy, launchd, hooks — and the open issues. Read before changing any of those areas. |
| [manual-test-checklist.md](manual-test-checklist.md) | What only a person at the Mac can verify, with the strip in the slot: the settings window, and how the French reads in it. One line per thing to do and what to expect. |

Where the facts come from:

- Timings and colours: `Sources/MySidepulseCore/Constants.swift`.
- Program text: `LedProgram.swift`, `LedEffects.swift`, pinned by `ProgramTests`.
- Session rules: `SessionStore.swift`, pinned by `SessionStoreTests`,
  `GoldenReplayTests`, `NotifyTests`, `SettleTests`, `TimerTests`.
- Notification copy: `Alert.swift` (`AlertCopy`), pinned by `NotifyTests`.
- The zsh snippet: `ShellInit.swift`, run in a real zsh by `ShellInitTests`.
- Every user-facing string, in English and French: `Strings*.swift`, with the
  language rule in `Localization.swift`, pinned by `LocalizationTests`.

Four texts leave the program with no compiler to check them — the LED program
text, the notification copy, the zsh snippet, and the string tables. Change them
only together with their exact-text tests, and verify LED changes on the strip.

The ntfy topic is a secret. It appears nowhere in this repository and must not
be pasted into a document, a commit message or an issue.

`_coverage.md` and `_audit.md` are the working files of the 2026-09-19 audit:
who read what, what was deleted and why.

## The shared documents

`shared/` is a byte-for-byte copy of `~/Projects/macos-app-template/docs/shared/`: the workflow every app
of the family follows, the conventions, the platform facts, the traps and the walks they all share. **It is
never edited here**; a change goes in the template and `sh ~/Projects/macos-app-template/scripts/sync-shared-docs.sh`
replicates it. What is this app's own stays in the documents above.
