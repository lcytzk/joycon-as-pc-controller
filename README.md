# GyroKeyMapper

Control your Mac with a pair of Nintendo Joy-Cons — from your lap, from the arm
of a chair, from wherever your hands are actually comfortable.

## Why this exists

If you share the pain point below, this is for you. If you don't, you probably
don't need it.

Agents are everywhere now, and a lot of my input has moved to voice. That
changed what I need a keyboard for: far less prose, far more short commands and
shortcuts. Plenty of people have noticed the same shift — companies are shipping
dedicated hardware for it, and geeks are building their own keyboards.

None of it went far enough for me, because all of it sits on a desk. Keeping my
hands on a desk is the thing that hurts in the first place. I wanted something I
could hold anywhere — on my lap, at my side, away from any surface at all. Going
looking for that, the Switch Joy-Con turned out to fit almost perfectly:
wireless, one per hand, no surface required, and enough buttons to be worth
mapping.

So this project is for anyone who wants to drive a computer from a pair of
Joy-Cons — agent workflows or not. Bind the shortcuts you actually use to the
buttons under your thumbs, and you can run the machine without reaching for the
desk.

**This is not for you if you need precise mouse control.** The Joy-Con gyro
simply isn't accurate enough for pixel work; it is fine for pointing at things,
not for drawing.

## Features

- **FN layers** — the feature this project was built around. Designate a button
  (ZL, ZR, anything) as an FN key and it doubles your vocabulary: `FN + A` means
  something different from `A`. An FN key keeps its ordinary binding on a *tap*
  and switches layer when *held*, so designating one costs you nothing, and you
  can have several. You only list the combinations you actually want — anything
  unlisted keeps doing what it already did.
- **Buttons** — each button maps to a key, a key combo (`cmd+tab`), a mouse
  click, or nothing. There is a Record button, so you press the shortcut instead
  of spelling it out.
- **Sticks** — each stick independently drives the mouse, a scroll wheel, four
  directional keys, or nothing.
- **Gyro-to-mouse** — either always-on rate control, or a "laser pointer" mode
  anchored to wherever the cursor was when a hold-to-activate button went down.
  Sensitivity, axis mapping, inversion, and a responsive/steady tradeoff are all
  adjustable.
- **Both halves together** — when both Joy-Cons are connected, a separate set of
  mappings takes over, with its own profile for holding them one per hand versus
  clipped into a grip. You choose which gyro drives the cursor, or fuse both into
  one: the second controller works out its own axis alignment by itself, and you
  can save that so it is ready immediately next time.
- **Battery** — the menu bar shows a charge percentage per controller, which
  macOS itself does not surface for these.
- Runs as a menu-bar-only background app, no Dock icon. Settings is a plain
  AppKit window built entirely in code.

## Build & run

Only the Swift toolchain is needed — no Xcode, no Xcode project, no CocoaPods.

```sh
bash start.sh            # builds if sources changed, then runs in the background
```

Or by hand:

```sh
cd GyroKeyMapper
swift build -c release
./.build/release/GyroKeyMapper
```

The app synthesises keyboard and mouse events, so it needs Accessibility
permission. If nothing happens when you press a button, grant it under System
Settings → Privacy & Security → Accessibility.

## Configuration

Open Settings from the 🎮 menu-bar icon. Every control saves as you change it —
there is no Save button.

Settings live in `GyroKeyMapper/keymap.txt` as plain `key=value` lines, next to
the source rather than hidden in `~/Library`, so your mapping is readable,
hand-editable, and produces a meaningful diff when one binding changes.

## Checking and debugging

```sh
bash GyroKeyMapper/Checks/run.sh
```

Runs the correctness checks. They are deliberately few — this app is close to
finished, so they cover only the failures that would be both silent and
expensive: FN routing across the two halves, settings surviving a save, and the
gyro fusion refusing two controllers that aren't one rigid body. See
`Checks/main.swift` for the reasoning.

Running with `GYROKEYMAPPER_DEBUG=1` logs a gyro sample-rate/gap summary and one
line per button event showing what FN resolved to — enough to tell "the pair
isn't recognised" from "that button isn't the FN key" from "the binding is wrong".

## Acknowledgement

Based on [magicien/JoyKeyMapper](https://github.com/magicien/JoyKeyMapper) and
[qibinc/JoyMapperSilicon](https://github.com/qibinc/JoyMapperSilicon), which
ported it to Apple Silicon. `Sources/JoyConSwift` is vendored from
[magicien/JoyConSwift](https://github.com/magicien/JoyConSwift) (MIT) since it
only ships a CocoaPods podspec, not a `Package.swift`. Thanks to both for
open-sourcing their work.
