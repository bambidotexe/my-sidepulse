# MySidepulse — app icon assets

1024 × 1024, full bleed, no rounded mask. The strip is symmetric, so it sits on the true centre of the canvas.

## Icon Composer stack (back to front)

| # | File | What it is | Settings |
|---|------|------------|----------|
| 0 | background (set on the canvas) | vertical gradient | `#2B2D37` (top) to `#0E0F14` (bottom); single colour: `#1D1E26` |
| 1 | `1_slot.svg` | the dark slot the LEDs sit in | fill `#07080B`, Liquid Glass on |
| 2 | `2_glow.png` | soft rainbow light inside the slot (bitmap, because a blurred multi-colour glow cannot be an SVG layer) | Liquid Glass **off** for this layer, opacity 100 % (lower it for a calmer icon) |
| 3 | `3_leds.svg` | the eight LEDs | keep the colours as imported, Liquid Glass on; this is the layer that should catch the specular |

Put each layer in its own group so the slot, the glow and the LEDs stack in depth.

`0_background.png` is the background gradient as a bitmap, only if you would rather import it.
`2_glow_flat_alt.svg` is an all-vector stand-in for the glow: eight flat discs that just touch. Use it at about 35–45 % opacity instead of `2_glow.png` if you want no bitmap in the icon.

LED colours, left to right: `#FF4B55`, `#FF8A3C`, `#FFD23F`, `#3DDC84`, `#2FD6E0`, `#3B8BFF`, `#8B6BFF`, `#F45BD6`

For the Mono appearance, set the LED layer's fill to white; the rainbow otherwise collapses to uneven greys.

## Other files

- `mysidepulse-flat.svg` — flat composite
- `previews/` — flat and simulated-glass PNGs with the rounded mask
