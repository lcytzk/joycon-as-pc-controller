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

struct ButtonAction: Codable {
    var key: String?
    var mouseButton: String? // "left" | "right" | "center"
}

enum StickMode: String, Codable {
    case none, key, mouse, wheel
}

// Decoding throughout tolerates missing keys: a config written by an older
// build must still load, since a decode failure silently replaces the user's
// whole setup with the defaults.

struct StickConfig: Codable {
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

struct GyroConfig: Codable {
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

// Whether both Joy-Cons are held one per hand (independent rigid bodies —
// today's per-side gyro behavior applies unchanged) or clipped into a single
// grip (one rigid body, two redundant IMUs). Only gyro handling depends on
// this; buttons and sticks already work the same either way.
enum CombineMode: String, Codable {
    case separate, gripMounted
}

// Settings that apply only when both Joy-Cons are connected at once. These
// leftGyro/rightGyro are a *separate* pair from AppConfig's own leftGyro/
// rightGyro — three fully independent contexts total (standalone left,
// standalone right, combine), since combined operation is meant to feel
// different from either controller used alone. NOTE: this is config/UI
// scaffolding only — runtime fusion of the two IMUs for `.gripMounted` (or
// any cooperative use of both for `.separate`) is not implemented yet, so
// `mode` currently has no effect on mouse behavior.
struct CombineConfig: Codable {
    var mode: CombineMode = .separate
    // Independent from the top-level `buttons` — using both Joy-Cons together
    // can reasonably want a different mapping than either used alone (e.g. a
    // button that means something as a modifier solo but conflicts when both
    // are live), even though day to day the two will mostly agree. "Copy
    // Settings" in the UI seeds this from the standalone buttons as a start.
    var buttons: [String: ButtonAction] = [:]
    var leftGyro: GyroConfig = GyroConfig()
    var rightGyro: GyroConfig = GyroConfig()

    init(
        mode: CombineMode = .separate,
        buttons: [String: ButtonAction] = [:],
        leftGyro: GyroConfig = GyroConfig(),
        rightGyro: GyroConfig = GyroConfig()
    ) {
        self.mode = mode
        self.buttons = buttons
        self.leftGyro = leftGyro
        self.rightGyro = rightGyro
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(CombineMode.self, forKey: .mode) ?? .separate
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        leftGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .leftGyro) ?? GyroConfig()
        rightGyro = try container.decodeIfPresent(GyroConfig.self, forKey: .rightGyro) ?? GyroConfig()
    }
}

// Joy-Con L and Joy-Con R each carry their own IMU, mounted at a different
// orientation on each controller's PCB — the same physical rotation reads as
// different (axis, sign) combinations on the two sides. So gyro settings are
// per-side, same as the sticks, rather than one config applied to whichever
// controller happens to be connected.
struct AppConfig: Codable {
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
        encodeButtons(config.combine.buttons, prefix: "combine.button", into: &lines)

        encodeStick(config.leftStick, prefix: "stick.left", into: &lines)
        encodeStick(config.rightStick, prefix: "stick.right", into: &lines)
        encodeGyro(config.leftGyro, prefix: "gyro.left", into: &lines)
        encodeGyro(config.rightGyro, prefix: "gyro.right", into: &lines)
        lines.append("combine.mode=\(config.combine.mode.rawValue)")
        encodeGyro(config.combine.leftGyro, prefix: "combine.gyro.left", into: &lines)
        encodeGyro(config.combine.rightGyro, prefix: "combine.gyro.right", into: &lines)

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
        config.combine = CombineConfig(
            mode: values["combine.mode"].flatMap(CombineMode.init(rawValue:)) ?? .separate,
            buttons: decodeButtons(prefix: "combine.button", from: values),
            leftGyro: decodeGyro(prefix: "combine.gyro.left", from: values),
            rightGyro: decodeGyro(prefix: "combine.gyro.right", from: values)
        )
        return config
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
