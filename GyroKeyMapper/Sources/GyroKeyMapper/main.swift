import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

let appController = AppController()
appController.start()

app.run()
