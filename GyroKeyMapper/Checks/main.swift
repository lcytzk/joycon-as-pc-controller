import Foundation
import JoyConSwift
import simd

// Correctness checks for GyroKeyMapper. Run with `bash Checks/run.sh`.
//
// Deliberately thin. This app is close to finished, so what earns a place here
// is not coverage but consequence: only failures that would be BOTH silent and
// expensive. Everything else in this app announces itself the first time you
// use it — a wrong key, a cursor that won't move — and needs no guarding.
//
// Three things qualify:
//
//   1. The FN layer's cross-half routing, and the rule that a release undoes
//      what the press did. Getting the first wrong emits the wrong key plus a
//      spurious extra one; getting the second wrong leaves a key held down for
//      the entire system, long after this app is the obvious suspect. The first
//      of these shipped once and was caught in review, not in use.
//
//   2. Config persistence. keymap.txt is hand-tuned and rewritten in full on
//      every settings change, so a field the encoder forgets is work the user
//      loses — and notices days later with no way to tell what happened.
//
//   3. The gyro fusion's refusal to trust two controllers that aren't one rigid
//      body. Accepting them steers the cursor by a motion neither controller
//      performed, which reads as drift or bad sensitivity rather than as a bug.

var failures: [String] = []

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok    \(what)")
    } else {
        print("  FAIL  \(what)")
        failures.append(what)
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
    check(actual == expected, actual == expected ? what : "\(what) — got \(actual), expected \(expected)")
}

func section(_ title: String) { print("\n\(title)") }

// ---------------------------------------------------------------------------
// 1. The FN layer
// ---------------------------------------------------------------------------
//
// These model the two-mapper composition — one ButtonSession per half over a
// shared CombineCoordinator — the way ControllerMapper.handleButton wires it.
// That method can't be built without a real HID device, so what is pinned here
// is the contract it has to satisfy, not the call itself.

/// One half of the pair, mirroring what handleButton does per controller.
struct Half {
    var session = ButtonSession()
    let combine: CombineCoordinator

    enum Emitted: Equatable { case nothing, press(String?), release(String?), tap(String?) }

    mutating func handle(_ button: JoyCon.Button, _ name: String, down: Bool,
                         base: [String: ButtonAction], fn: FnConfig, now: CFTimeInterval) -> Emitted {
        if fn.isFnKey(name) {
            if down {
                combine.fnPress(name, now: now)
            } else if combine.fnRelease(name, now: now), let tap = base[name] {
                return .tap(tap.key)
            }
            return .nothing
        }
        if down { combine.fnNoteOtherPress() }
        let engaged = combine.fnEngagedKeys()
        switch session.handle(button: button, name: name, isDown: down, base: base, fn: fn, engaged: engaged) {
        case .none: return .nothing
        case .press(let action): return .press(action.key)
        case .release(let action): return .release(action.key)
        }
    }
}

let base: [String: ButtonAction] = [
    "Left": ButtonAction(key: "left"),
    "ZR": ButtonAction(key: "f12"),   // the FN key's own tap action
    "A": ButtonAction(key: "z"),
]
/// The shipped shape: FN on the right half, its combination on the left.
let fn = FnConfig(enabled: true, layers: [
    FnLayer(key: "ZR", bindings: ["Left": ButtonAction(key: "backspace")]),
])

func pair(_ fn: FnConfig) -> (left: Half, right: Half, combine: CombineCoordinator) {
    let combine = CombineCoordinator()
    combine.update(isCombined: true, profile: CombineProfile(), fn: fn)
    return (Half(combine: combine), Half(combine: combine), combine)
}

section("FN layer")

// The regression this exists for. FN state was once per-mapper, and each half's
// button events only reach its own mapper — so a combination spanning the two
// halves silently emitted the ordinary binding, plus a spurious tap on release.
do {
    var (left, right, _) = pair(fn)
    _ = right.handle(.ZR, "ZR", down: true, base: base, fn: fn, now: 0)
    checkEqual(left.handle(.Left, "Left", down: true, base: base, fn: fn, now: 0.05), .press("backspace"),
               "FN held on the right half applies to a button on the left half")
    checkEqual(left.handle(.Left, "Left", down: false, base: base, fn: fn, now: 0.10), .release("backspace"),
               "and its release undoes the same binding")
    checkEqual(right.handle(.ZR, "ZR", down: false, base: base, fn: fn, now: 0.15), .nothing,
               "the other half's press settles FN as a hold, so no stray tap fires")
}

// A release has to undo what the press did rather than what the button would
// mean now. Get this wrong and the key is never released.
do {
    var (left, right, _) = pair(fn)
    checkEqual(left.handle(.Left, "Left", down: true, base: base, fn: fn, now: 0), .press("left"),
               "a button pressed with no FN held gives its ordinary binding")
    _ = right.handle(.ZR, "ZR", down: true, base: base, fn: fn, now: 0.1)
    checkEqual(left.handle(.Left, "Left", down: false, base: base, fn: fn, now: 0.2), .release("left"),
               "releasing it releases what it pressed, though FN engaged in between")
}

// Re-resolving the mapping releases every held key, so the bookkeeping has to go
// with it — including a held FN key, whose release would otherwise no longer
// match and would leave the layer engaged for good.
do {
    var parts = pair(fn)
    let combine = parts.combine
    _ = parts.right.handle(.ZR, "ZR", down: true, base: base, fn: fn, now: 0)
    check(!combine.fnEngagedKeys().isEmpty, "a held FN key registers")
    combine.update(isCombined: false, profile: CombineProfile(), fn: fn)
    check(combine.fnEngagedKeys().isEmpty, "a half disconnecting clears it rather than leaving it stuck")
}

// Tapping an FN key falls through to its ordinary binding, which is what makes
// designating one free. Holding it must not also fire that binding.
do {
    var (_, right, _) = pair(fn)
    _ = right.handle(.ZR, "ZR", down: true, base: base, fn: fn, now: 0)
    checkEqual(right.handle(.ZR, "ZR", down: false, base: base, fn: fn, now: 0.08), .tap("f12"),
               "a quick unused press of FN emits its ordinary binding")

    var (_, slow, _) = pair(fn)
    _ = slow.handle(.ZR, "ZR", down: true, base: base, fn: fn, now: 0)
    checkEqual(slow.handle(.ZR, "ZR", down: false, base: base, fn: fn, now: 0.4), .nothing,
               "held past the tapping term, no tap fires")
}

// Two FN keys at once is undefined by choice, and "undefined" has to mean no
// output — including no fallback to the ordinary binding.
do {
    let twoFn = FnConfig(enabled: true, layers: [
        FnLayer(key: "ZR", bindings: ["Left": ButtonAction(key: "backspace")]),
        FnLayer(key: "ZL", bindings: ["Left": ButtonAction(key: "escape")]),
    ])
    var (left, right, combine) = pair(twoFn)
    _ = right.handle(.ZR, "ZR", down: true, base: base, fn: twoFn, now: 0)
    _ = left.handle(.ZL, "ZL", down: true, base: base, fn: twoFn, now: 0.02)
    checkEqual(combine.fnEngagedKeys().count, 2, "FN keys on opposite halves are both visible")
    checkEqual(left.handle(.Left, "Left", down: true, base: base, fn: twoFn, now: 0.04), .nothing,
               "a button pressed with two FN keys held emits nothing")
}

// ---------------------------------------------------------------------------
// 2. Config persistence
// ---------------------------------------------------------------------------

section("Config persistence")

/// Every section populated, with non-default values throughout so a dropped
/// field can't coincide with its own default.
func fullyPopulated() -> AppConfig {
    var config = AppConfig()
    config.buttons = ["A": ButtonAction(key: "z"), "ZR": ButtonAction(mouseButton: "left")]
    config.leftStick = StickConfig(mode: .key, speed: 7, keys: ["up": ButtonAction(key: "w")])
    config.rightStick = StickConfig(mode: .mouse, speed: 15)
    config.leftGyro = GyroConfig(enabled: true, sensitivity: 40, horizontalAxis: "z", verticalAxis: "y",
                                 invertHorizontal: false, invertVertical: true,
                                 activationButton: "ZL", activationMode: .toggle, smoothing: 0.07)
    config.rightGyro = GyroConfig(enabled: true, sensitivity: 22, horizontalAxis: "y")
    config.combine.mode = .gripMounted
    config.combine.fn = FnConfig(enabled: true, layers: [
        FnLayer(
            key: "ZR", bindings: ["Left": ButtonAction(key: "backspace")],
            leftStickRotation: StickRotationConfig(target: .ctrl, degreesPerStep: 60),
            rightStickRotation: StickRotationConfig(target: .command, degreesPerStep: 45)
        ),
        FnLayer(key: "ZL", bindings: ["A": ButtonAction(mouseButton: "right")]),
    ])
    config.combine.separate = CombineProfile(gyroSource: .left)
    config.combine.grip = CombineProfile(
        gyroSource: .fused,
        fusionAlignment: FusionAlignment(textForm: "+y,+z,-x")
    )
    return config
}

do {
    let original = fullyPopulated()
    let reloaded = KeyValueConfigCodec.decode(KeyValueConfigCodec.encode(original))
    // Whole-config equality on purpose: naming individual fields here would
    // mean the next field added is the one nobody checks.
    check(reloaded == original, "every populated setting survives a save and reload")
    if reloaded != original {
        // Narrow it down rather than making someone diff two large structs.
        check(reloaded.buttons == original.buttons, "  …buttons")
        check(reloaded.leftStick == original.leftStick, "  …left stick")
        check(reloaded.rightStick == original.rightStick, "  …right stick")
        check(reloaded.leftGyro == original.leftGyro, "  …left gyro")
        check(reloaded.rightGyro == original.rightGyro, "  …right gyro")
        check(reloaded.combine.fn == original.combine.fn, "  …FN config")
        check(reloaded.combine.separate == original.combine.separate, "  …held-separately profile")
        check(reloaded.combine.grip == original.combine.grip, "  …grip profile")
    }

    // Encoding must be a fixed point, or this git-tracked file would churn on
    // its own between saves.
    let once = KeyValueConfigCodec.encode(original)
    let twice = KeyValueConfigCodec.encode(KeyValueConfigCodec.decode(once))
    check(once == twice, "saving twice produces an identical file")
}

// Combine settings used to live in one unprefixed block, including its own
// combine.button.*/combine.gyro.* — from when combine kept a second copy of
// buttons and per-side gyro tuning. Neither exists on CombineProfile any
// more, so such a file's combine.mode/combine.fn still load, and the button/
// gyro keys are simply unrecognized, same as any other setting an older or
// newer build doesn't know about.
do {
    let migrated = KeyValueConfigCodec.decode("""
    button.B.key=x
    combine.mode=gripMounted
    combine.button.A.key=enter
    combine.gyro.left.sensitivity=40.0
    """)
    checkEqual(migrated.combine.mode, .gripMounted, "combine.mode still loads from such a file")
    checkEqual(migrated.buttons["B"]?.key, "x", "settings outside combine are untouched")
}

// Every key is optional on read: a file from an older build must load rather
// than being silently replaced by defaults.
do {
    let sparse = KeyValueConfigCodec.decode("button.A.key=z")
    checkEqual(sparse.buttons["A"]?.key, "z", "a file predating a feature still loads")
    check(!sparse.combine.fn.enabled && sparse.combine.fn.layers.isEmpty, "and the missing feature is simply off")
    check(KeyValueConfigCodec.decode("").combine.mode == .separate, "an empty file yields usable defaults")
}

// A malformed stored calibration must be rejected outright rather than
// half-parsed into a mapping that would steer the cursor sideways.
do {
    check(FusionAlignment(textForm: "garbage") == nil, "a malformed calibration is rejected")
    check(FusionAlignment(textForm: "+y,+z") == nil, "so is one with the wrong number of axes")
    check(FusionAlignment(textForm: "+q,+z,-x") == nil, "so is one naming an axis that doesn't exist")
    checkEqual(FusionAlignment(textForm: "+y,?,-x")?.textForm, "+y,?,-x", "a partial calibration round-trips")
}

// ---------------------------------------------------------------------------
// 3. Gyro fusion safety
// ---------------------------------------------------------------------------

section("Gyro fusion safety")

let dt = 1.0 / 120

/// A grip: the second IMU's axes are a fixed signed permutation of the first's,
/// so both report the same rotation with the same magnitude.
func gripSample(_ i: Int, noise: Double = 0) -> (driver: SIMD3<Double>, other: SIMD3<Double>) {
    let t = Double(i) * dt
    let driver = SIMD3<Double>(
        120 * sin(2 * .pi * 0.7 * t),
        110 * sin(2 * .pi * 1.3 * t + 1.0),
        90 * sin(2 * .pi * 2.1 * t + 2.0)
    )
    var other = SIMD3<Double>()
    other[0] = -driver[2]
    other[1] = driver[0]
    other[2] = driver[1]
    if noise > 0 {
        var generator = SystemRandomNumberGenerator()
        for axis in 0..<3 { other[axis] += Double.random(in: -noise...noise, using: &generator) }
    }
    return (driver, other)
}

for noise in [0.0, 15.0, 30.0] {
    var alignment = GyroAlignment()
    var placedAfter: Double?
    for i in 0..<1800 {
        let sample = gripSample(i, noise: noise)
        alignment.update(driverRaw: sample.driver, other: sample.other, dt: dt)
        if !alignment.result.isEmpty {
            placedAfter = Double(i) * dt
            break
        }
    }
    let seconds = placedAfter.map { String(format: "%.1fs", $0) } ?? "never"
    check(alignment.result.textForm == "+y,+z,-x" && (placedAfter ?? .infinity) < 3.0,
          "a real grip is calibrated correctly and quickly through ±\(Int(noise)) deg/s of noise (\(seconds))")
}

// The failure that matters. Over a finite window, two independently waved
// controllers regularly throw up a signed axis that correlates beautifully with
// the driver — correlation alone cannot tell them apart.
do {
    var accepted: [String] = []
    for driverFrequency in [0.4, 0.7, 1.1, 1.9] {
        for otherFrequency in [0.5, 1.3, 2.9, 3.7] {
            for phase in [0.0, 1.1, 2.4] {
                var alignment = GyroAlignment()
                for i in 0..<1800 {
                    let t = Double(i) * dt
                    let driver = SIMD3<Double>(
                        120 * sin(2 * .pi * driverFrequency * t),
                        110 * sin(2 * .pi * (driverFrequency * 1.7) * t + 0.5),
                        90 * sin(2 * .pi * (driverFrequency * 2.3) * t + 1.5)
                    )
                    let other = SIMD3<Double>(
                        130 * sin(2 * .pi * otherFrequency * t + phase),
                        110 * sin(2 * .pi * (otherFrequency * 1.3) * t + phase * 2),
                        90 * sin(2 * .pi * (otherFrequency * 0.6) * t + phase * 3)
                    )
                    alignment.update(driverRaw: driver, other: other, dt: dt)
                    if !alignment.result.isEmpty {
                        accepted.append("\(driverFrequency)/\(otherFrequency)/\(phase)")
                        break
                    }
                }
            }
        }
    }
    check(accepted.isEmpty,
          "48 combinations of independent two-handed motion are all refused\(accepted.isEmpty ? "" : " — accepted \(accepted)")")
}

// Matching the magnitude of rotation removes the physics check and leaves only
// the structural ones. They have to hold on their own.
do {
    var accepted = 0
    for otherFrequency in [0.9, 1.6, 2.7, 3.9] {
        var alignment = GyroAlignment()
        for i in 0..<1800 {
            let t = Double(i) * dt
            let driver = SIMD3<Double>(
                120 * sin(2 * .pi * 0.7 * t),
                110 * sin(2 * .pi * 1.3 * t + 1.0),
                90 * sin(2 * .pi * 2.1 * t + 2.0)
            )
            var other = SIMD3<Double>(
                sin(2 * .pi * otherFrequency * t),
                sin(2 * .pi * (otherFrequency * 1.4) * t + 1.0),
                sin(2 * .pi * (otherFrequency * 0.7) * t + 2.0)
            )
            let otherLength = (other * other).sum().squareRoot()
            let driverLength = (driver * driver).sum().squareRoot()
            if otherLength > 1e-6 { other *= driverLength / otherLength }
            alignment.update(driverRaw: driver, other: other, dt: dt)
        }
        if !alignment.result.isEmpty { accepted += 1 }
    }
    checkEqual(accepted, 0, "unrelated motion is refused even when the magnitudes are forced to agree")
}

// A partial answer is the shape a coincidence takes — one axis that lined up for
// a moment. Handing one out would fuse that direction on a guess.
do {
    var alignment = GyroAlignment()
    for i in 0..<1800 {
        let t = Double(i) * dt
        let driver = SIMD3<Double>(120 * sin(2 * .pi * 0.7 * t), 0, 0)
        var other = SIMD3<Double>()
        other[1] = driver[0]
        alignment.update(driverRaw: driver, other: other, dt: dt)
    }
    checkEqual(alignment.placedAxisCount, 1, "turning the grip one way places one axis")
    check(alignment.result.isEmpty, "but nothing is usable until all three are in")
}

// Once calibrated, a half pulled out of the grip has to be noticed: the mapping
// is still right but the premise isn't.
do {
    var fusion = GyroFusion(stillnessThreshold: 3.0)
    checkEqual(fusion.combine(own: (h: 80, v: 30), other: (h: 80, v: 30), dt: dt).rate?.h, 80,
               "two agreeing IMUs average to the same rate")
    check(!fusion.isSuspended, "and the watchdog stays quiet")
    for _ in 0..<120 { _ = fusion.combine(own: (h: 0, v: 0), other: (h: 250, v: 0), dt: dt) }
    check(fusion.isSuspended, "a sustained disagreement stops the averaging")

    var twitchy = GyroFusion(stillnessThreshold: 3.0)
    checkEqual(twitchy.combine(own: (h: 0, v: 0), other: (h: 250, v: 0), dt: dt).rate?.h, 125,
               "a single disagreeing frame is not evidence")
}

// Half the point of two IMUs: when one drops a report, the other carries the
// tick rather than the cursor stalling.
do {
    var fusion = GyroFusion()
    checkEqual(fusion.combine(own: (h: 7, v: 7), other: nil, dt: dt).rate?.h, 7, "this half alone carries a tick")
    checkEqual(fusion.combine(own: nil, other: (h: 9, v: 9), dt: dt).rate?.h, 9, "so does the other half alone")
    check(fusion.combine(own: nil, other: nil, dt: dt).rate == nil, "neither reporting yields no rate")
}

// ---------------------------------------------------------------------------

if failures.isEmpty {
    print("\nall checks passed")
    exit(0)
}
print("\n\(failures.count) FAILED")
for failure in failures { print("  - \(failure)") }
exit(1)
