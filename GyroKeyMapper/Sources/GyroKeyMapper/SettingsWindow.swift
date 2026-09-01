import AppKit

// Joy-Con L and Joy-Con R are the only controllers this app targets right now
// (see AppConfig's leftGyro/rightGyro split), so buttons are grouped by which
// physical half they live on instead of one long undifferentiated list.
private let leftJoyConButtons: [String] = [
    "Up", "Right", "Down", "Left",
    "L", "ZL", "Minus", "Capture",
    "LStick", "LeftSL", "LeftSR",
]
private let rightJoyConButtons: [String] = [
    "A", "B", "X", "Y",
    "R", "ZR", "Plus", "Home",
    "RStick", "RightSL", "RightSR",
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

/// One side's stick controls — a plain value bag rather than a bunch of
/// separately-named properties, so left/right don't have to be hand-duplicated
/// wherever sticks are built, loaded, or read back.
private struct StickControls {
    let modePopup = NSPopUpButton()
    let speedField = NSTextField()
    let keyFields: [String: NSTextField] = [
        "up": NSTextField(), "down": NSTextField(), "left": NSTextField(), "right": NSTextField(),
    ]
}

/// One side's gyro controls — see `StickControls`.
private struct GyroControls {
    let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let sensitivityField = NSTextField()
    let smoothingSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let horizontalAxisPopup = NSPopUpButton()
    let verticalAxisPopup = NSPopUpButton()
    let invertHorizontalCheckbox = NSButton(checkboxWithTitle: "Invert Horizontal", target: nil, action: nil)
    let invertVerticalCheckbox = NSButton(checkboxWithTitle: "Invert Vertical", target: nil, action: nil)
    let activationPopup = NSPopUpButton()
    // Mutually exclusive with each other: a button either activates the gyro
    // mouse while held, or toggles it on/off with a click.
    let activationModePopup = NSPopUpButton()
}

/// A plain NSButton that remembers which text field it should fill in when
/// "Record" is clicked — avoids needing NSButton to be a dictionary key.
private final class RecordButton: NSButton {
    weak var targetField: NSTextField?
}

/// A plain NSView defaults to a non-flipped (bottom-left-origin) coordinate
/// system, which makes NSScrollView open showing the *bottom* of a taller-
/// than-viewport document view instead of the top. Flipping it is the
/// standard fix — same convention NSTextView and other scrollable AppKit
/// views use.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A settings window built entirely in code (no Storyboard/XIB), so it needs
/// only the Swift compiler to build — no Xcode required.
///
/// Every control commits to `config` and calls `onSave` the moment it
/// changes — there is no separate Save button to remember to click. Key
/// fields that don't yet parse to a known key are simply left out of the
/// saved config (and shown in red) rather than popping a blocking alert,
/// since that would fire on every half-typed keystroke.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void

    private var buttonRows: [ButtonRow] = []

    private let leftStickControls = StickControls()
    private let rightStickControls = StickControls()
    private let leftGyroControls = GyroControls()
    private let rightGyroControls = GyroControls()
    // Combine has its own independent left/right gyro pair — three fully
    // separate contexts (standalone left, standalone right, combine), since
    // combined operation is meant to feel different from either controller
    // used alone.
    private let combineLeftGyroControls = GyroControls()
    private let combineRightGyroControls = GyroControls()
    private let combineModePopup = NSPopUpButton()
    // Combine's own button mapping — independent from `buttonRows` above.
    // Using both Joy-Cons together can reasonably want different bindings
    // than either alone, so this isn't just a read-only mirror.
    private var combineButtonRows: [ButtonRow] = []

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
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

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let leftItem = NSTabViewItem(identifier: "left")
        leftItem.label = "Left Joy-Con"
        leftItem.view = buildScrollablePage(buildSidePage(buttonNames: leftJoyConButtons, stick: leftStickControls, gyro: leftGyroControls))

        let rightItem = NSTabViewItem(identifier: "right")
        rightItem.label = "Right Joy-Con"
        rightItem.view = buildScrollablePage(buildSidePage(buttonNames: rightJoyConButtons, stick: rightStickControls, gyro: rightGyroControls))

        let combineItem = NSTabViewItem(identifier: "combine")
        combineItem.label = "Combine"
        combineItem.view = buildScrollablePage(buildCombinePage())

        tabView.addTabViewItem(leftItem)
        tabView.addTabViewItem(rightItem)
        tabView.addTabViewItem(combineItem)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    /// Wraps `content` in a scroll view with real, explicit left/right
    /// breathing room — relying on NSStackView.edgeInsets alone here left the
    /// content flush against the window edge once it sat inside a scroll
    /// view's document view, so the inset is enforced with its own constraints.
    ///
    /// The document view's width must come *only* from being pinned to the
    /// clip view's leading/trailing — the clip view is already narrower than
    /// the scroll view itself (room for the scrollbar). Also constraining it
    /// to `scrollView.widthAnchor` (as earlier code here did) fights that by
    /// a constant 15pt and makes AppKit break one of the two arbitrarily,
    /// which is what left one tab's page rendering empty.
    private func buildScrollablePage(_ content: NSView) -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // NSTabView resizes a tab item's root view via legacy frame +
        // autoresizing-mask assignment on selection, not Auto Layout — this
        // view must keep translatesAutoresizingMaskIntoConstraints == true
        // (the default) for that to size it reliably; Auto Layout still
        // governs everything nested inside it.
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = container

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),

            container.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        return scrollView
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func buildSidePage(buttonNames: [String], stick: StickControls, gyro: GyroControls) -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20

        mainStack.addArrangedSubview(buildButtonsSection(names: buttonNames, rows: &buttonRows))
        mainStack.addArrangedSubview(buildStickSection(stick: stick))
        mainStack.addArrangedSubview(buildGyroSection(gyro: gyro, activationButtonNames: buttonNames))

        return mainStack
    }

    /// Settings that only matter when both Joy-Cons are connected at once.
    /// Buttons and sticks already work identically either way (see
    /// leftJoyConButtons/rightJoyConButtons above), so this page only adds a
    /// third gyro profile — for the case where the two controllers are one
    /// rigid body (grip-mounted) rather than two independent ones.
    private func buildCombinePage() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 4
        let copyButton = NSButton(title: "Copy Settings", target: self, action: #selector(copyCombineFromStandalone))
        let copyHint = labeled("Copies the Left/Right Joy-Con tabs' buttons and gyro tuning here (each into its matching side) as a starting point to fine-tune.")
        copyHint.textColor = .secondaryLabelColor
        copyHint.maximumNumberOfLines = 2
        copyHint.preferredMaxLayoutWidth = 380
        copyStack.addArrangedSubview(copyButton)
        copyStack.addArrangedSubview(copyHint)
        mainStack.addArrangedSubview(copyStack)

        let modeStack = NSStackView()
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 6
        modeStack.addArrangedSubview(sectionTitle("Mode"))
        combineModePopup.addItems(withTitles: ["Held Separately", "Mounted in Grip"])
        combineModePopup.target = self
        combineModePopup.action = #selector(settingsChanged(_:))
        modeStack.addArrangedSubview(combineModePopup)
        let modeHint = labeled("Only changes how the gyro sections below are handled at runtime. \"Mounted in Grip\" means sampling both IMUs at once and fusing them into one optimized trajectory — not wired up yet, so picking it has no effect on the cursor.")
        modeHint.textColor = .secondaryLabelColor
        modeHint.maximumNumberOfLines = 3
        modeHint.preferredMaxLayoutWidth = 380
        modeStack.addArrangedSubview(modeHint)
        mainStack.addArrangedSubview(modeStack)

        mainStack.addArrangedSubview(buildButtonsSection(names: leftJoyConButtons + rightJoyConButtons, rows: &combineButtonRows))
        mainStack.addArrangedSubview(buildGyroSection(gyro: combineLeftGyroControls, activationButtonNames: leftJoyConButtons, title: "Left Gyro"))
        mainStack.addArrangedSubview(buildGyroSection(gyro: combineRightGyroControls, activationButtonNames: rightJoyConButtons, title: "Right Gyro"))

        return mainStack
    }

    private func buildButtonsSection(names: [String], rows: inout [ButtonRow]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(sectionTitle("Buttons"))

        for name in names {
            let nameLabel = labeled(name, width: 70)
            let typePopup = NSPopUpButton()
            typePopup.addItems(withTitles: actionKindTitles)
            typePopup.target = self
            typePopup.action = #selector(buttonTypeChanged(_:))

            let keyField = NSTextField()
            keyField.placeholderString = "key name, e.g. z"
            keyField.delegate = self
            keyField.widthAnchor.constraint(equalToConstant: 140).isActive = true

            let r = row([nameLabel, typePopup, keyField, recordButton(for: keyField)])
            stack.addArrangedSubview(r)
            rows.append(ButtonRow(name: name, typePopup: typePopup, keyField: keyField))
        }

        return stack
    }

    private func buildStickSection(stick: StickControls) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(sectionTitle("Stick"))

        stick.modePopup.addItems(withTitles: ["None", "Mouse", "Key", "Wheel"])
        stick.modePopup.target = self
        stick.modePopup.action = #selector(settingsChanged(_:))
        stick.speedField.delegate = self
        stick.speedField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(row([labeled("Mode", width: 70), stick.modePopup, labeled("Speed"), stick.speedField]))

        for direction in ["up", "down", "left", "right"] {
            guard let field = stick.keyFields[direction] else { continue }
            field.placeholderString = "key name (used when Mode = Key)"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            stack.addArrangedSubview(row([labeled(direction.capitalized, width: 70), field, recordButton(for: field)]))
        }

        return stack
    }

    private func buildGyroSection(gyro: GyroControls, activationButtonNames: [String], title: String = "Gyro Mouse") -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(sectionTitle(title))

        gyro.enabledCheckbox.target = self
        gyro.enabledCheckbox.action = #selector(settingsChanged(_:))
        stack.addArrangedSubview(gyro.enabledCheckbox)

        gyro.sensitivityField.delegate = self
        gyro.sensitivityField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(row([labeled("Sensitivity", width: 90), gyro.sensitivityField]))

        gyro.smoothingSlider.target = self
        gyro.smoothingSlider.action = #selector(settingsChanged(_:))
        gyro.smoothingSlider.isContinuous = true
        gyro.smoothingSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(row([labeled("Smoothing", width: 90), gyro.smoothingSlider, labeled("responsive ← → steady")]))

        gyro.horizontalAxisPopup.addItems(withTitles: ["X", "Y", "Z"])
        gyro.horizontalAxisPopup.target = self
        gyro.horizontalAxisPopup.action = #selector(settingsChanged(_:))
        gyro.verticalAxisPopup.addItems(withTitles: ["X", "Y", "Z"])
        gyro.verticalAxisPopup.target = self
        gyro.verticalAxisPopup.action = #selector(settingsChanged(_:))
        stack.addArrangedSubview(row([labeled("Horizontal Axis", width: 90), gyro.horizontalAxisPopup]))
        stack.addArrangedSubview(row([labeled("Vertical Axis", width: 90), gyro.verticalAxisPopup]))
        let hint = labeled("Physical axis identity varies by grip — try combinations here and watch the cursor to find the right one.")
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(hint)

        gyro.invertHorizontalCheckbox.target = self
        gyro.invertHorizontalCheckbox.action = #selector(settingsChanged(_:))
        gyro.invertVerticalCheckbox.target = self
        gyro.invertVerticalCheckbox.action = #selector(settingsChanged(_:))
        stack.addArrangedSubview(row([gyro.invertHorizontalCheckbox, gyro.invertVerticalCheckbox]))

        gyro.activationPopup.addItem(withTitle: "Always")
        gyro.activationPopup.lastItem?.representedObject = ""
        for name in activationButtonNames {
            gyro.activationPopup.addItem(withTitle: name)
            gyro.activationPopup.lastItem?.representedObject = name
        }
        gyro.activationPopup.target = self
        gyro.activationPopup.action = #selector(settingsChanged(_:))

        gyro.activationModePopup.addItems(withTitles: ["Hold to Activate", "Click to Toggle"])
        gyro.activationModePopup.target = self
        gyro.activationModePopup.action = #selector(settingsChanged(_:))

        stack.addArrangedSubview(row([labeled("Activation", width: 90), gyro.activationModePopup, gyro.activationPopup]))

        return stack
    }

    // MARK: - Config -> UI

    private func loadFromConfig() {
        loadButtons(config.buttons, into: buttonRows)
        loadButtons(config.combine.buttons, into: combineButtonRows)

        loadStick(config.leftStick, into: leftStickControls)
        loadStick(config.rightStick, into: rightStickControls)
        loadGyro(config.leftGyro, into: leftGyroControls)
        loadGyro(config.rightGyro, into: rightGyroControls)

        combineModePopup.selectItem(at: config.combine.mode == .gripMounted ? 1 : 0)
        loadGyro(config.combine.leftGyro, into: combineLeftGyroControls)
        loadGyro(config.combine.rightGyro, into: combineRightGyroControls)
    }

    private func loadButtons(_ buttons: [String: ButtonAction], into rows: [ButtonRow]) {
        for r in rows {
            let action = buttons[r.name]
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
    }

    private func loadStick(_ stick: StickConfig, into controls: StickControls) {
        switch stick.mode {
        case .none: controls.modePopup.selectItem(at: 0)
        case .mouse: controls.modePopup.selectItem(at: 1)
        case .key: controls.modePopup.selectItem(at: 2)
        case .wheel: controls.modePopup.selectItem(at: 3)
        }
        controls.speedField.stringValue = String(stick.speed)
        for (direction, field) in controls.keyFields {
            field.stringValue = stick.keys[direction]?.key ?? ""
        }
    }

    private func loadGyro(_ gyro: GyroConfig, into controls: GyroControls) {
        controls.enabledCheckbox.state = gyro.enabled ? .on : .off
        controls.sensitivityField.stringValue = String(gyro.sensitivity)
        controls.smoothingSlider.doubleValue = gyro.smoothing
        controls.horizontalAxisPopup.selectItem(at: ["x", "y", "z"].firstIndex(of: gyro.horizontalAxis) ?? 0)
        controls.verticalAxisPopup.selectItem(at: ["x", "y", "z"].firstIndex(of: gyro.verticalAxis) ?? 1)
        controls.invertHorizontalCheckbox.state = gyro.invertHorizontal ? .on : .off
        controls.invertVerticalCheckbox.state = gyro.invertVertical ? .on : .off
        let activation = gyro.activationButton ?? ""
        let index = controls.activationPopup.itemArray.firstIndex { ($0.representedObject as? String) == activation } ?? 0
        controls.activationPopup.selectItem(at: index)
        controls.activationModePopup.selectItem(at: gyro.activationMode == .toggle ? 1 : 0)
    }

    // MARK: - UI -> Config

    /// Rebuilds `config` from every control and immediately persists it — the
    /// autosave path that replaces a Save button. Key fields that don't yet
    /// parse are simply omitted (and highlighted) rather than blocking with
    /// an alert, since this fires on every keystroke.
    private func commit() {
        let buttons = readButtons(from: buttonRows)
        let combineButtons = readButtons(from: combineButtonRows)

        var newConfig = AppConfig()
        newConfig.buttons = buttons
        newConfig.leftStick = readStick(leftStickControls)
        newConfig.rightStick = readStick(rightStickControls)
        newConfig.leftGyro = readGyro(leftGyroControls)
        newConfig.rightGyro = readGyro(rightGyroControls)
        newConfig.combine = CombineConfig(
            mode: combineModePopup.indexOfSelectedItem == 1 ? .gripMounted : .separate,
            buttons: combineButtons,
            leftGyro: readGyro(combineLeftGyroControls),
            rightGyro: readGyro(combineRightGyroControls)
        )

        config = newConfig
        onSave(newConfig)
    }

    private func readButtons(from rows: [ButtonRow]) -> [String: ButtonAction] {
        var buttons: [String: ButtonAction] = [:]
        for r in rows {
            switch r.typePopup.indexOfSelectedItem {
            case 1:
                let key = r.keyField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
                highlightIfUnknown(r.keyField, text: key)
                if !key.isEmpty && isFullyKnown(key) {
                    buttons[r.name] = ButtonAction(key: key, mouseButton: nil)
                }
            case 2: buttons[r.name] = ButtonAction(key: nil, mouseButton: "left")
            case 3: buttons[r.name] = ButtonAction(key: nil, mouseButton: "right")
            case 4: buttons[r.name] = ButtonAction(key: nil, mouseButton: "center")
            default: r.keyField.textColor = .labelColor
            }
        }
        return buttons
    }

    private func readStick(_ controls: StickControls) -> StickConfig {
        let mode: StickMode
        switch controls.modePopup.indexOfSelectedItem {
        case 1: mode = .mouse
        case 2: mode = .key
        case 3: mode = .wheel
        default: mode = .none
        }
        var keys: [String: ButtonAction] = [:]
        for (direction, field) in controls.keyFields {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            highlightIfUnknown(field, text: text)
            if !text.isEmpty && isFullyKnown(text) {
                keys[direction] = ButtonAction(key: text, mouseButton: nil)
            }
        }
        return StickConfig(mode: mode, speed: Double(controls.speedField.stringValue) ?? 10.0, keys: keys)
    }

    private func readGyro(_ controls: GyroControls) -> GyroConfig {
        let activation = controls.activationPopup.selectedItem?.representedObject as? String ?? ""
        let axisNames = ["x", "y", "z"]
        func axisName(for popup: NSPopUpButton, fallback: String) -> String {
            let i = popup.indexOfSelectedItem
            return (i >= 0 && i < axisNames.count) ? axisNames[i] : fallback
        }
        return GyroConfig(
            enabled: controls.enabledCheckbox.state == .on,
            sensitivity: Double(controls.sensitivityField.stringValue) ?? 8.0,
            horizontalAxis: axisName(for: controls.horizontalAxisPopup, fallback: "x"),
            verticalAxis: axisName(for: controls.verticalAxisPopup, fallback: "y"),
            invertHorizontal: controls.invertHorizontalCheckbox.state == .on,
            invertVertical: controls.invertVerticalCheckbox.state == .on,
            activationButton: activation,
            activationMode: controls.activationModePopup.indexOfSelectedItem == 1 ? .toggle : .hold,
            smoothing: controls.smoothingSlider.doubleValue
        )
    }

    /// "+"-separated combos (e.g. "cmd+tab") — every token must be a known key.
    private func isFullyKnown(_ combo: String) -> Bool {
        combo.split(separator: "+").allSatisfy { keyCodes[String($0)] != nil }
    }

    private func highlightIfUnknown(_ field: NSTextField, text: String) {
        field.textColor = (text.isEmpty || isFullyKnown(text)) ? .labelColor : .systemRed
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
        commit()
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

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        commit()
    }

    // MARK: - Actions

    @objc private func buttonTypeChanged(_ sender: NSPopUpButton) {
        guard let r = (buttonRows + combineButtonRows).first(where: { $0.typePopup === sender }) else { return }
        r.keyField.isEnabled = sender.indexOfSelectedItem == 1
        commit()
    }

    @objc private func settingsChanged(_ sender: Any) {
        commit()
    }

    @objc private func copyCombineFromStandalone() {
        loadButtons(readButtons(from: buttonRows), into: combineButtonRows)
        loadGyro(readGyro(leftGyroControls), into: combineLeftGyroControls)
        loadGyro(readGyro(rightGyroControls), into: combineRightGyroControls)
        commit()
    }
}
