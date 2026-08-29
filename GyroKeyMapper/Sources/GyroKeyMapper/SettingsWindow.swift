import AppKit

private let allButtonNames: [String] = [
    "Up", "Right", "Down", "Left",
    "A", "B", "X", "Y",
    "L", "ZL", "R", "ZR",
    "Minus", "Plus", "Capture", "Home",
    "LStick", "RStick", "LeftSL", "LeftSR", "RightSL", "RightSR",
    "Start", "Select",
]

private let actionKindTitles = ["None", "Key", "Mouse Left", "Mouse Right", "Mouse Center"]

private func labeled(_ text: String, width: CGFloat? = nil) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    if let width = width {
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    return label
}

private func row(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.alignment = .centerY
    return stack
}

private struct ButtonRow {
    let name: String
    let typePopup: NSPopUpButton
    let keyField: NSTextField
}

/// A plain NSButton that remembers which text field it should fill in when
/// "Record" is clicked — avoids needing NSButton to be a dictionary key.
private final class RecordButton: NSButton {
    weak var targetField: NSTextField?
}

/// A settings window built entirely in code (no Storyboard/XIB), so it needs
/// only the Swift compiler to build — no Xcode required.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void

    private var buttonRows: [ButtonRow] = []

    private let leftStickModePopup = NSPopUpButton()
    private let leftStickSpeedField = NSTextField()
    private let leftStickKeyFields: [String: NSTextField] = [
        "up": NSTextField(), "down": NSTextField(), "left": NSTextField(), "right": NSTextField(),
    ]

    private let rightStickModePopup = NSPopUpButton()
    private let rightStickSpeedField = NSTextField()
    private let rightStickKeyFields: [String: NSTextField] = [
        "up": NSTextField(), "down": NSTextField(), "left": NSTextField(), "right": NSTextField(),
    ]

    private let gyroEnabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let gyroSensitivityField = NSTextField()
    private let gyroSmoothingSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let gyroHorizontalAxisPopup = NSPopUpButton()
    private let gyroVerticalAxisPopup = NSPopUpButton()
    private let gyroInvertHorizontalCheckbox = NSButton(checkboxWithTitle: "Invert Horizontal", target: nil, action: nil)
    private let gyroInvertVerticalCheckbox = NSButton(checkboxWithTitle: "Invert Vertical", target: nil, action: nil)
    private let gyroActivationPopup = NSPopUpButton()

    // Key-recording state: click "Record" next to a field, then press a real
    // key (or key combo) on the keyboard instead of typing its name.
    private var recordingMonitor: Any?
    private var recordingField: NSTextField?
    private var recordingButton: NSButton?
    // Direction (press vs release) is detected from the generic modifier
    // flags, but *which* key is recorded uses each flagsChanged event's own
    // keyCode — that's side-specific (e.g. left Control 0x3B vs right 0x3E),
    // unlike NSEvent.ModifierFlags.control which can't tell them apart.
    private var recordingHeldModifierFlags: NSEvent.ModifierFlags = []
    private var recordingCapturedKeyOrder: [CGKeyCode] = []

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GyroKeyMapper Settings"
        window.center()

        super.init(window: window)
        window.delegate = self
        buildUI()
        loadFromConfig()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        mainStack.addArrangedSubview(buildButtonsSection())
        mainStack.addArrangedSubview(buildStickSection(title: "Left Stick", modePopup: leftStickModePopup, speedField: leftStickSpeedField, keyFields: leftStickKeyFields))
        mainStack.addArrangedSubview(buildStickSection(title: "Right Stick", modePopup: rightStickModePopup, speedField: rightStickSpeedField, keyFields: rightStickKeyFields))
        mainStack.addArrangedSubview(buildGyroSection())

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = mainStack

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        let buttonRow = row([NSView(), cancelButton, saveButton]) // spacer pushes buttons right
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

            mainStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            mainStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func buildButtonsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(sectionTitle("Buttons"))

        for name in allButtonNames {
            let nameLabel = labeled(name, width: 70)
            let typePopup = NSPopUpButton()
            typePopup.addItems(withTitles: actionKindTitles)
            typePopup.target = self
            typePopup.action = #selector(buttonTypeChanged(_:))

            let keyField = NSTextField()
            keyField.placeholderString = "key name, e.g. z"
            keyField.widthAnchor.constraint(equalToConstant: 140).isActive = true

            let r = row([nameLabel, typePopup, keyField, recordButton(for: keyField)])
            stack.addArrangedSubview(r)
            buttonRows.append(ButtonRow(name: name, typePopup: typePopup, keyField: keyField))
        }

        return stack
    }

    private func buildStickSection(title: String, modePopup: NSPopUpButton, speedField: NSTextField, keyFields: [String: NSTextField]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(sectionTitle(title))

        modePopup.addItems(withTitles: ["None", "Mouse", "Key", "Wheel"])
        speedField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(row([labeled("Mode", width: 70), modePopup, labeled("Speed"), speedField]))

        for direction in ["up", "down", "left", "right"] {
            guard let field = keyFields[direction] else { continue }
            field.placeholderString = "key name (used when Mode = Key)"
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            stack.addArrangedSubview(row([labeled(direction.capitalized, width: 70), field, recordButton(for: field)]))
        }

        return stack
    }

    private func buildGyroSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(sectionTitle("Gyro Mouse"))

        stack.addArrangedSubview(gyroEnabledCheckbox)

        gyroSensitivityField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(row([labeled("Sensitivity", width: 90), gyroSensitivityField]))

        gyroSmoothingSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(row([labeled("Smoothing", width: 90), gyroSmoothingSlider, labeled("responsive ← → steady")]))

        gyroHorizontalAxisPopup.addItems(withTitles: ["X", "Y", "Z"])
        gyroVerticalAxisPopup.addItems(withTitles: ["X", "Y", "Z"])
        stack.addArrangedSubview(row([labeled("Horizontal Axis", width: 90), gyroHorizontalAxisPopup]))
        stack.addArrangedSubview(row([labeled("Vertical Axis", width: 90), gyroVerticalAxisPopup]))
        stack.addArrangedSubview(labeled("Physical axis identity varies by controller/grip — try combinations here and watch the cursor to find the right one."))

        stack.addArrangedSubview(row([gyroInvertHorizontalCheckbox, gyroInvertVerticalCheckbox]))

        gyroActivationPopup.addItem(withTitle: "Always")
        gyroActivationPopup.lastItem?.representedObject = ""
        for name in allButtonNames {
            gyroActivationPopup.addItem(withTitle: name)
            gyroActivationPopup.lastItem?.representedObject = name
        }
        stack.addArrangedSubview(row([labeled("Hold to activate", width: 90), gyroActivationPopup]))

        return stack
    }

    // MARK: - Config <-> UI

    private func loadFromConfig() {
        for r in buttonRows {
            let action = config.buttons[r.name]
            if let mouse = action?.mouseButton {
                switch mouse.lowercased() {
                case "right": r.typePopup.selectItem(at: 3)
                case "center", "middle": r.typePopup.selectItem(at: 4)
                default: r.typePopup.selectItem(at: 2)
                }
                r.keyField.isEnabled = false
            } else if let key = action?.key {
                r.typePopup.selectItem(at: 1)
                r.keyField.stringValue = key
                r.keyField.isEnabled = true
            } else {
                r.typePopup.selectItem(at: 0)
                r.keyField.isEnabled = false
            }
        }

        loadStick(config.leftStick, modePopup: leftStickModePopup, speedField: leftStickSpeedField, keyFields: leftStickKeyFields)
        loadStick(config.rightStick, modePopup: rightStickModePopup, speedField: rightStickSpeedField, keyFields: rightStickKeyFields)

        gyroEnabledCheckbox.state = config.gyro.enabled ? .on : .off
        gyroSensitivityField.stringValue = String(config.gyro.sensitivity)
        gyroSmoothingSlider.doubleValue = config.gyro.smoothing
        gyroHorizontalAxisPopup.selectItem(at: ["x", "y", "z"].firstIndex(of: config.gyro.horizontalAxis) ?? 0)
        gyroVerticalAxisPopup.selectItem(at: ["x", "y", "z"].firstIndex(of: config.gyro.verticalAxis) ?? 1)
        gyroInvertHorizontalCheckbox.state = config.gyro.invertHorizontal ? .on : .off
        gyroInvertVerticalCheckbox.state = config.gyro.invertVertical ? .on : .off
        let activation = config.gyro.activationButton ?? ""
        let index = gyroActivationPopup.itemArray.firstIndex { ($0.representedObject as? String) == activation } ?? 0
        gyroActivationPopup.selectItem(at: index)
    }

    private func loadStick(_ stick: StickConfig, modePopup: NSPopUpButton, speedField: NSTextField, keyFields: [String: NSTextField]) {
        switch stick.mode {
        case .none: modePopup.selectItem(at: 0)
        case .mouse: modePopup.selectItem(at: 1)
        case .key: modePopup.selectItem(at: 2)
        case .wheel: modePopup.selectItem(at: 3)
        }
        speedField.stringValue = String(stick.speed)
        for (direction, field) in keyFields {
            field.stringValue = stick.keys[direction]?.key ?? ""
        }
    }

    private func readStick(modePopup: NSPopUpButton, speedField: NSTextField, keyFields: [String: NSTextField]) -> StickConfig {
        let mode: StickMode
        switch modePopup.indexOfSelectedItem {
        case 1: mode = .mouse
        case 2: mode = .key
        case 3: mode = .wheel
        default: mode = .none
        }
        var keys: [String: ButtonAction] = [:]
        for (direction, field) in keyFields {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                keys[direction] = ButtonAction(key: text, mouseButton: nil)
            }
        }
        return StickConfig(mode: mode, speed: Double(speedField.stringValue) ?? 10.0, keys: keys)
    }

    // MARK: - Key recording

    private func recordButton(for field: NSTextField) -> NSButton {
        let button = RecordButton(title: "Record", target: self, action: #selector(recordButtonTapped(_:)))
        button.targetField = field
        return button
    }

    @objc private func recordButtonTapped(_ sender: NSButton) {
        guard let recordBtn = sender as? RecordButton, let field = recordBtn.targetField else { return }
        beginRecording(for: field, button: sender)
    }

    private func beginRecording(for field: NSTextField, button: NSButton) {
        stopRecording() // only one field records at a time

        recordingField = field
        recordingButton = button
        recordingHeldModifierFlags = []
        recordingCapturedKeyOrder = []
        button.title = "Recording… (Esc cancels)"
        field.stringValue = ""

        // If the field is still first responder, AppKit's own text-editing
        // key bindings (Emacs-style Ctrl+P/N/B/F/A/E = up/down/left/right/etc.
        // on a focused NSTextField) can consume a keystroke as a cursor-move
        // command instead of it reaching the recording monitor — move focus
        // off the field entirely and stop it accepting input for the duration.
        field.isEditable = false
        window?.makeFirstResponder(button)

        // Adding keys builds up the combo (shown live in the field); the
        // first key you let go of ends recording — no waiting for everything
        // to be released, no guessing timeouts.
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { // Escape always cancels outright, never recorded as a key
                    self.stopRecording()
                    return nil
                }
                self.recordKeyCode(CGKeyCode(event.keyCode))
                self.updateLiveRecordingDisplay(field: field)
                return nil

            case .keyUp:
                // Any regular key being released ends recording immediately,
                // using everything captured up to this point.
                self.finalizeRecording(field: field)
                return nil

            case .flagsChanged:
                // event.keyCode identifies exactly which physical modifier
                // changed (e.g. left Control 0x3B vs right Control 0x3E) —
                // unlike event.modifierFlags, which can't tell the two sides
                // apart. Use the flags only to detect press-vs-release.
                self.recordKeyCode(CGKeyCode(event.keyCode))
                let newFlags = event.modifierFlags
                let aModifierWasReleased = !self.recordingHeldModifierFlags.isSubset(of: newFlags)
                self.recordingHeldModifierFlags = newFlags
                self.updateLiveRecordingDisplay(field: field)
                if aModifierWasReleased && !self.recordingCapturedKeyOrder.isEmpty {
                    self.finalizeRecording(field: field)
                }
                return nil

            default:
                return event
            }
        }
    }

    private func recordKeyCode(_ code: CGKeyCode) {
        if !recordingCapturedKeyOrder.contains(code) {
            recordingCapturedKeyOrder.append(code)
        }
    }

    private func updateLiveRecordingDisplay(field: NSTextField) {
        field.stringValue = recordingCapturedKeyOrder.compactMap { keyCodeToCanonicalName[$0] }.joined(separator: "+")
    }

    private func finalizeRecording(field: NSTextField) {
        updateLiveRecordingDisplay(field: field)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
        }
        recordingMonitor = nil
        recordingButton?.title = "Record"
        recordingButton = nil
        recordingField?.isEditable = true
        recordingField = nil
        recordingHeldModifierFlags = []
        recordingCapturedKeyOrder = []
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    // MARK: - Actions

    @objc private func buttonTypeChanged(_ sender: NSPopUpButton) {
        guard let r = buttonRows.first(where: { $0.typePopup === sender }) else { return }
        r.keyField.isEnabled = sender.indexOfSelectedItem == 1
    }

    @objc private func cancelTapped() {
        stopRecording()
        loadFromConfig() // discard in-progress edits
        window?.close()
    }

    @objc private func saveTapped() {
        stopRecording()
        var unknownKeys: [String] = []
        var buttons: [String: ButtonAction] = [:]

        for r in buttonRows {
            switch r.typePopup.indexOfSelectedItem {
            case 1:
                let key = r.keyField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
                if key.isEmpty { continue }
                // "+"-separated combos (e.g. "cmd+tab") — each token must be a known key.
                let unknownTokens = key.split(separator: "+").map(String.init).filter { keyCodes[$0] == nil }
                if !unknownTokens.isEmpty { unknownKeys.append("\(r.name): \(unknownTokens.joined(separator: ", "))") }
                buttons[r.name] = ButtonAction(key: key, mouseButton: nil)
            case 2: buttons[r.name] = ButtonAction(key: nil, mouseButton: "left")
            case 3: buttons[r.name] = ButtonAction(key: nil, mouseButton: "right")
            case 4: buttons[r.name] = ButtonAction(key: nil, mouseButton: "center")
            default: break
            }
        }

        if !unknownKeys.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Unrecognized key name(s)"
            alert.informativeText = unknownKeys.joined(separator: "\n") + "\n\nFix these before saving."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        var newConfig = AppConfig()
        newConfig.buttons = buttons
        newConfig.leftStick = readStick(modePopup: leftStickModePopup, speedField: leftStickSpeedField, keyFields: leftStickKeyFields)
        newConfig.rightStick = readStick(modePopup: rightStickModePopup, speedField: rightStickSpeedField, keyFields: rightStickKeyFields)

        let activation = gyroActivationPopup.selectedItem?.representedObject as? String ?? ""
        let axisNames = ["x", "y", "z"]
        func axisName(for popup: NSPopUpButton, fallback: String) -> String {
            let i = popup.indexOfSelectedItem
            return (i >= 0 && i < axisNames.count) ? axisNames[i] : fallback
        }
        newConfig.gyro = GyroConfig(
            enabled: gyroEnabledCheckbox.state == .on,
            sensitivity: Double(gyroSensitivityField.stringValue) ?? 8.0,
            horizontalAxis: axisName(for: gyroHorizontalAxisPopup, fallback: "x"),
            verticalAxis: axisName(for: gyroVerticalAxisPopup, fallback: "y"),
            invertHorizontal: gyroInvertHorizontalCheckbox.state == .on,
            invertVertical: gyroInvertVerticalCheckbox.state == .on,
            activationButton: activation,
            smoothing: gyroSmoothingSlider.doubleValue
        )

        config = newConfig
        onSave(newConfig)
    }
}
