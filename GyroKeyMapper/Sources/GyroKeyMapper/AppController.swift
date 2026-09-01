import AppKit
import JoyConSwift

/// Owns the tray icon, the connected controllers, and the settings window.
final class AppController: NSObject {
    private var config: AppConfig
    private var mappers: [ObjectIdentifier: ControllerMapper] = [:]
    private let combine = CombineCoordinator()
    private let manager = JoyConManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "No controller connected", action: nil, keyEquivalent: "")
    private var settingsWindowController: SettingsWindowController?
    private var fusionStatusTimer: Timer?

    override init() {
        self.config = ConfigStore.loadOrCreateDefault()
        super.init()
    }

    func start() {
        statusItem.button?.title = "🎮"

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

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
        notifyCombineStateChanged()
        updateStatusMenu()
    }

    private func handleDisconnect(_ controller: JoyConSwift.Controller) {
        // Disconnecting mid-press must not leave a key or modifier held down
        // for the whole system.
        mappers.removeValue(forKey: ObjectIdentifier(controller))?.releaseAllHeldKeys()
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
        combine.update(isCombined: isCombined(including: extra), profile: config.combine.activeProfile)
    }

    private func notifyCombineStateChanged() {
        for mapper in mappers.values { mapper.combineStateChanged() }
    }

    private func updateStatusMenu() {
        if mappers.isEmpty {
            statusMenuItem.title = "No controller connected"
        } else {
            let names = mappers.values.map { $0.controller.type.rawValue }
            statusMenuItem.title = names.joined(separator: ", ")
        }
        publishConnectionState()
    }

    /// The Combine settings only describe a both-halves-connected setup, so the
    /// settings window is told which halves are actually present rather than
    /// leaving the user to guess whether that page applies right now.
    private func publishConnectionState() {
        let types = mappers.values.map { $0.controller.type }
        settingsWindowController?.updateConnectionState(
            leftConnected: types.contains(.JoyConL),
            rightConnected: types.contains(.JoyConR)
        )
    }

    /// Fusing places the second IMU by watching the user move the grip, so the
    /// settings window has to be told about it as it happens. Polling only
    /// while that window is on screen keeps this off the input path entirely —
    /// nothing here runs during ordinary play.
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
