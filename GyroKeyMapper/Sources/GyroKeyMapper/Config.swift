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
    // that must be held for gyro-to-mouse to be active.
    var activationButton: String? = nil
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
        smoothing: Double = 0.5
    ) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.horizontalAxis = horizontalAxis
        self.verticalAxis = verticalAxis
        self.invertHorizontal = invertHorizontal
        self.invertVertical = invertVertical
        self.activationButton = activationButton
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
        smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5
    }
}

struct AppConfig: Codable {
    var buttons: [String: ButtonAction] = [:]
    var leftStick: StickConfig = StickConfig()
    var rightStick: StickConfig = StickConfig()
    var gyro: GyroConfig = GyroConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
        leftStick = try container.decodeIfPresent(StickConfig.self, forKey: .leftStick) ?? StickConfig()
        rightStick = try container.decodeIfPresent(StickConfig.self, forKey: .rightStick) ?? StickConfig()
        gyro = try container.decodeIfPresent(GyroConfig.self, forKey: .gyro) ?? GyroConfig()
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
        config.gyro = GyroConfig(enabled: false, sensitivity: 8.0, horizontalAxis: "x", verticalAxis: "y", invertHorizontal: false, invertVertical: false, activationButton: "ZR")
        return config
    }
}

enum ConfigStore {
    static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GyroKeyMapper", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    static func loadOrCreateDefault() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            print("Loaded config from \(url.path)")
            return config
        }

        let defaultConfig = AppConfig.exampleDefault
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defaultConfig) {
            try? data.write(to: url)
        }
        print("No config found — wrote a default one to \(url.path)")
        print("Edit it and restart GyroKeyMapper to apply changes.")
        return defaultConfig
    }

    @discardableResult
    static func save(_ config: AppConfig) -> Bool {
        let url = configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            print("Failed to save config: \(error)")
            return false
        }
    }
}
