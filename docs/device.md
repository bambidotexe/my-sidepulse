# Device: the LED strip and the host protocol

What the host knows about the SidePulse strip and exactly what it sends to it.
Everything here is what `MySidepulseCore/LedProgram.swift`,
`MySidepulseCore/LedEffects.swift` and `MySidepulsePlatform/LedWriter.swift`
implement; the exact texts are pinned by `ProgramTests`.

The strip is a closed device. The host has no firmware source, no USB or serial
channel and no read-back: the whole protocol is *files on a mounted volume*.

## What the host sees

The strip sits in the SD-card slot and mounts as an ordinary removable volume.
The host uses two files at the volume root:

| File | Direction | Purpose |
|---|---|---|
| `LEDS.LED` | host → device | The LED program, as UTF-8 text. Rewriting it replaces what the strip shows. |
| `keepalive` | host → device | Touched once a minute so macOS keeps the card reader powered. Content is irrelevant. |

The device's own boot program (`INIT.LED`) is never read or written by the
host.

**Recognition.** A mounted volume is a strip if and only if `LEDS.LED` exists
at its root (`LedDevice.probe`). There is no vendor/product ID check and no
content check.

**LED count** comes from the volume name, case-insensitively
(`LedProgram.ledCount(volumeName:)`):

| Volume name starts with | LEDs |
|---|---|
| `sidepulsedot` | 2 |
| `sidepulsepro` | 8 |
| anything else | 8 (`K.defaultLedCount`) |

**Identity** is the mount point's `(st_dev, st_ino)` (`DeviceKey`), not its
path. A replugged strip gets the same path back with a fresh identity, which is
what forces a repaint: the device boots into its own program, so the host must
not assume its last write is still showing.

LEDs are addressed `0 … n−1`, left to right. Colours are `#rrggbb`, lowercase,
sent exactly as the palette holds them (`LedPalette`: K's defaults, each slot
replaced by the Colours page's override in `config.json`) — the host does no
channel reordering and no gamma. A colour is a true colour: dimming is the
`brightness` line's job (below), never a darker hex. An override that is not `#`
and six hex digits is ignored and the slot keeps its default, since one
malformed colour makes the whole program unreadable.

## Program text

A program is a few lines of text joined by `\n`, with no trailing newline. The
host emits only these line forms:

| Form | Meaning |
|---|---|
| `brightness N` | First line only. Global brightness, `1…254`. Omitted at full brightness (255) and never sent with `off`. |
| `off` | Whole strip dark. |
| `off <dur>` | Whole strip dark for `<dur>`. |
| `off <dur> cosine` | Fade the whole strip to dark over `<dur>` on a cosine curve. |
| `#rrggbb` | Whole strip solid colour. |
| `#rrggbb <dur> pulse` | One whole-strip pulse: dark → colour → dark over `<dur>`. |
| `i:#rrggbb <dur>` | LED `i` crossfades to the colour over `<dur>` and holds it. |
| `i:#rrggbb <dur> pulse <delay>ms` | LED `i` pulses once over `<dur>`, starting `<delay>` into the line. |
| `repeat` | Last line. Loop the program. |

Per-LED segments on one line are separated by `; ` (or `;` in the battery bar
and the rotating effects, where bytes are scarce) and run concurrently. Lines
run one after another; a line lasts until its longest segment ends.

Durations are written `<n>ms`, `<n>s` or `<n.n>s`. `LedEffects.duration(ms:)`
picks the shorter spelling (`0.2s`, not `200ms`), because of the size ceiling
below.

**Limits the host stays inside:** 20 lines and 512 bytes per program
(`testProgramsRespectDeviceLimits`). The 8-LED rainbow is the tightest at 501
bytes with a brightness line; that ceiling is why it has four frames and steps
two hues at a time.

A program the device cannot parse is not shown at all: the strip blinks red six
times instead. One malformed colour is enough, which is why
`testEveryColourConstantIsAValidProgramColour` exists.

**Device behaviour the programs depend on** — each learned on the hardware, and
each the reason a program has the shape it has:

- A whole-strip `pulse` returns to black. A per-LED `pulse` returns to that
  LED's *pre-pulse* value. So every program that mixes per-LED animations opens
  with a baseline line assigning every LED; without it the previous program's
  colours show through the gaps.
- A per-LED assignment holds through later lines that do not reassign that LED.
  The split display's steady green zone relies on this.
- Two pulses for the same LED on one line do not stack — the strip renders one.
  The split display's amber double blink is therefore built across two lines.

## Programs by display state

`LedProgram.program(for:power:ledCount:brightness:palette:)` maps each
`DisplayState` to one text. Shown for the 8-LED strip with the default palette;
each colour below is a palette slot (`working`, `needsYou`, `done`,
`jobRunning`, `batteryCritical`, `batteryLow`, `batteryMid`, `batteryHigh`).

**`off`** — also the idle strip, when nothing is happening:

```
off
```

**`working`** — a red wave rolling left to right (`K.claudeWorking`). Each LED
pulses for 760 ms, staggered by 95 ms (260 ms on the 2-LED strip):

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; 1:#ff374a 760ms pulse 95ms; … 7:#ff374a 760ms pulse 665ms
repeat
```

**`jobRunning`** — the same roll in `K.jobRunning` (`#ba5eff`).

**`waiting`, `jobFailed`** — amber double blink, 1.5 s cycle, identical on any
LED count:

```
off
#ff7000 200ms pulse
off 70ms
#ff7000 200ms pulse
off 1030ms
repeat
```

**`done`, `jobSucceeded`** — one slow green breath every 4.5 s:

```
off
#00ff37 4.5s pulse
repeat
```

**`batteryCritical`** — a slower red breath:

```
off
#ff0000 6.0s pulse
repeat
```

**`batteryGlance`** — a fill bar, one LED per eighth of charge, the frontier LED
dimmed by the remainder (`BatteryRules.fill`, linear per-channel scaling). Bar
colour by charge: ≤ 15 % `#ff0000`, ≤ 50 % `#ff7000`, else `#00ff37`; unlit
LEDs `#000000`. At 30 % on 8 LEDs, two LEDs are full and the third is at 40 %:

```
0:#ff7000 360ms;1:#ff7000 360ms;2:#652c00 360ms;3:#000000 360ms;…;7:#000000 360ms
```

**`manualColor(hex)`** — the hex alone, e.g. `#112233`.

**`split(alert:work:)`** — an alert and running work at once. The alert takes
the leftmost LEDs (`K.alertZoneLedsNeedsYou` = 3 for waiting / job failed,
`K.alertZoneLedsFinished` = 2 for done / job succeeded, always leaving at least
one LED to the work); the roll keeps the rest.

Amber zone over the working roll — baseline, first blink, then the second blink
riding the roll's line 70 ms in. The cycle is 1.5 s, the same rhythm as the
full-strip blink (`testNeedsYouRhythmMatchesTheSplit` derives it):

```
0:#000000 160ms; 1:#000000 160ms; … 7:#000000 160ms
0:#ff7000 200ms pulse 0ms; 1:#ff7000 200ms pulse 0ms; 2:#ff7000 200ms pulse 0ms
0:#ff7000 200ms pulse 70ms; 1:#ff7000 200ms pulse 70ms; 2:#ff7000 200ms pulse 70ms; 3:#ff374a 760ms pulse 0ms; 4:#ff374a 760ms pulse 95ms; … 7:#ff374a 760ms pulse 380ms
repeat
```

Green zone over the working roll — the baseline sets the zone green once and it
holds steady; only the roll animates:

```
0:#00ff37 160ms; 1:#00ff37 160ms; 2:#000000 160ms; … 7:#000000 160ms
2:#ff374a 760ms pulse 0ms; 3:#ff374a 760ms pulse 95ms; … 7:#ff374a 760ms pulse 475ms
repeat
```

When the roll has two LEDs or fewer it uses the 260 ms stagger.

**`effect(name)`** — the six `LedEffects.names`:

| Effect | Shape |
|---|---|
| `rainbow` | 8-hue wheel, 4 frames of `i:#hex 0.2s`, advancing two hues per frame; no dark line, so the strip never goes out. |
| `aurora`, `ocean`, `lava` | 3-hue wheels, 3 frames, 0.9 s / 0.8 s / 0.8 s per frame. |
| `ember` | `off` / `#ff5200 3.2s pulse` / `repeat`. |
| `sparkle` | `off 160ms cosine`, then `i:#d1d1ff 360ms pulse <slot>ms` with slots spread over a 2880 ms cycle in the order `(i·5) mod n`. |

In a rotating effect, LED `i` in frame `f` shows wheel entry
`(i·spacing + advance·f) mod wheel.count`, with
`spacing = max(1, wheel.count / ledCount)` (`LedEffects.wheelIndex`). The
settings window's preview uses the same function.

An effect name outside the list cannot reach the device: `LedMode.parse`
rejects it, and the program builder falls back to `off`.

## Brightness

Per volume name, `1…255`, stored in `config.json` under `brightness` keyed by
the lower-cased volume name; absent means 255. It is sent as the `brightness N`
first line. `off` is never prefixed. The Strip page's slider sets it, and so does
`mysidepulse brightness cycle` (functional.md §11), which writes the same value
for every plugged-in strip. Both set a perceived percent and send
`255 · fraction^γ` (`BrightnessCurve`, `K.brightnessGamma`): the value is linear
in the LEDs' power, the eye is not.

**The white LED** of `brightness cycle`, on a strip that would be dark, is one
line with its brightness line, the baseline shape the split opens with:
`0:#ba5eff 160ms;1:#000000 160ms;…;7:#000000 160ms`. `#ba5eff` is what reads as
white on the strip; `#ffffff` reads yellow there.
(`LedProgram.brightnessPreview`). It is never drawn over another program.

## Writing

`LedWriter` owns every write.

- **How:** `open(LEDS.LED, O_WRONLY | O_TRUNC)`, one `write(2)` of the UTF-8
  bytes, `close`. No `O_CREAT` (the file must already exist, as the probe
  proved), no temp file and rename, no `fsync`.
- **Where:** a single serial io queue shared by all devices. Bookkeeping lives
  on a second serial queue. Nothing in this path runs on the main queue.
- **Dedupe:** the last program successfully written to each `DeviceKey` is
  remembered; an identical program is not written again. A device's entry is
  cleared when it appears or disappears.
- **Coalescing:** at most one pending program per device. A newer program
  replaces a queued one, so the strip always gets the latest decision.
- **Watchdog:** a write that has not returned after `K.writeWatchdogSeconds`
  (2 s) marks the device *stalled*. A stalled device keeps recording the
  program it should show but starts no new write, because the parked write
  still owns the io queue. When that write returns — successfully or not — the
  stall clears and the pending program is painted. A failed write leaves the
  dedupe entry alone, so the next paint retries it.
- A write that never returns blocks the io queue until the volume goes away.
- **Quitting** is the one write that does not use that queue. `LedWriter.blackout`
  writes `off` to every strip directly, one background write each, and waits for
  them all at once for at most `K.quitBlackoutSeconds` (1.5 s) before the process
  exits. The queued path would return before the strip was dark, and a strip that
  has stopped answering must not be able to hold a quit open; strips that are
  healthy still go dark while one is parked.

Stalls and recoveries are logged (`device stalled, writes suspended` /
`device recovered, writes resumed`) and surfaced as `STALLED` in
`mysidepulse status`, `mysidepulse doctor` and the menu.

## Keepalive

macOS powers the built-in card reader down after a few idle minutes, and the
LEDs go with it. `Keepalive` runs `/usr/bin/touch <mount>/keepalive` for every
known device, first after 1 s and then every `K.keepaliveSeconds` (60 s).

It is a subprocess on purpose: a filesystem call on a wedged volume blocks
uninterruptibly, and a child process can hang without hanging the app. A touch
still running after `K.keepaliveTouchTimeoutSeconds` (5 s) gets `SIGTERM`, and
`SIGKILL` 5 s after that. At most `K.keepaliveMaxOutstandingTouches` (3) touches
may be outstanding per device; beyond that the device is skipped until one
returns. The accounting is keyed by `DeviceKey`, so a replug starts clean.
