# GyroKeyMapper

Nintendo Joy-Con / Pro Controller mapper for Apple Silicon and Intel Macs. Maps buttons, sticks, and gyro to keyboard and mouse events, so games and other apps that don't natively support a gamepad on macOS (e.g. Witcher 3, CrossOver) can still be played with one.

A Swift Package Manager app — no Xcode project, no CocoaPods. Building only needs the Swift toolchain.

## Features

- **Buttons**: map each button to a key (including "+"-separated combos like `cmd+tab`), a mouse click, or nothing.
- **Sticks**: each stick independently drives mouse movement, a scroll wheel, four directional keys, or nothing.
- **Gyro-to-mouse**: turns the controller's gyroscope into mouse movement — either always-on rate control, or a "laser pointer" mode anchored to wherever the cursor was when a hold-to-activate button went down. Sensitivity, axis mapping, inversion, and a responsive/steady smoothing tradeoff are all configurable.
- Runs as a menu-bar-only background app (no Dock icon); Settings are a plain AppKit window built entirely in code.

## Build & run

```sh
cd GyroKeyMapper
swift build
./.build/debug/GyroKeyMapper
```

For a release build, use `swift build -c release` and run `.build/release/GyroKeyMapper` instead.

## Configuration

Open Settings from the 🎮 menu-bar icon. Configuration is stored as JSON at `~/Library/Application Support/GyroKeyMapper/config.json` and is picked up on launch and whenever Settings is saved.

To diagnose gyro connection stutter (report drops on the Bluetooth link vs. app-side stalls), run with `GYROKEYMAPPER_DEBUG=1` — it prints a sample-rate/gap summary to stdout every 2 seconds.

## Acknowledgement

This application is based on [magicien/JoyKeyMapper](https://github.com/magicien/JoyKeyMapper) and [qibinc/JoyMapperSilicon](https://github.com/qibinc/JoyMapperSilicon), which ported it to Apple Silicon. `Sources/JoyConSwift` is vendored from [magicien/JoyConSwift](https://github.com/magicien/JoyConSwift) (MIT license) since it only ships a CocoaPods podspec, not a `Package.swift`. Thanks to both for open-sourcing their work.
