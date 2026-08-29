import AppKit
import JoyConSwift

/// Owns the tray icon, the connected controllers, and the settings window.
final class AppController: NSObject {
    private var config: AppConfig
    private var mappers: [ObjectIdentifier: ControllerMapper] = [:]
    private let manager = JoyConManager()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "No controller connected", action: nil, keyEquivalent: "")
    private var settingsWindowController: SettingsWindowController?

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
        let mapper = ControllerMapper(controller: controller, config: config)
        mappers[ObjectIdentifier(controller)] = mapper
        updateStatusMenu()
    }

    private func handleDisconnect(_ controller: JoyConSwift.Controller) {
        // Disconnecting mid-press must not leave a key or modifier held down
        // for the whole system.
        mappers.removeValue(forKey: ObjectIdentifier(controller))?.releaseAllHeldKeys()
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        if mappers.isEmpty {
            statusMenuItem.title = "No controller connected"
        } else {
            let names = mappers.values.map { $0.controller.type.rawValue }
            statusMenuItem.title = names.joined(separator: ", ")
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(config: config) { [weak self] newConfig in
                self?.applyConfig(newConfig)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func applyConfig(_ newConfig: AppConfig) {
        config = newConfig
        for mapper in mappers.values {
            mapper.config = newConfig
        }
        ConfigStore.save(newConfig)
    }
}
