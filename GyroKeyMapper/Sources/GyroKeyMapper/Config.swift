import Foundation
import JoyConSwift

// Canonical button-name vocabulary used both for JSON keys and for
// resolving a gyro activation-button name back to a JoyCon.Button.
let buttonNames: [JoyCon.Button: String] = [
    .Up: "Up", .Right: "Right", .Down: "Down", .Left: "Left",
    .A: "A", .B: "B", .X: "X", .Y: "Y",
    .L: "L", .ZL: "ZL", .R: "R", .ZR: "ZR",
    .Minus: "Minus", .Plus: "Plus", .Capture: "Capture", .Home: "Home",
    .LStick: "LStick", .RStick: "RStick",
    .LeftSL: "LeftSL", .LeftSR: "LeftSR",
    .RightSL: "RightSL", .RightSR: "RightSR",
    .Start: "Start", .Select: "Select",
]

struct ButtonAction: Codable, Equatable {
    var key: String?
    var mouseButton: String? // "left" | "right" | "center"
}

/// One FN key and the combinations it unlocks.
///
/// An FN key keeps its ordinary binding on a *tap* (see `ButtonSession`), so
/// designating one costs nothing — which is why there can be several rather
/// than exactly one.
///
/// `bindings` holds only the combinations actually asked for. A button missing
/// from it keeps doing whatever it does without FN: the equivalent of a
/// transparent key, and the reason this list stays short rather than being a
/// second copy of every button.
struct FnLayer: Codable, Equatable {
    /// A name from `buttonNames`, or nil while none has been chosen.
    var key: String? = nil
    var bindings: [String: ButtonAction] = [:]

    init(key: String? = nil, bindings: [String: ButtonAction] = [:]) {
        self.key = key
        self.bindings = bindings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        bindings = try container.decodeIfPresent([String: ButtonAction].self, forKey: .bindings) ?? [:]
    }

    /// Pointed at an actual button. A half-finished layer must change nothing,
    /// or switching the feature on before choosing a key would swallow one.
    var isConfigured: Bool { !(key ?? "").isEmpty }
}

/// Every FN key available while both Joy-Cons are connected, plus the one switch
/// that turns the lot on.
///
/// Only meaningful in combined operation: an FN combination will routinely span
/// the two halves (FN on the left, the bound button on the right), which is not
/// something a single controller can express.
struct FnConfig: Codable, Equatable {
    var enabled: Bool = false
    var layers: [FnLayer] = []

    init(enabled: Bool = false, layers: [FnLayer] = []) {
        self.enabled = enabled
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        layers = try container.decodeIfPresent([FnLayer].self, forKey: .layers) ?? []
    }

    var activeLayers: [FnLayer] { enabled ? layers.filter { $0.isConfigured } : [] }

    func layer(forKey name: String) -> FnLayer? { activeLayers.first { $0.key == name } }

    /// Whether this button is an FN key. Such a button emits nothing while
    /// held — only on a tap.
    func isFnKey(_ name: String) -> Bool { layer(forKey: name) != nil }

    /// Buttons already spoken for as FN keys, so the settings page can keep them
    /// out of the combination lists.
    var reservedKeys: Set<String> { Set(activeLayers.compactMap { $0.key }) }

    /// What a button does, given which FN keys are held right now.
    ///
    /// Holding two FN keys at once is not a gesture this supports. Rather than
    /// invent a winner, an ambiguous state produces no output at all — better
    /// to do nothing than to do something the user can't predict.
    func action(for name: String, base: [String: ButtonAction], engaged: [String]) -> ButtonAction? {
        guard engaged.count <= 1 else { return nil }
        if let key = engaged.first, let binding = layer(forKey: key)?.bindings[name] { return binding }
        return base[name]
    }
}

enum StickMode: String, Codable {
    case none, key, mouse, wheel
}

// Decoding throughout tolerates missing keys: a config written by an older
// build must still load, since a decode failure silently replaces the user's
// whole setup with the defaults.

struct StickConfig: Codable, Equatable {
    var mode: StickMode = .none
    var speed: Double = 10.0
    // Directions: "up", "down", "left", "right" — only used when mode == .key
    var keys: [String: ButtonAction] = [:]

    init(mode: StickMode = .none, speed: Double = 10.0, keys: [String: ButtonAction] = [:]) {
        self.mode = mode
        self.speed = speed
        self.keys = keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(StickMode.self, forKey: .mode) ?? .none
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 10.0
        keys = try container.decodeIfPresent([String: ButtonAction].self, forKey: .keys) ?? [:]
    }
}

// How `activationButton` turns the gyro mouse on and off — mutually
// exclusive, since a button can't simultaneously mean "active while held"
// and "toggles on/off when clicked".
enum GyroActivationMode: String, Codable {
    case hold, toggle
}

struct GyroConfig: Codable, Equatable {
    var enabled: Bool = false
    var sensitivity: Double = 8.0
    // Which raw gyro axis ("x"/"y"/"z") drives on-screen horizontal/vertical
    // movement — physical axis identity varies by controller/grip, so this is
    // exposed directly instead of guessed at in code.
    var horizontalAxis: String = "x"
    var verticalAxis: String = "y"
    var invertHorizontal: Bool = false
    var invertVertical: Bool = false
    // nil/empty = always active while enabled; otherwise a name from buttonNames
    // that activates gyro-to-mouse, per `activationMode`.
    var activationButton: String? = nil
    var activationMode: GyroActivationMode = .hold
    // 0 = most responsive, 1 = smoothest. Only sets how heavily an essentially
    // still hand is filtered; motion always opens the filter up, so raising it
    // costs steadiness-at-rest nothing in flick latency.
    var smoothing: Double = 0.5

    init(
        enabled: Bool = false,
        sensitivity: Double = 8.0,
        horizontalAxis: String = "x",
        verticalAxis: String = "y",
        invertHorizontal: Bool = false,
        invertVertical: Bool = false,
        activationButton: String? = nil,
        activationMode: GyroActivationMode = .hold,
        smoothing: Double = 0.5
    ) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.horizontalAxis = horizontalAxis
        self.verticalAxis = verticalAxis
        self.invertHorizontal = invertHorizontal
        self.invertVertical = invertVertical
        self.activationButton = activationButton
        self.activationMode = activationMode
        self.smoothing = smoothing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 8.0
        horizontalAxis = try container.decodeIfPresent(String.self, forKey: .horizontalAxis) ?? "x"
        verticalAxis = try container.decodeIfPresent(String.self, forKey: .verticalAxis) ?? "y"
        invertHorizontal = try container.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? false
        invertVertical = try container.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? false
        activationButton = try container.decodeIfPresent(String.self, forKey: .activationButton)
        activationMode = try container.decodeIfPresent(GyroActivationMode.self, forKey: .activationMode) ?? .hold
        smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5
    }
}

// Whether both Joy-Cons are held one per hand or clipped into a single grip.
// This is a *profile selector*, not a behavior flag: each mode carries its own
// complete set of combine settings — buttons included — because the same
// physical button can reasonably mean different things depending on how the
// pair is being held. Nothing here is auto-detectable (there is no signal that
// says "clipped into a grip"), so the user picks it.
enum CombineMode: String, Codable, CaseIterable {
    case separate, gripMounted
}

// Which gyro drives the cursor while both Joy-Cons are connected. Some choice
// is mandatory: each ControllerMapper posts an *absolute* cursor position
// computed from its own captured origin, so two simultaneously-live gyros mean
// two targets alternating every frame rather than one averaged motion.
//
// `.fused` samples both IMUs and combines them into a single trajectory. That
// only means anything when the two are one rigid body, so it is offered in the
// `.gripMounted` profile only.
enum CombineGyroSource: String, Codable {
    case left, right, fused
}

/// One complete set of settings for using both Joy-Cons together — everything
/// that can differ between the two ways of holding them. `CombineMode` selects
/// which profile is live; the other keeps its own values untouched.
struct CombineProfile: Codable, Equatable {
    // Independent from AppConfig's top-level `buttons`: both-at-once can want
    // different bindings than either controller alone, and the two holding
    // modes can want different bindings from each other.
    var buttons: [String: ButtonAction] = [:]
    // Same reasoning as `buttons`: a stick that is WASD when the halves are one
    // per hand can want to be the mouse once they're in a grip. Joy-Con L
    // reports as the left stick and Joy-Con R as the right, so the pair covers
    // both halves with no overlap.
    var leftStick: StickConfig = StickConfig()
    var rightStick: StickConfig = StickConfig()
    var gyroSource: CombineGyroSource = .right
    var leftGyro: GyroConfig = GyroConfig()
    var rightGyro: GyroConfig = GyroConfig()
    // The single gyro the user sees while fusing: a complete config, describing
    // the driving IMU exactly as a one-controller setup would. Where the second
    // IMU's axes sit relative to these is learned at runtime by `GyroAlignment`
    // rather than configured, so fusing asks nothing extra of the user.
    // leftGyro/rightGyro apply to the single-side sources only.
    var fused: GyroConfig = GyroConfig()
    // A saved answer to "how is the second IMU oriented relative to the first".
    // It's a property of two controllers in a grip, so it doesn't change
    // between sessions — storing it means the pair is ready to fuse the moment
    // it connects, instead of having to be waved about first. nil = not
    // calibrated, in which case it is worked out live.
    var fusionAlignment: FusionAlignment? = nil

    init(
        buttons: [String: ButtonAction] = [:],
        leftStick: StickConfig = StickConfig(),
        rightStick: StickConfig = StickConfig(),
        gyroSource: CombineGyroSource = .right,
        leftGyro: GyroConfig = GyroConfig(),
        rightGyro: GyroConfig = GyroConfig(),
        fused: GyroConfig = GyroConfig(),
        fusionAlignment: FusionAlignment? = nil
    ) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.gyroSource = gyroSource
        self.leftGyro = leftGyro
        self.rightGyro = rightGyro
        self.fused = fused
        self.fusionAlignment = fusionAlignment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        leftStick = try container.decodeIfPresent(StickConfig.self, forKey: .leftStick) ?? StickConfig()
        rightStick = try container.decodeIfPresent(StickConfig.self, forKey: .rightStick) ?? StickConfig()
        gyroSource = try container.decodeIfPresent(CombineGyroSource.self, forKey: .gyroSource) ?? .right
        leftGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .leftGyro) ?? GyroConfig()
        rightGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .rightGyro) ?? GyroConfig()
        fused = try container.decodeIfPresent(GyroConfig.self, forKey: .fused) ?? GyroConfig()
        fusionAlignment = try container.decodeIfPresent(FusionAlignment.self, forKey: .fusionAlignment)
    }
}

// Settings that apply only when both Joy-Cons are connected at once — one
// profile per holding mode, plus which of them is selected. While both halves
// are present these take over from the per-side settings entirely: see
// `CombineCoordinator` and `ControllerMapper.resolveMapping`.
struct CombineConfig: Codable, Equatable {
    var mode: CombineMode = .separate
    // Shared by both holding modes rather than living inside a profile: it has
    // its own settings tab, outside the mode switch, because an FN combination
    // spans both halves and isn't a property of how the pair is held.
    var fn: FnConfig = FnConfig()
    var separate: CombineProfile = CombineProfile()
    var grip: CombineProfile = CombineProfile()

    /// The profile a given mode selects — lets callers switch profiles without
    /// restating which stored property that is at every call site.
    subscript(mode: CombineMode) -> CombineProfile {
        get { mode == .gripMounted ? grip : separate }
        set {
            if mode == .gripMounted { grip = newValue } else { separate = newValue }
        }
    }

    var activeProfile: CombineProfile { self[mode] }

    init(mode: CombineMode = .separate, fn: FnConfig = FnConfig(), separate: CombineProfile = CombineProfile(), grip: CombineProfile = CombineProfile()) {
        self.mode = mode
        self.fn = fn
        self.separate = separate
        self.grip = grip
        normalize()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(CombineMode.self, forKey: .mode) ?? .separate
        fn = try container.decodeIfPresent(FnConfig.self, forKey: .fn) ?? FnConfig()
        separate = try container.decodeIfPresent(CombineProfile.self, forKey: .separate) ?? CombineProfile()
        grip = try container.decodeIfPresent(CombineProfile.self, forKey: .grip) ?? CombineProfile()
        normalize()
    }

    /// Fusing two independent rigid bodies would produce a motion nobody
    /// performed, so `.fused` is not a legal choice for the held-separately
    /// profile no matter where the value came from.
    private mutating func normalize() {
        if separate.gyroSource == .fused { separate.gyroSource = .right }
    }
}

// Joy-Con L and Joy-Con R each carry their own IMU, mounted at a different
// orientation on each controller's PCB — the same physical rotation reads as
// different (axis, sign) combinations on the two sides. So gyro settings are
// per-side, same as the sticks, rather than one config applied to whichever
// controller happens to be connected.
struct AppConfig: Codable, Equatable {
    var buttons: [String: ButtonAction] = [:]
    var leftStick: StickConfig = StickConfig()
    var rightStick: StickConfig = StickConfig()
    var leftGyro: GyroConfig = GyroConfig()
    var rightGyro: GyroConfig = GyroConfig()
    var combine: CombineConfig = CombineConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        leftStick = try container.decodeIfPresent(StickConfig.self, forKey: .leftStick) ?? StickConfig()
        rightStick = try container.decodeIfPresent(StickConfig.self, forKey: .rightStick) ?? StickConfig()
        leftGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .leftGyro) ?? GyroConfig()
        rightGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .rightGyro) ?? GyroConfig()
        combine = try container.decodeIfPresent(CombineConfig.self, forKey: .combine) ?? CombineConfig()
    }
}

extension AppConfig {
    static var exampleDefault: AppConfig {
        var config = AppConfig()
        config.buttons["A"] = ButtonAction(key: "z", mouseButton: nil)
        config.buttons["B"] = ButtonAction(key: "x", mouseButton: nil)
        config.buttons["X"] = ButtonAction(key: "c", mouseButton: nil)
        config.buttons["Y"] = ButtonAction(key: "v", mouseButton: nil)
        config.buttons["ZR"] = ButtonAction(key: nil, mouseButton: "left")
        config.buttons["ZL"] = ButtonAction(key: nil, mouseButton: "right")
        config.rightStick = StickConfig(mode: .mouse, speed: 15.0, keys: [:])
        config.rightGyro = GyroConfig(enabled: false, sensitivity: 8.0, horizontalAxis: "x", verticalAxis: "y", invertHorizontal: false, invertVertical: false, activationButton: "ZR")
        return config
    }
}

/// Legacy shape (single shared `gyro`, JSON) — read once to migrate an
/// existing ~/Library/Application Support config into the new per-side,
/// git-tracked keymap file.
private struct LegacyAppConfig: Decodable {
    var buttons: [String: ButtonAction] = [:]
    var leftStick: StickConfig = StickConfig()
    var rightStick: StickConfig = StickConfig()
    var gyro: GyroConfig = GyroConfig()

    private enum CodingKeys: String, CodingKey {
        case buttons, leftStick, rightStick, gyro
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        leftStick = try container.decodeIfPresent(StickConfig.self, forKey: .leftStick) ?? StickConfig()
        rightStick = try container.decodeIfPresent(StickConfig.self, forKey: .rightStick) ?? StickConfig()
        gyro = try container.decodeIfPresent(GyroConfig.self, forKey: .gyro) ?? GyroConfig()
    }
}

enum ConfigStore {
    /// Stored inside the Swift package (next to Package.swift) rather than in
    /// ~/Library/Application Support, so the mapping is a plain, diffable,
    /// git-tracked file instead of a hidden per-machine blob. `#filePath` is a
    /// compile-time constant here — fine for a single-machine personal tool,
    /// not something that needs to survive being relocated to another machine.
    static var configURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/GyroKeyMapper/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // GyroKeyMapper/ (package root)
            .appendingPathComponent("keymap.txt")
    }

    private static var legacyConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GyroKeyMapper", isDirectory: true).appendingPathComponent("config.json")
    }

    static func loadOrCreateDefault() -> AppConfig {
        let url = configURL
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let config = KeyValueConfigCodec.decode(text)
            print("Loaded config from \(url.path)")
            return config
        }

        if let data = try? Data(contentsOf: legacyConfigURL),
           let legacy = try? JSONDecoder().decode(LegacyAppConfig.self, from: data) {
            var migrated = AppConfig()
            migrated.buttons = legacy.buttons
            migrated.leftStick = legacy.leftStick
            migrated.rightStick = legacy.rightStick
            migrated.leftGyro = legacy.gyro
            migrated.rightGyro = legacy.gyro
            save(migrated)
            print("Migrated existing config from \(legacyConfigURL.path) to \(url.path)")
            return migrated
        }

        let defaultConfig = AppConfig.exampleDefault
        save(defaultConfig)
        print("No config found — wrote a default one to \(url.path)")
        return defaultConfig
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        let url = configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try KeyValueConfigCodec.encode(config).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to save config: \(error)")
            return false
        }
    }
}

/// A flat `key=value` text format for `AppConfig` — chosen over JSON so the
/// mapping file is easy to read/hand-edit and produces small, meaningful git
/// diffs when one binding changes. Every key is optional on read: a missing
/// or unparsable value falls back to the same default `AppConfig()` would use.
enum KeyValueConfigCodec {
    static func encode(_ config: AppConfig) -> String {
        var lines: [String] = []

        encodeButtons(config.buttons, prefix: "button", into: &lines)

        encodeStick(config.leftStick, prefix: "stick.left", into: &lines)
        encodeStick(config.rightStick, prefix: "stick.right", into: &lines)
        encodeGyro(config.leftGyro, prefix: "gyro.left", into: &lines)
        encodeGyro(config.rightGyro, prefix: "gyro.right", into: &lines)

        lines.append("combine.mode=\(config.combine.mode.rawValue)")
        encodeFn(config.combine.fn, prefix: "combine.fn", into: &lines)
        encodeCombineProfile(config.combine.separate, prefix: "combine.separate", into: &lines)
        encodeCombineProfile(config.combine.grip, prefix: "combine.grip", into: &lines)

        return lines.sorted().joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) -> AppConfig {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            values[key] = value
        }

        var config = AppConfig()
        config.buttons = decodeButtons(prefix: "button", from: values)
        config.leftStick = decodeStick(prefix: "stick.left", from: values)
        config.rightStick = decodeStick(prefix: "stick.right", from: values)
        config.leftGyro = decodeGyro(prefix: "gyro.left", from: values)
        config.rightGyro = decodeGyro(prefix: "gyro.right", from: values)
        config.combine = decodeCombine(from: values)
        return config
    }

    private static func encodeCombineProfile(_ profile: CombineProfile, prefix: String, into lines: inout [String]) {
        encodeButtons(profile.buttons, prefix: "\(prefix).button", into: &lines)
        encodeStick(profile.leftStick, prefix: "\(prefix).stick.left", into: &lines)
        encodeStick(profile.rightStick, prefix: "\(prefix).stick.right", into: &lines)
        lines.append("\(prefix).gyroSource=\(profile.gyroSource.rawValue)")
        encodeGyro(profile.leftGyro, prefix: "\(prefix).gyro.left", into: &lines)
        encodeGyro(profile.rightGyro, prefix: "\(prefix).gyro.right", into: &lines)
        encodeGyro(profile.fused, prefix: "\(prefix).gyro.fused", into: &lines)
        if let alignment = profile.fusionAlignment, !alignment.isEmpty {
            lines.append("\(prefix).fusion=\(alignment.textForm)")
        }
    }

    private static func decodeCombineProfile(prefix: String, from values: [String: String]) -> CombineProfile {
        CombineProfile(
            buttons: decodeButtons(prefix: "\(prefix).button", from: values),
            leftStick: decodeStick(prefix: "\(prefix).stick.left", from: values),
            rightStick: decodeStick(prefix: "\(prefix).stick.right", from: values),
            gyroSource: values["\(prefix).gyroSource"].flatMap(CombineGyroSource.init(rawValue:)) ?? .right,
            leftGyro: decodeGyro(prefix: "\(prefix).gyro.left", from: values),
            rightGyro: decodeGyro(prefix: "\(prefix).gyro.right", from: values),
            fused: decodeGyro(prefix: "\(prefix).gyro.fused", from: values),
            fusionAlignment: values["\(prefix).fusion"].flatMap(FusionAlignment.init(textForm:))
        )
    }

    /// Files written before combine settings were split per holding mode carry
    /// a single unprefixed `combine.*` block. It describes whichever mode was
    /// selected at the time, so it migrates into that profile and leaves the
    /// other one at its defaults — rather than being dropped, which would
    /// silently discard a mapping the user had already tuned.
    private static func decodeCombine(from values: [String: String]) -> CombineConfig {
        let mode = values["combine.mode"].flatMap(CombineMode.init(rawValue:)) ?? .separate
        let hasProfiles = values.keys.contains { $0.hasPrefix("combine.separate.") || $0.hasPrefix("combine.grip.") }
        guard hasProfiles else {
            var combine = CombineConfig(mode: mode, fn: decodeFn(prefix: "combine.fn", from: values))
            combine[mode] = CombineProfile(
                buttons: decodeButtons(prefix: "combine.button", from: values),
                leftGyro: decodeGyro(prefix: "combine.gyro.left", from: values),
                rightGyro: decodeGyro(prefix: "combine.gyro.right", from: values)
            )
            return combine
        }
        return CombineConfig(
            mode: mode,
            fn: decodeFn(prefix: "combine.fn", from: values),
            separate: decodeCombineProfile(prefix: "combine.separate", from: values),
            grip: decodeCombineProfile(prefix: "combine.grip", from: values)
        )
    }

    private static func encodeButtons(_ buttons: [String: ButtonAction], prefix: String, into lines: inout [String]) {
        for name in buttonNames.values.sorted() {
            guard let action = buttons[name] else { continue }
            if let key = action.key { lines.append("\(prefix).\(name).key=\(key)") }
            if let mouse = action.mouseButton { lines.append("\(prefix).\(name).mouse=\(mouse)") }
        }
    }

    private static func decodeButtons(prefix: String, from values: [String: String]) -> [String: ButtonAction] {
        var buttons: [String: ButtonAction] = [:]
        for name in buttonNames.values {
            let key = values["\(prefix).\(name).key"]
            let mouse = values["\(prefix).\(name).mouse"]
            if key != nil || mouse != nil {
                buttons[name] = ButtonAction(key: key, mouseButton: mouse)
            }
        }
        return buttons
    }

    private static func encodeFn(_ fn: FnConfig, prefix: String, into lines: inout [String]) {
        lines.append("\(prefix).enabled=\(fn.enabled)")
        for (index, layer) in fn.layers.enumerated() {
            let layerPrefix = "\(prefix).\(index)"
            if let key = layer.key, !key.isEmpty { lines.append("\(layerPrefix).key=\(key)") }
            encodeButtons(layer.bindings, prefix: "\(layerPrefix).button", into: &lines)
        }
    }

    private static func decodeFn(prefix: String, from values: [String: String]) -> FnConfig {
        // Indices are read back from the file rather than assumed up to some
        // ceiling, and are re-numbered contiguously on the next save.
        var indices: Set<Int> = []
        for key in values.keys where key.hasPrefix("\(prefix).") {
            let rest = key.dropFirst(prefix.count + 1)
            guard let dot = rest.firstIndex(of: "."), let index = Int(rest[rest.startIndex..<dot]) else { continue }
            indices.insert(index)
        }

        let layers = indices.sorted().compactMap { index -> FnLayer? in
            let layerPrefix = "\(prefix).\(index)"
            let layer = FnLayer(
                key: values["\(layerPrefix).key"],
                bindings: decodeButtons(prefix: "\(layerPrefix).button", from: values)
            )
            // A stored layer with neither a key nor a binding is noise.
            return (layer.isConfigured || !layer.bindings.isEmpty) ? layer : nil
        }

        return FnConfig(enabled: values["\(prefix).enabled"].flatMap(Bool.init) ?? false, layers: layers)
    }

    private static func encodeStick(_ stick: StickConfig, prefix: String, into lines: inout [String]) {
        lines.append("\(prefix).mode=\(stick.mode.rawValue)")
        lines.append("\(prefix).speed=\(stick.speed)")
        for (direction, action) in stick.keys {
            if let key = action.key { lines.append("\(prefix).key.\(direction)=\(key)") }
        }
    }

    private static func decodeStick(prefix: String, from values: [String: String]) -> StickConfig {
        let mode = values["\(prefix).mode"].flatMap(StickMode.init(rawValue:)) ?? .none
        let speed = values["\(prefix).speed"].flatMap(Double.init) ?? 10.0
        var keys: [String: ButtonAction] = [:]
        for direction in ["up", "down", "left", "right"] {
            if let key = values["\(prefix).key.\(direction)"] {
                keys[direction] = ButtonAction(key: key, mouseButton: nil)
            }
        }
        return StickConfig(mode: mode, speed: speed, keys: keys)
    }

    private static func encodeGyro(_ gyro: GyroConfig, prefix: String, into lines: inout [String]) {
        lines.append("\(prefix).enabled=\(gyro.enabled)")
        lines.append("\(prefix).sensitivity=\(gyro.sensitivity)")
        lines.append("\(prefix).horizontalAxis=\(gyro.horizontalAxis)")
        lines.append("\(prefix).verticalAxis=\(gyro.verticalAxis)")
        lines.append("\(prefix).invertHorizontal=\(gyro.invertHorizontal)")
        lines.append("\(prefix).invertVertical=\(gyro.invertVertical)")
        lines.append("\(prefix).smoothing=\(gyro.smoothing)")
        lines.append("\(prefix).activationMode=\(gyro.activationMode.rawValue)")
        if let activation = gyro.activationButton, !activation.isEmpty {
            lines.append("\(prefix).activationButton=\(activation)")
        }
    }

    private static func decodeGyro(prefix: String, from values: [String: String]) -> GyroConfig {
        GyroConfig(
            enabled: values["\(prefix).enabled"].flatMap(Bool.init) ?? false,
            sensitivity: values["\(prefix).sensitivity"].flatMap(Double.init) ?? 8.0,
            horizontalAxis: values["\(prefix).horizontalAxis"] ?? "x",
            verticalAxis: values["\(prefix).verticalAxis"] ?? "y",
            invertHorizontal: values["\(prefix).invertHorizontal"].flatMap(Bool.init) ?? false,
            invertVertical: values["\(prefix).invertVertical"].flatMap(Bool.init) ?? false,
            activationButton: values["\(prefix).activationButton"],
            activationMode: values["\(prefix).activationMode"].flatMap(GyroActivationMode.init(rawValue:)) ?? .hold,
            smoothing: values["\(prefix).smoothing"].flatMap(Double.init) ?? 0.5
        )
    }
}
