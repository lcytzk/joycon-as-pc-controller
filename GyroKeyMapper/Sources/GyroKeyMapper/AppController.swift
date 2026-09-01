import AppKit
import JoyConSwift

/// Owns the tray icon, the connected controllers, and the settings window.
final class AppController: NSObject {
    private var config: AppConfig
    private var mappers: [ObjectIdentifier: ControllerMapper] = [:]
    private let combine = CombineCoordinator()
    private let manager = JoyConManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// One row per connected controller, rebuilt on every change. Held onto so
    /// they can be swapped out without disturbing the items below them.
    private var controllerMenuItems: [NSMenuItem] = []
    private var settingsWindowController: SettingsWindowController?
    private var fusionStatusTimer: Timer?

    /// Raw regulated-voltage readings, per controller.
    private var batteryVoltages: [ObjectIdentifier: UInt16] = [:]
    private var batteryPollTimer: Timer?

    /// Battery, kept here rather than read off the controller on demand.
    ///
    /// JoyConSwift already parses it out of every standard input report — see
    /// `Controller.readStandardState` — but it writes those properties from the
    /// IOHID read thread. Capturing the value inside the change handler, which
    /// runs on that same thread, and carrying it to the main thread avoids
    /// reading them across threads at all.
    private var batteryLevels: [ObjectIdentifier: (level: JoyCon.BatteryStatus, charging: Bool)] = [:]

    override init() {
        self.config = ConfigStore.loadOrCreateDefault()
        super.init()
    }

    func start() {
        statusItem.button?.title = "🎮"

        let menu = NSMenu()
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateStatusMenu()

        manager.connectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.handleConnect(controller) }
        }
        manager.disconnectHandler = { [weak self] controller in
            DispatchQueue.main.async { self?.handleDisconnect(controller) }
        }
        _ = manager.runAsync()
    }

    private func handleConnect(_ controller: JoyConSwift.Controller) {
        // The coordinator has to know the pair is complete before the new
        // mapper resolves what it maps to, or the first one would come up
        // configured as if it were alone.
        refreshCombineState(adding: controller)
        let mapper = ControllerMapper(controller: controller, config: config, combine: combine)
        mappers[ObjectIdentifier(controller)] = mapper
        observeBattery(controller)
        requestBatteryVoltage(controller)
        startBatteryPolling()
        notifyCombineStateChanged()
        updateStatusMenu()
    }

    private func handleDisconnect(_ controller: JoyConSwift.Controller) {
        // Disconnecting mid-press must not leave a key or modifier held down
        // for the whole system.
        mappers.removeValue(forKey: ObjectIdentifier(controller))?.releaseAllHeldKeys()
        batteryLevels.removeValue(forKey: ObjectIdentifier(controller))
        batteryVoltages.removeValue(forKey: ObjectIdentifier(controller))
        if mappers.isEmpty {
            batteryPollTimer?.invalidate()
            batteryPollTimer = nil
        }
        refreshCombineState()
        notifyCombineStateChanged()
        updateStatusMenu()
    }

    /// Both Joy-Cons present means the Combine profile is what applies, rather
    /// than the per-side settings.
    private func isCombined(including extra: JoyConSwift.Controller? = nil) -> Bool {
        var types = mappers.values.map { $0.controller.type }
        if let extra = extra { types.append(extra.type) }
        return types.contains(.JoyConL) && types.contains(.JoyConR)
    }

    private func refreshCombineState(adding extra: JoyConSwift.Controller? = nil) {
        combine.update(isCombined: isCombined(including: extra), profile: config.combine.activeProfile, fn: config.combine.fn)
    }

    private func notifyCombineStateChanged() {
        for mapper in mappers.values { mapper.combineStateChanged() }
    }

    /// macOS doesn't surface these controllers' battery anywhere, but every
    /// standard input report carries it, so the tray can.
    private func observeBattery(_ controller: JoyConSwift.Controller) {
        let id = ObjectIdentifier(controller)

        // Seed from the current values first. The handlers below are change
        // hooks, and by the time a controller reports as connected it has
        // already delivered the input reports that set these — so waiting for a
        // change means never learning that a controller docked in the charging
        // grip is charging. This is the one place these are read off the
        // controller directly; a single load of a byte-sized enum and a Bool,
        // once per connection.
        batteryLevels[id] = (controller.battery, controller.isCharging)

        controller.batteryChangeHandler = { [weak self] level, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let charging = self.batteryLevels[id]?.charging ?? false
                self.batteryLevels[id] = (level, charging)
                self.updateStatusMenu()
            }
        }
        controller.isChargingChangeHandler = { [weak self] charging in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let level = self.batteryLevels[id]?.level ?? .unknown
                self.batteryLevels[id] = (level, charging)
                self.updateStatusMenu()
            }
        }
    }

    /// A rough charge percentage from a raw regulated-voltage reading.
    ///
    /// Linear over the usable range, which is the simplest model that isn't
    /// inventing anything. Two caveats when reading the number: a lithium
    /// cell's voltage-to-charge curve is not actually linear, and it sags under
    /// load, so this drifts while rumble and the sticks are busy. It is a
    /// "roughly how much is left" figure, not a fuel gauge.
    ///
    /// The endpoints are the documented ends of the reported range (about
    /// 3.3 V to 4.2 V), which is why "full" from the coarse per-report level
    /// can show as well under 100%: that bucket covers everything above ~3.9 V.
    static func batteryPercentage(fromRegulatedVoltage raw: UInt16) -> Int {
        let low = 1320.0, high = 1680.0
        let fraction = (Double(raw) - low) / (high - low)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private func requestBatteryVoltage(_ controller: JoyConSwift.Controller) {
        let id = ObjectIdentifier(controller)
        controller.readRegulatedVoltage { [weak self] raw in
            // Replies arrive on the IOHID read thread.
            DispatchQueue.main.async {
                guard let self = self, let raw = raw else { return }
                self.batteryVoltages[id] = raw
                self.updateStatusMenu()
            }
        }
    }

    /// The voltage reading costs a round trip, so it is asked for on a slow
    /// timer rather than per report. A battery does not move quickly, and this
    /// keeps the subcommand queue — shared with input configuration — quiet.
    private func startBatteryPolling() {
        guard batteryPollTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] timer in
            guard let self = self, !self.mappers.isEmpty else {
                timer.invalidate()
                self?.batteryPollTimer = nil
                return
            }
            for mapper in self.mappers.values {
                self.requestBatteryVoltage(mapper.controller)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryPollTimer = timer
    }

    /// What sits beside a controller's name: a percentage once a voltage reading
    /// has arrived, and the coarse level from the input reports until then —
    /// that one needs no round trip, so it is there almost immediately.
    private func batteryText(for controller: JoyConSwift.Controller) -> String {
        let id = ObjectIdentifier(controller)
        let charging = (batteryLevels[id]?.charging ?? false) ? " ⚡" : ""

        if let raw = batteryVoltages[id] {
            return "\(Self.batteryPercentage(fromRegulatedVoltage: raw))%\(charging)"
        }

        switch batteryLevels[id]?.level {
        case .full: return "full\(charging)"
        case .medium: return "medium\(charging)"
        case .low: return "low\(charging)"
        case .critical: return "critical\(charging)"
        case .empty: return "empty\(charging)"
        case .unknown, nil: return charging.isEmpty ? "…" : "charging"
        }
    }

    /// A menu row whose battery figure is right-aligned against a fixed column,
    /// so a list of controllers reads as a table rather than as ragged text.
    private func controllerMenuItem(name: String, battery: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(name)  \(battery)", action: nil, keyEquivalent: "")
        item.isEnabled = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 180)]
        item.attributedTitle = NSAttributedString(
            string: "\(name)\t\(battery)",
            attributes: [
                .paragraphStyle: paragraph,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        return item
    }

    private func updateStatusMenu() {
        guard let menu = statusItem.menu else { return }

        for item in controllerMenuItems where menu.items.contains(item) {
            menu.removeItem(item)
        }
        controllerMenuItems.removeAll()

        // Sorted, because dictionary order would otherwise let the two halves
        // swap places in the menu from one update to the next.
        let connected = mappers.values.sorted { $0.controller.type.rawValue < $1.controller.type.rawValue }
        if connected.isEmpty {
            let item = NSMenuItem(title: "No controller connected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            controllerMenuItems.append(item)
        } else {
            for mapper in connected {
                controllerMenuItems.append(controllerMenuItem(
                    name: mapper.controller.type.rawValue,
                    battery: batteryText(for: mapper.controller)
                ))
            }
        }

        for (index, item) in controllerMenuItems.enumerated() {
            menu.insertItem(item, at: index)
        }
        publishConnectionState()
    }

    /// Fusing places the second IMU by watching the user move the grip, so the
    /// settings window has to be told about it as it happens. Polling only
    /// while that window is on screen keeps this off the input path entirely —
    /// nothing here runs during ordinary play.
    /// The Combine settings only describe a both-halves-connected setup, so the
    /// settings window is told which halves are actually present rather than
    /// leaving the user to guess whether those pages apply right now.
    private func publishConnectionState() {
        let types = mappers.values.map { $0.controller.type }
        settingsWindowController?.updateConnectionState(
            leftConnected: types.contains(.JoyConL),
            rightConnected: types.contains(.JoyConR)
        )
    }

    private func startFusionStatusUpdates() {
        guard fusionStatusTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard let window = self.settingsWindowController?.window, window.isVisible else {
                timer.invalidate()
                self.fusionStatusTimer = nil
                return
            }
            let driver = self.mappers.values.first { $0.fusionStatus != .inactive }
            self.settingsWindowController?.updateFusionState(
                status: driver?.fusionStatus ?? .inactive,
                learned: driver?.learnedAlignment ?? FusionAlignment()
            )
            self.settingsWindowController?.updateFnState(
                engaged: self.combine.fnEngagedKeys().last,
                combined: self.isCombined()
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        fusionStatusTimer = timer
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(config: config) { [weak self] newConfig in
                self?.applyConfig(newConfig)
            }
        }
        publishConnectionState()
        startFusionStatusUpdates()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        // Which profile is live can change here too (the holding mode is part
        // of the config), so the shared state goes first — each mapper reads it
        // while resolving its own new mapping.
        refreshCombineState()
        for mapper in mappers.values {
            mapper.config = newConfig
        }
        ConfigStore.save(newConfig)
    }
}
