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
strip's brightness (below), never a darker hex. An override that is not `#`
and six hex digits is ignored and the slot keeps its default, since one
malformed colour makes the whole program unreadable.

## Program text

A program is a few lines of text joined by `\n`, with no trailing newline. The
host emits only these line forms:

| Form | Meaning |
|---|---|
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
(`testProgramsRespectDeviceLimits`). The 8-LED rainbow is the tightest at 486
bytes, then the two-agent roll's two passes at 496; that ceiling is why the
rainbow has four frames and steps two hues at a time, why a shared roll
alternates by LED under a zone, and why the roll of three or four agents is
one pass that alternates by LED on the whole strip too (three passes would be
741 bytes). No program carries a `brightness N` line (see *Brightness*).

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
each colour below is a palette slot (`working`, `codexWorking`,
`copilotWorking`, `opencodeWorking`, `needsYou`, `done`, `jobRunning`,
`batteryCritical`, `batteryLow`, `batteryMid`, `batteryHigh`).

**`off`** — also the idle strip, when nothing is happening:

```
off
```

**`working(claude)`** — a red wave rolling left to right (`K.claudeWorking`).
Each LED pulses for 760 ms, staggered by 95 ms (260 ms on the 2-LED strip):

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; 1:#ff374a 760ms pulse 95ms; … 7:#ff374a 760ms pulse 665ms
repeat
```

**`working(codex)`**, **`working(copilot)`**, **`working(opencode)`** — the
same roll in `K.codexWorking` (`#0a00ff`), `K.copilotWorking` (`#0e5cff`) and
`K.opencodeWorking` (`#ff0043`).

**Two agents at work**, `working(claude, codex)` for instance: one pass per
colour, in the agents' order, each opening with the same fade, so the wave
keeps its rhythm and changes colour at every pass. 496 bytes on 8 LEDs, the
largest program the host writes after the rainbow; the loop is 3170 ms (2360
on the Dot):

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; … 7:#ff374a 760ms pulse 665ms
off 160ms cosine
0:#0a00ff 760ms pulse 0ms; … 7:#0a00ff 760ms pulse 665ms
repeat
```

**Three or four agents at work**: one pass, LED *i* in the colour of agent
*i* mod *n*, in the agents' order (`LedProgram.rollPasses`). It is the single
roll's shape and size, 251 bytes, and its loop, 1585 ms (1180 on the Dot);
three passes would be 741 bytes. `working(claude, codex, copilot)`:

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; 1:#0a00ff 760ms pulse 95ms; 2:#0e5cff 760ms pulse 190ms; 3:#ff374a 760ms pulse 285ms; 4:#0a00ff 760ms pulse 380ms; 5:#0e5cff 760ms pulse 475ms; 6:#ff374a 760ms pulse 570ms; 7:#0a00ff 760ms pulse 665ms
repeat
```

`working(claude, codex, copilot, opencode)`:

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; 1:#0a00ff 760ms pulse 95ms; 2:#0e5cff 760ms pulse 190ms; 3:#ff0043 760ms pulse 285ms; 4:#ff374a 760ms pulse 380ms; 5:#0a00ff 760ms pulse 475ms; 6:#0e5cff 760ms pulse 570ms; 7:#ff0043 760ms pulse 665ms
repeat
```

On the Dot's two LEDs either shows the first two agents' colours only:

```
off 160ms cosine
0:#ff374a 760ms pulse 0ms; 1:#0a00ff 760ms pulse 260ms
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

A roll several agents share cannot alternate by pass under a zone: two passes
of blink lines and roll lines are over 700 bytes on 8 LEDs. It alternates by
LED instead, whatever the number of agents: the first agent's colour on the
roll's first LED, the next agent's on the next, round again after the last;
on the Dot, where the roll is one LED, only the first agent's shows. Claude
and Codex:

```
0:#000000 160ms; 1:#000000 160ms; … 7:#000000 160ms
0:#ff7000 200ms pulse 0ms; 1:#ff7000 200ms pulse 0ms; 2:#ff7000 200ms pulse 0ms
0:#ff7000 200ms pulse 70ms; 1:#ff7000 200ms pulse 70ms; 2:#ff7000 200ms pulse 70ms; 3:#ff374a 760ms pulse 0ms; 4:#0a00ff 760ms pulse 95ms; 5:#ff374a 760ms pulse 190ms; 6:#0a00ff 760ms pulse 285ms; 7:#ff374a 760ms pulse 380ms
repeat
```

All four agents:

```
0:#000000 160ms; 1:#000000 160ms; … 7:#000000 160ms
0:#ff7000 200ms pulse 0ms; 1:#ff7000 200ms pulse 0ms; 2:#ff7000 200ms pulse 0ms
0:#ff7000 200ms pulse 70ms; 1:#ff7000 200ms pulse 70ms; 2:#ff7000 200ms pulse 70ms; 3:#ff374a 760ms pulse 0ms; 4:#0a00ff 760ms pulse 95ms; 5:#0e5cff 760ms pulse 190ms; 6:#ff0043 760ms pulse 285ms; 7:#ff374a 760ms pulse 380ms
repeat
```

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
the lower-cased volume name; absent means 255. **It is never sent as a
`brightness N` line.** Every colour of every program is scaled by it on the way
out, each channel multiplied by `brightness / 255` and rounded
(`LedProgram.scaled`), which is the arithmetic the strip's own line applies to
what it draws: the same values reach the LEDs, and the palette keeps its true
colours. The line is not used because, on the owner's strip, a program that
carried one showed its lit LEDs at full scale for a frame at the parse (the
strip renders before the line takes effect), which a colour already at the
brightness cannot do. The Strip page's slider sets it, and so does
`mysidepulse brightness cycle` (functional.md §11), which writes the same value
for every plugged-in strip. Both set a perceived percent and send
`255 · fraction^γ` (`BrightnessCurve`, `K.brightnessGamma`): the value is linear
in the LEDs' power, the eye is not.

**The white LED** of `brightness cycle`, on a strip that would be dark, is one
line, the baseline shape the split opens with, scaled like everything else:
`0:#ba5eff 160ms;1:#000000 160ms;…;7:#000000 160ms`. `#ba5eff` is what reads as
white on the strip; `#ffffff` reads yellow there.
(`LedProgram.brightnessPreview`). It is never drawn over another program.

## Carrying an animation on

A program starts from its first line and the strip keeps no phase across
parses, so every rewrite restarts what is playing. When the animation carries
on through a change (functional.md §3 *Carrying an animation on*), the host
writes a one-shot **tail** at once, then the loop when the tail ends
(`LedContinuation`, `Engine.paint`). The tail is built from the text the host
wrote, read back into lines and segments, cut at the phase: the milliseconds
since that program was written, modulo the loop's length, with a line that has
no timing counted as one frame (`LedContinuation.frameMs`, 17 ms).

**Firmware facts the tail rests on**, each verified on the owner's strip, which
runs firmware older than the vendor's document:

- `repeat N` is refused: a parse error, six red blinks. A program cannot play
  a prefix once and then loop, which is why the tail is a write of its own.
- `none` easing is accepted.
- A whole-strip `#hex D pulse` looks identical to `#hex D/2 cosine` followed
  by `off D/2 cosine`: the pulse is two cosine halves, so it can be cut anywhere.
- Not verified, and therefore not used: a per-LED `cosine`, the other easings,
  `roll`. A tail is assembled only from the shapes above and the per-LED
  crossfade and pulse the programs already use.
- A program carrying a `brightness N` line shows its lit LEDs at full scale for
  a frame at the parse, and a segment starts from the LED's visible value at
  the brightness it was drawn with. Both are why colours are scaled on the way
  out and a brightness tail opens with a bridge line (below).

**What the vendor's engine says.** The vendor ships its LED engine as
`sdled.wasm` for its own preview (`inteliwear/sidepulse`, `src/sidepulse/
resources`), and it runs under Node. It is newer than the strip's firmware (it
takes `repeat N`, and it shows no flash at a parse), so it is evidence, not the
authority. On it: timing is millisecond-exact, the working loop 1585 ms, an
instant line 17 ms (the breath's period 4517, the blink's 1517), and a
brightness line costs no time; a per-LED pulse is the raised cosine
`(1 − cos 2πt/D) / 2` from the pre-pulse colour, to the unit; a whole-strip
pulse is the same; a plain per-LED crossfade eases like CSS `ease`
(`cubic-bezier(0.25, 0.1, 0.25, 1)`, 80 % of the way at half time), `linear`
and `cosine` are what they say; a crossfade behind a delay and a 17 ms
crossfade parse. `LedContinuation` uses those curves for the bridge.

**Cut rules**, each keeping the line's length so the tail ends exactly at the
loop's end:

| The segment under way | Its rest |
|---|---|
| whole-strip `off <d>` (`cosine` or not) | `off <remaining>` with the same easing |
| whole-strip `#hex <D> pulse`, rising | `#hex <D/2 − t> cosine`, then `off <D/2> cosine` on its own line |
| the same, falling | `off <remaining> cosine` |
| per-LED, not started yet | unchanged, its delay reduced |
| per-LED, finished | dropped: the LED holds what it holds |
| per-LED crossfade `i:#hex <d>` | `i:#hex <remaining>`, from where the LED is |
| per-LED pulse past its peak | `i:#000000 <remaining>`: a crossfade to its pre-pulse value, black in every program |
| per-LED pulse still rising, at or past half its peak (`riseToPeakFrom`) | on the bridge (below) `i:#hex <bridge>`, to its peak; then `i:#000000 <remaining>`, the fall |
| per-LED pulse still rising, below half | on the bridge `i:#000000 <bridge>`, to black; then `i:#hex <remaining> pulse 0ms`, the whole pulse from black, its peak a little late |
| per-LED pulse starting during the bridge | nothing on the bridge; then `i:#hex <remaining> pulse 0ms` from the bridge's end, up to 60 ms late |

**From a dark strip** (functional.md §3, off and back within
`K.resumeFromDarkSeconds`), the same cut with every pulse under way played
from black over what is left of it: a per-LED pulse, rising or falling, as
`i:#hex <remaining> pulse 0ms`; a whole-strip pulse on its way down as
`#hex <remaining> pulse`, one on its way up as its rising cosine, which from
black is already the fade-in. The rest is unchanged: LEDs not started yet
start on time, and a crossfade fades in to its target.

**The bridge.** A segment starts from the LED's visible value, and that value
was drawn at the old brightness, so a lit LED would carry the old brightness
to the end of its segment while a fresh pulse started at the new one. And a
rising pulse cannot be continued with one segment: a fall leaves a hole in
the wave, a pulse from its level leaves that level lit. So a brightness tail
opens with a BRIDGE line of up to `LedContinuation.bridgeMs` (60 ms, or what
is left of the line under way): every lit LED crossfades to where it goes on
from, at the new brightness once scaled. A falling pulse, and a crossfade, go
to their value at the bridge's end (the pulse's raised cosine, or the
crossfade's `ease` curve from the previous line's colour); a rising pulse at
or past half its peak goes to its peak and falls from there; one below half
goes to black and then plays whole from black; a held LED, a steady zone,
goes to its colour; a whole-strip line under way bridges as one instant
`#hex`. The cut then continues from the bridge's end, and a pulse that would
have started during the bridge starts at its end. Not from dark, where the
fade-in is the point, and dropped when it would not fit in 512 bytes, which
only the rainbow's first frame hits. The roll 500 ms in, cut at brightness
255 and as written at 128:

```
0:#ff374a 60ms; 1:#ff374a 60ms; 2:#000000 60ms; 3:#000000 60ms
0:#000000 360ms; 1:#000000 455ms; 2:#ff374a 550ms pulse 0ms; 3:#ff374a 645ms pulse 0ms; 4:#ff374a 740ms pulse 0ms; 5:#ff374a 760ms pulse 75ms; 6:#ff374a 760ms pulse 170ms; 7:#ff374a 760ms pulse 265ms
```

```
0:#801c25 60ms; 1:#801c25 60ms; 2:#000000 60ms; 3:#000000 60ms
0:#000000 360ms; 1:#000000 455ms; 2:#801c25 550ms pulse 0ms; 3:#801c25 645ms pulse 0ms; 4:#801c25 740ms pulse 0ms; 5:#801c25 760ms pulse 75ms; 6:#801c25 760ms pulse 170ms; 7:#801c25 760ms pulse 265ms
```

What that costs, on the pass of the press only: the two dimmest rising LEDs
go dark for the bridge and peak up to about 100 ms late, one LED started up
to 60 ms late, and a rising LED past half rises to its peak in 60 ms rather
than the rest of its rise. Nothing is skipped and nothing stays lit.

Every tail is cut from unscaled text, the palette's colours, and scaled once
on the way out; the Engine keeps the unscaled text of what plays, so a second
cut works from the same colours.

**A loop of several passes**, the roll two agents share, is cut the same way,
with one more rule. The bridge and the whole rest of the loop fit in 512 bytes
while four LEDs or so are lit; when they would not, the tail is the bridge and
the rest of the pass under way, which ends with every LED dark, and the loop
is written there (`LedContinuation.currentPass`): the bridge is worth more
than the pass order, and the cost is the first agent's colour twice in a row,
once, after a brightness change during its pass. The roll of three or four
agents is one pass and is cut like one agent's. The tail says how long it
plays, and the Engine hands over at that moment. **The full-strip roll changing
colour** (`LedProgram.rollRecolour`: any change of the agents rolling, between
the one-pass and the two-pass rolls too) is carried on by the same tail at the
same brightness, and the new loop is written at its end.
A cut duration is spelled the shortest way (`0.1s`); an unchanged one keeps
the spelling the host gave it, so the reader and the writer round-trip every
program byte for byte (`testEveryHostProgramReadsBackAsItself`).

**The roll under a zone.** When a split opens, closes or changes over the same
roll (the same agents: a roll whose agents change under a zone starts the
split anew), the tail is the roll's rest with the zone's LEDs taken out of every line
(`LedProgram.rollHandover` says which LEDs, `LedContinuation.transition` writes
it). A green zone is `i:#green 160ms` on the first line; a zone that closes is
`i:#000000 160ms` there. An amber zone needs blink one on a line of its own and
blink two 70 ms into the next, so the roll's line under way is split: its next
200 ms as one crossfade per LED to the value that LED's pulse reaches by then
(a chord of the pulse, `LedContinuation.piece`, the colour scaled per channel),
then its rest under the cut rules, blink two riding it. When a zone LED is lit
at that moment, a per-LED pulse would return it to that red and hold it under
the pair, so the split's own 160 ms baseline comes first, the zone fading to
black beside a 160 ms chord of the roll, then the two blink lines: three
lines, as soon as the split written outright would blink, and two lines again
if three would not fit in 512 bytes. The last chord is the bridge: at its
end a rising LED past half goes to its peak, one below half to black to start
over, and a pulse that would have started during it starts at its end. A
steady zone, and a zone that closes, open over the bridge itself. The tail ends
where the roll's loop would have, or on the roll two agents share where the
pass under way ends, so the loop written there finds the roll dark; the blink pair's
rhythm has one irregular gap there, from the transition to the loop's first
pair. When the roll is at its dark end, with nothing left but LED 7's fall,
the new program is written outright.

The 8-LED working roll 500 ms in, LEDs 0…2 lit, a question landing (brightness 255):

```
3:#9a212d 160ms; 4:#3a0c11 120ms 40ms; 5:#030101 25ms 135ms; 0:#000000 160ms; 1:#000000 160ms; 2:#000000 160ms
3:#fa3648 0.2s; 4:#f03446 0.2s; 5:#a42330 0.2s; 6:#430e13 130ms 70ms; 7:#050102 35ms 165ms; 0:#ff7000 0.2s pulse 0ms; 1:#ff7000 0.2s pulse 0ms; 2:#ff7000 0.2s pulse 0ms
3:#000000 345ms; 4:#000000 440ms; 5:#000000 535ms; 6:#000000 630ms; 7:#000000 725ms; 0:#ff7000 0.2s pulse 70ms; 1:#ff7000 0.2s pulse 70ms; 2:#ff7000 0.2s pulse 70ms
```

**Limits.** Every tail is checked at every phase in 5 ms steps, on 2 and 8 LEDs,
at 255 and 254: under 512 bytes and 20 lines, no brightness line, every line a
shape the reader knows, its length the loop's remainder within one frame, or
the pass's on the roll two agents share
(`testEveryTailIsWellFormedAndEndsAtTheLoopEnd`, `testEveryTransitionIsWellFormed`,
`testTheRollRecolouredAcrossAgentCounts`, `CodexTests`).

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
