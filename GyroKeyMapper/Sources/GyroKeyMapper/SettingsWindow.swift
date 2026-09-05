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

// Rotate-to-switch-tabs (see `StickRotationConfig`) is offered as two more
// choices in an FN combination row's target popup, alongside every ordinary
// controller button — picking one turns that row into "while this FN key is
// held, sweep this stick to switch tabs/apps" instead of "press this button".
// The ids are deliberately unlike any button name (`buttonNames`'s values are
// all bare button names with no punctuation) so they can share the same
// `representedObject`-keyed candidate list and duplicate-detection logic
// (`fnRowButtonChanged`) as real buttons without ever colliding with one.
private let leftStickRotateTargetID = "rotate.left"
private let rightStickRotateTargetID = "rotate.right"
private let stickRotationRowTargets: [(id: String, title: String)] = [
    (leftStickRotateTargetID, "Left Stick Rotate"),
    (rightStickRotateTargetID, "Right Stick Rotate"),
]
private let rotationTargetTitles = ["Off", "Ctrl+Tab (browser tabs)", "Option+Tab", "Cmd+Tab (app switcher)"]

private func isStickRotationTarget(_ id: String) -> Bool {
    id == leftStickRotateTargetID || id == rightStickRotateTargetID
}

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
    /// Live x/y and a running count of rotation steps fired, updated while
    /// Settings is open — see `SettingsWindowController.updateStickDebugState`.
    let debugLabel = NSTextField(labelWithString: "live: waiting for input…")
}

/// One gyro section's controls — see `StickControls`.
private final class GyroControls {
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

/// One "FN + target → action" line. `buttonPopup` names the target — an
/// ordinary controller button, or one of the two stick-rotation pseudo-
/// targets (see `stickRotationRowTargets`) — and `typePopup` + `keyField`/
/// `degreesField` hold whichever kind of action that target takes: a button
/// takes an action kind (None/Key/Mouse) and, for Key, a key name; a
/// rotation target takes a rotation target (Off/Ctrl/Option/Cmd) and, for
/// anything but Off, degrees-per-switch. Only one of `keyField`/`degreesField`
/// is ever visible at a time — see `configureRowKind`.
private final class FnRow {
    let buttonPopup = NSPopUpButton()
    let typePopup = NSPopUpButton()
    let keyField = NSTextField()
    let degreesField = NSTextField()
    var recordButtonRef: NSButton?
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    var container: NSView?
}

/// One FN key and its combinations.
private final class FnLayerControls {
    let keyPopup = NSPopUpButton()
    let removeButton = NSButton(title: "Remove FN Key", target: nil, action: nil)
    let rowsStack = NSStackView()
    let addRowButton = NSButton(title: "+ Add Combination", target: nil, action: nil)
    var rows: [FnRow] = []
    var container: NSView?
}

/// The whole FN page. Combinations are built as the user adds them rather than
/// being a row per button: 22 rows of mostly-empty controls per FN key would
/// bury the handful of bindings that actually exist.
private final class FnControls {
    let enabledCheckbox = NSButton(checkboxWithTitle: "Enable FN keys", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let liveLabel = NSTextField(wrappingLabelWithString: "")
    let layersStack = NSStackView()
    let addLayerButton = NSButton(title: "+ Add FN Key", target: nil, action: nil)
    var layers: [FnLayerControls] = []
    /// Everything below the enable checkbox, so it can be dimmed as a unit.
    weak var body: NSStackView?
}

/// A plain NSView defaults to a non-flipped (bottom-left-origin) coordinate
/// system, which makes NSScrollView open showing the *bottom* of a taller-
/// than-viewport document view instead of the top. Flipping it is the
/// standard fix — same convention NSTextView and other scrollable AppKit
/// views use.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A dot inside a circle, at the stick's raw x/y (each roughly -1...1) — the
/// classic gamepad-tester deflection view. Deliberately *not* flipped: +y
/// staying "up" on screen is what makes pushing the stick up read as
/// intuitive, and that only holds in AppKit's default bottom-left-origin
/// coordinate space.
private final class StickIndicatorView: NSView {
    var position: CGPoint = .zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 6

        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: center.x - radius, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        ctx.move(to: CGPoint(x: center.x, y: center.y - radius))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        ctx.strokePath()

        let clampedX = max(-1, min(1, position.x))
        let clampedY = max(-1, min(1, position.y))
        let magnitude = (position.x * position.x + position.y * position.y).squareRoot()
        let dotCenter = CGPoint(x: center.x + clampedX * radius, y: center.y + clampedY * radius)
        let dotRadius: CGFloat = 5
        // Green once past the rotation gesture's own deadzone, so this
        // doubles as "is my push even registering as one" without leaving
        // this page.
        ctx.setFillColor((magnitude >= 0.5 ? NSColor.systemGreen : NSColor.systemBlue).cgColor)
        ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    }
}

/// One side's diagnostic page controls — button highlight labels keyed by
/// name, the stick's live dot, and a raw gyro readout.
private final class TestPageControls {
    var buttonLabels: [String: NSTextField] = [:]
    let stickIndicator = StickIndicatorView()
    let stickText = NSTextField(labelWithString: "")
    let gyroText = NSTextField(labelWithString: "")
}

/// A settings window built entirely in code (no Storyboard/XIB), so it needs
/// only the Swift compiler to build — no Xcode required.
///
/// Every control commits to `config` and calls `onSave` the moment it
/// changes — there is no separate Save button to remember to click. Key
/// fields that don't yet parse to a known key are simply left out of the
/// saved config (and shown in red) rather than popping a blocking alert,
/// since that would fire on every half-typed keystroke.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTabViewDelegate {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void
    /// Told whenever the Left/Right Test tab becomes (or stops being) the
    /// selected one, so real output can be suppressed only while that
    /// controller's test page is actually on screen. Both false covers every
    /// other tab and is also forced on window close.
    private let onTestModeChanged: (_ leftSuppressed: Bool, _ rightSuppressed: Bool) -> Void

    private var buttonRows: [ButtonRow] = []
    // FN gets its own tab rather than a section on an existing page: a
    // combination routinely spans the two halves, so it belongs to neither
    // side's page, and it isn't a property of how the pair is held either.
    private let fnControls = FnControls()

    private let leftStickControls = StickControls()
    private let rightStickControls = StickControls()
    private let leftGyroControls = GyroControls()
    private let rightGyroControls = GyroControls()
    private let leftTestControls = TestPageControls()
    private let rightTestControls = TestPageControls()

    // The Combine page shows one holding-mode profile at a time. This is which
    // one — the controls below it are that profile's, and everything read out
    // of them is written back to it.
    private var combineMode: CombineMode = .separate
    private let combineModeSegmented = NSSegmentedControl(
        labels: ["Held Separately", "Mounted in Grip"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var combineSourceRadios: [CombineGyroSource: NSButton] = [:]
    private var combineFusedRadioHint: NSTextField?
    private let combineStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let combineFusionStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveCalibrationButton = NSButton(title: "Save Calibration", target: nil, action: nil)
    private let clearCalibrationButton = NSButton(title: "Clear", target: nil, action: nil)
    /// The calibration stored in the profile on screen, if any. There is no
    /// control that edits it directly — it is captured from the running
    /// alignment — so it rides along here between load and commit.
    private var combineSavedAlignment: FusionAlignment?
    /// The latest live-learned alignment, pushed in by `AppController`.
    private var latestLearnedAlignment = FusionAlignment()

    /// Set while controls are being filled in from a config, so the autosave
    /// path stays out of the way. Programmatic setters mostly don't fire their
    /// action, but a text field with an active field editor is the exception —
    /// and switching profiles with a key field focused would otherwise write
    /// the incoming profile's values straight back over the outgoing one.
    private var isReloading = false

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

    // Controller-button conflict detection (FN tab): each FN key/button-
    // choosing popup's last confirmed selection, so a rejected reassignment
    // has an exact value to roll back to — an NSPopUpButton has no
    // "editing session" the way a text field does to hook a revert into.
    private var confirmedButtonSelections: [ObjectIdentifier: String] = [:]

    init(
        config: AppConfig, onSave: @escaping (AppConfig) -> Void,
        onTestModeChanged: @escaping (_ leftSuppressed: Bool, _ rightSuppressed: Bool) -> Void
    ) {
        self.config = config
        self.onSave = onSave
        self.onTestModeChanged = onTestModeChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
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
        tabView.delegate = self

        let leftItem = NSTabViewItem(identifier: "left")
        leftItem.label = "Left Joy-Con"
        leftItem.view = buildScrollablePage(buildSidePage(buttonNames: leftJoyConButtons, stick: leftStickControls, gyro: leftGyroControls))

        let rightItem = NSTabViewItem(identifier: "right")
        rightItem.label = "Right Joy-Con"
        rightItem.view = buildScrollablePage(buildSidePage(buttonNames: rightJoyConButtons, stick: rightStickControls, gyro: rightGyroControls))

        let combineItem = NSTabViewItem(identifier: "combine")
        combineItem.label = "Combine"
        combineItem.view = buildScrollablePage(buildCombinePage())

        let fnItem = NSTabViewItem(identifier: "combineFn")
        fnItem.label = "Combine FN"
        fnItem.view = buildScrollablePage(buildFnPage())

        let leftTestItem = NSTabViewItem(identifier: "leftTest")
        leftTestItem.label = "Left Test"
        leftTestItem.view = buildScrollablePage(buildTestPage(buttonNames: leftJoyConButtons, controls: leftTestControls))

        let rightTestItem = NSTabViewItem(identifier: "rightTest")
        rightTestItem.label = "Right Test"
        rightTestItem.view = buildScrollablePage(buildTestPage(buttonNames: rightJoyConButtons, controls: rightTestControls))

        tabView.addTabViewItem(leftItem)
        tabView.addTabViewItem(rightItem)
        tabView.addTabViewItem(combineItem)
        tabView.addTabViewItem(fnItem)
        tabView.addTabViewItem(leftTestItem)
        tabView.addTabViewItem(rightTestItem)

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

    /// The FN page: which buttons act as FN, and what each unlocks.
    ///
    /// Its own tab rather than a section on an existing page, because a
    /// combination routinely spans the two halves — FN under a left-hand finger,
    /// the bound button on the right — so it belongs to neither side's page, and
    /// it is not a property of how the pair is held either.
    private func buildFnPage() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16

        fnControls.statusLabel.isSelectable = false
        fnControls.statusLabel.maximumNumberOfLines = 2
        fnControls.statusLabel.preferredMaxLayoutWidth = 460
        fnControls.statusLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true
        mainStack.addArrangedSubview(fnControls.statusLabel)

        fnControls.enabledCheckbox.target = self
        fnControls.enabledCheckbox.action = #selector(fnEnabledChanged(_:))
        mainStack.addArrangedSubview(fnControls.enabledCheckbox)

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        fnControls.body = body

        body.addArrangedSubview(hintLabel("An FN key keeps its ordinary binding on a tap and switches layer when held — so making a button an FN key costs you nothing. Its tap action is simply its row in the Combine tab's button list; leave that row unset for a key that does nothing on its own.", lines: 4, width: 460))
        body.addArrangedSubview(hintLabel("Buttons you don't list keep doing what they do without FN. Holding two FN keys at once does nothing at all, rather than guessing which one you meant.", lines: 3, width: 460))
        body.addArrangedSubview(hintLabel("A combination's target is usually a button, but it can also be \"Left/Right Stick Rotate\": while this FN key is held, push that stick all the way out in any direction — that push is itself the first switch — then keep sweeping: clockwise taps Tab, counter-clockwise taps Shift+Tab, once per Degrees/switch of further rotation. The chosen key stays down until the stick is back to center.", lines: 6, width: 460))

        fnControls.layersStack.orientation = .vertical
        fnControls.layersStack.alignment = .leading
        fnControls.layersStack.spacing = 14
        body.addArrangedSubview(fnControls.layersStack)

        fnControls.addLayerButton.target = self
        fnControls.addLayerButton.action = #selector(addFnLayer(_:))
        body.addArrangedSubview(fnControls.addLayerButton)

        // Live feedback, because everything else on this page is a guess until
        // you can see whether a hold actually registered.
        fnControls.liveLabel.isSelectable = false
        fnControls.liveLabel.maximumNumberOfLines = 2
        fnControls.liveLabel.preferredMaxLayoutWidth = 460
        fnControls.liveLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true
        body.addArrangedSubview(fnControls.liveLabel)
        updateFnState(engaged: nil)

        mainStack.addArrangedSubview(body)
        return mainStack
    }

    /// A raw hardware check, independent of whatever is currently bound:
    /// every button on this half, the stick's live deflection, and the
    /// gyro's raw rate — so "is this Joy-Con just worn out" can be answered
    /// by looking rather than by inference from mapped behaviour.
    private func buildTestPage(buttonNames: [String], controls: TestPageControls) -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16

        mainStack.addArrangedSubview(hintLabel("Press and hold each button — a dead one never highlights. At rest, a healthy stick's dot sits dead center and a healthy gyro reads near 0 deg/s on all three axes; drift or noise here is the controller, not the mapping.", lines: 3, width: 460))

        let buttonsStack = NSStackView()
        buttonsStack.orientation = .vertical
        buttonsStack.alignment = .leading
        buttonsStack.spacing = 4
        buttonsStack.addArrangedSubview(sectionTitle("Buttons"))
        for name in buttonNames {
            let stateLabel = NSTextField(labelWithString: "")
            stateLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            stateLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
            controls.buttonLabels[name] = stateLabel
            buttonsStack.addArrangedSubview(row([labeled(name, width: 90), stateLabel]))
        }
        mainStack.addArrangedSubview(buttonsStack)

        let stickStack = NSStackView()
        stickStack.orientation = .vertical
        stickStack.alignment = .leading
        stickStack.spacing = 6
        stickStack.addArrangedSubview(sectionTitle("Stick"))
        controls.stickIndicator.widthAnchor.constraint(equalToConstant: 140).isActive = true
        controls.stickIndicator.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stickStack.addArrangedSubview(controls.stickIndicator)
        controls.stickText.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        controls.stickText.textColor = .secondaryLabelColor
        stickStack.addArrangedSubview(controls.stickText)
        mainStack.addArrangedSubview(stickStack)

        let gyroStack = NSStackView()
        gyroStack.orientation = .vertical
        gyroStack.alignment = .leading
        gyroStack.spacing = 6
        gyroStack.addArrangedSubview(sectionTitle("Gyro — raw, deg/s"))
        controls.gyroText.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        controls.gyroText.textColor = .secondaryLabelColor
        gyroStack.addArrangedSubview(controls.gyroText)
        mainStack.addArrangedSubview(gyroStack)

        return mainStack
    }

    /// Buttons still free to be bound under FN: everything that isn't already
    /// acting as an FN key. Offering a choice that would discard itself on save
    /// is worse than not offering it.
    private func availableFnButtons() -> [String] {
        let reserved = Set(fnControls.layers.compactMap { $0.keyPopup.selectedItem?.representedObject as? String })
        return (leftJoyConButtons + rightJoyConButtons).filter { !reserved.contains($0) }
    }

    /// What a *new* row in this layer should default to: a button the layer
    /// isn't already binding. Two rows on the same button would silently
    /// collapse into one on save, with no sign of which was kept.
    private func nextFnButton(for layer: FnLayerControls) -> String? {
        let taken = Set(layer.rows.compactMap { $0.buttonPopup.selectedItem?.representedObject as? String })
        return availableFnButtons().first { !taken.contains($0) }
    }

    private func addFnLayerControls(key: String?) {
        let layer = FnLayerControls()

        layer.keyPopup.addItem(withTitle: "— none —")
        layer.keyPopup.lastItem?.representedObject = ""
        for name in leftJoyConButtons + rightJoyConButtons {
            layer.keyPopup.addItem(withTitle: name)
            layer.keyPopup.lastItem?.representedObject = name
        }
        layer.keyPopup.target = self
        layer.keyPopup.action = #selector(fnKeyChanged(_:))
        let selected = key ?? ""
        layer.keyPopup.selectItem(at: layer.keyPopup.itemArray.firstIndex { ($0.representedObject as? String) == selected } ?? 0)
        confirmedButtonSelections[ObjectIdentifier(layer.keyPopup)] = selected

        layer.removeButton.target = self
        layer.removeButton.action = #selector(removeFnLayer(_:))

        layer.rowsStack.orientation = .vertical
        layer.rowsStack.alignment = .leading
        layer.rowsStack.spacing = 4

        layer.addRowButton.target = self
        layer.addRowButton.action = #selector(addFnCombination(_:))

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.addArrangedSubview(row([labeled("FN key", width: 60), layer.keyPopup, layer.removeButton]))
        container.addArrangedSubview(layer.rowsStack)
        container.addArrangedSubview(layer.addRowButton)
        layer.container = container

        fnControls.layersStack.addArrangedSubview(container)
        fnControls.layers.append(layer)
    }

    /// `name` is either a button name or one of `stickRotationRowTargets`'
    /// ids; `action` supplies the initial value for a button row, `rotation`
    /// for a stick-rotation row — whichever doesn't apply is nil.
    private func addFnRow(to layer: FnLayerControls, name: String?, action: ButtonAction? = nil, rotation: StickRotationConfig? = nil) {
        let fnRow = FnRow()

        var candidates = availableFnButtons()
        // A saved binding stays selectable even if it is now spoken for
        // elsewhere, so the row shows the truth rather than silently changing.
        if let name = name, !candidates.contains(name), !isStickRotationTarget(name) { candidates.append(name) }
        for candidate in candidates {
            fnRow.buttonPopup.addItem(withTitle: candidate)
            fnRow.buttonPopup.lastItem?.representedObject = candidate
        }
        for target in stickRotationRowTargets {
            fnRow.buttonPopup.addItem(withTitle: target.title)
            fnRow.buttonPopup.lastItem?.representedObject = target.id
        }
        fnRow.buttonPopup.target = self
        fnRow.buttonPopup.action = #selector(fnRowButtonChanged(_:))
        let wanted = name ?? nextFnButton(for: layer) ?? candidates.first
        if let wanted = wanted,
           let index = fnRow.buttonPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == wanted }) {
            fnRow.buttonPopup.selectItem(at: index)
        }
        confirmedButtonSelections[ObjectIdentifier(fnRow.buttonPopup)] = wanted ?? ""

        fnRow.typePopup.target = self
        fnRow.typePopup.action = #selector(buttonTypeChanged(_:))

        fnRow.keyField.placeholderString = "key name, e.g. z"
        fnRow.keyField.delegate = self
        fnRow.keyField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        fnRow.degreesField.placeholderString = "deg/switch"
        fnRow.degreesField.delegate = self
        fnRow.degreesField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        fnRow.recordButtonRef = recordButton(for: fnRow.keyField)

        fnRow.removeButton.target = self
        fnRow.removeButton.action = #selector(removeFnCombination(_:))

        let isRotation = isStickRotationTarget(wanted ?? "")
        configureRowKind(fnRow, isRotation: isRotation)
        if isRotation {
            loadStickRotation(rotation ?? StickRotationConfig(), into: fnRow.typePopup, field: fnRow.degreesField)
            fnRow.degreesField.isEnabled = (rotation ?? StickRotationConfig()).target != .off
        } else {
            loadFnRowAction(action, into: fnRow)
        }

        let container = row([
            labeled("FN +", width: 40), fnRow.buttonPopup,
            fnRow.typePopup, fnRow.keyField, fnRow.recordButtonRef!, fnRow.degreesField, fnRow.removeButton,
        ])
        fnRow.container = container
        layer.rowsStack.addArrangedSubview(container)
        layer.rows.append(fnRow)
    }

    /// Swaps `typePopup`'s meaning between an action kind (button target) and
    /// a rotation target (stick-rotation target), and shows only the field
    /// that kind actually uses. Called whenever a row's target crosses that
    /// boundary — within one kind the existing selection stays valid as-is.
    private func configureRowKind(_ fnRow: FnRow, isRotation: Bool) {
        fnRow.typePopup.removeAllItems()
        fnRow.typePopup.addItems(withTitles: isRotation ? rotationTargetTitles : actionKindTitles)
        fnRow.keyField.isHidden = isRotation
        fnRow.recordButtonRef?.isHidden = isRotation
        fnRow.degreesField.isHidden = !isRotation
    }

    /// Same encoding as the plain button rows, so "Mouse Left" and a recorded
    /// combo behave identically here.
    private func loadFnRowAction(_ action: ButtonAction?, into fnRow: FnRow) {
        if let mouse = action?.mouseButton {
            switch mouse.lowercased() {
            case "right": fnRow.typePopup.selectItem(at: 3)
            case "center", "middle": fnRow.typePopup.selectItem(at: 4)
            default: fnRow.typePopup.selectItem(at: 2)
            }
            fnRow.keyField.isEnabled = false
        } else if let key = action?.key {
            fnRow.typePopup.selectItem(at: 1)
            fnRow.keyField.stringValue = key
            fnRow.keyField.isEnabled = true
        } else {
            fnRow.typePopup.selectItem(at: 0)
            fnRow.keyField.isEnabled = false
        }
    }

    /// Resets a row to its kind's "nothing" state — "None" and an empty key
    /// for a button row, "Off" and no degrees for a rotation row. Used when a
    /// duplicate target claim is resolved in favor of a different row.
    private func resetFnRowToNone(_ fnRow: FnRow) {
        fnRow.typePopup.selectItem(at: 0)
        fnRow.keyField.stringValue = ""
        fnRow.keyField.isEnabled = false
        fnRow.degreesField.stringValue = ""
        fnRow.degreesField.isEnabled = false
    }

    private func clearFnLayers() {
        for layer in fnControls.layers {
            layer.container?.removeFromSuperview()
        }
        fnControls.layers.removeAll()
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
    ///
    /// The page is a *profile editor*: the holding-mode control at the top
    /// picks which of the two stored profiles everything below it belongs to,
    /// rather than toggling a single behavior flag. That is why it is a
    /// segmented control and not another popup in the list — it governs the
    /// whole page, including the button mapping.
    private func buildCombinePage() -> NSView {
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 20

        combineStatusLabel.isSelectable = false
        combineStatusLabel.maximumNumberOfLines = 2
        combineStatusLabel.preferredMaxLayoutWidth = 400
        combineStatusLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true
        mainStack.addArrangedSubview(combineStatusLabel)
        updateConnectionState(leftConnected: false, rightConnected: false)

        let modeStack = NSStackView()
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 6
        modeStack.addArrangedSubview(sectionTitle("Holding Mode"))
        combineModeSegmented.target = self
        combineModeSegmented.action = #selector(combineModeChanged(_:))
        combineModeSegmented.selectedSegment = 0
        modeStack.addArrangedSubview(combineModeSegmented)
        modeStack.addArrangedSubview(hintLabel("Each mode keeps its own choice of which gyro drives the cursor. Everything else — buttons, sticks, and each gyro's own tuning — comes from the Left/Right Joy-Con tabs and doesn't change here.", lines: 4))
        mainStack.addArrangedSubview(modeStack)

        let sourceStack = NSStackView()
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 8
        sourceStack.addArrangedSubview(sectionTitle("Gyro Source"))
        sourceStack.addArrangedSubview(gyroSourceOption(
            .left, title: "Left Joy-Con only",
            hint: "Tuned from the Left Joy-Con tab. The right Joy-Con's gyro stays off; its buttons and stick work as normal."
        ))
        sourceStack.addArrangedSubview(gyroSourceOption(
            .right, title: "Right Joy-Con only",
            hint: "Tuned from the Right Joy-Con tab. The left Joy-Con's gyro stays off; its buttons and stick work as normal."
        ))
        let fusedOption = gyroSourceOption(
            .fused, title: "Both, fused — needs the grip",
            hint: "One gyro, fed by both IMUs: they cover each other's dropped reports and agree on when the pair is still, so aim holds steadier. Tuned from the Right Joy-Con tab — the second Joy-Con places itself against whatever axes that picks, so there's nothing extra to configure. Only valid when the two are one rigid body; don't pick this holding them one per hand."
        )
        sourceStack.addArrangedSubview(fusedOption)
        mainStack.addArrangedSubview(sourceStack)

        let fusionStack = NSStackView()
        fusionStack.orientation = .vertical
        fusionStack.alignment = .leading
        fusionStack.spacing = 6
        fusionStack.addArrangedSubview(sectionTitle("Fusion Calibration"))
        fusionStack.addArrangedSubview(hintLabel(
            "How the second Joy-Con's IMU sits relative to the first, learned by turning the grip every way once (left/right, up/down, tilt). Saving it means fusing is ready immediately every session after, instead of having to be worked out again by waving the grip about.",
            lines: 4
        ))
        combineFusionStatusLabel.isSelectable = false
        combineFusionStatusLabel.maximumNumberOfLines = 2
        combineFusionStatusLabel.preferredMaxLayoutWidth = 400
        combineFusionStatusLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true
        combineFusionStatusLabel.textColor = .secondaryLabelColor
        fusionStack.addArrangedSubview(combineFusionStatusLabel)

        saveCalibrationButton.target = self
        saveCalibrationButton.action = #selector(saveFusionCalibration)
        clearCalibrationButton.target = self
        clearCalibrationButton.action = #selector(clearFusionCalibration)
        fusionStack.addArrangedSubview(row([saveCalibrationButton, clearCalibrationButton]))
        mainStack.addArrangedSubview(fusionStack)
        updateFusionState(status: .inactive, learned: FusionAlignment())

        return mainStack
    }

    /// A wrapping explanatory label. `NSTextField(labelWithString:)` — what
    /// `labeled()` builds — is single-line: raising maximumNumberOfLines on it
    /// isn't enough on its own, the text just gets clipped at the first line.
    /// These need the wrapping variant plus a width to wrap against.
    private func hintLabel(_ text: String, lines: Int = 2, color: NSColor = .secondaryLabelColor, width: CGFloat = 400) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.textColor = color
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// A radio plus its own explanation. Radio auto-grouping only covers
    /// buttons that share a superview, which these don't once each one is
    /// paired with a hint — so exclusivity is enforced in the action instead.
    private func gyroSourceOption(_ source: CombineGyroSource, title: String, hint: String) -> NSView {
        let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(gyroSourceChanged(_:)))
        combineSourceRadios[source] = radio

        let hintText = hintLabel(hint, lines: 4, width: 382)
        if source == .fused { combineFusedRadioHint = hintText }

        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(radio)
        stack.addArrangedSubview(row([indent, hintText]))
        return stack
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

    private func buildStickSection(stick: StickControls, title: String = "Stick") -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(sectionTitle(title))

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

        stack.addArrangedSubview(hintLabel("Rotate-to-switch-tabs lives on the FN tab now — sweeping this stick in a circle only does something while an FN key is held, so configure it there.", width: 380))

        stick.debugLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        stick.debugLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(stick.debugLabel)

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
        stack.addArrangedSubview(hintLabel("Physical axis identity varies by grip — try combinations here and watch the cursor to find the right one.", width: 380))

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
        isReloading = true
        loadFn(config.combine.fn)
        loadButtons(config.buttons, into: buttonRows)
        loadStick(config.leftStick, into: leftStickControls)
        loadStick(config.rightStick, into: rightStickControls)
        loadGyro(config.leftGyro, into: leftGyroControls)
        loadGyro(config.rightGyro, into: rightGyroControls)

        combineMode = config.combine.mode
        combineModeSegmented.selectedSegment = combineMode == .gripMounted ? 1 : 0
        isReloading = false

        loadCombineProfile(config.combine[combineMode])
    }

    /// Fills the Combine page from one profile: which gyro drives the cursor,
    /// plus the calibration fusing has learned or been given.
    private func loadCombineProfile(_ profile: CombineProfile) {
        isReloading = true
        for (source, radio) in combineSourceRadios {
            radio.state = source == profile.gyroSource ? .on : .off
        }
        combineSavedAlignment = profile.fusionAlignment
        isReloading = false

        applyCombineLayout()
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

    private func loadFn(_ fn: FnConfig) {
        fnControls.enabledCheckbox.state = fn.enabled ? .on : .off
        clearFnLayers()
        // Every FN key has to exist before any combination row is built: the
        // rows offer "buttons not already acting as FN", and a key that hasn't
        // been created yet doesn't count as taken.
        for layer in fn.layers {
            addFnLayerControls(key: layer.key)
        }
        for (index, layer) in fn.layers.enumerated() where index < fnControls.layers.count {
            // Canonical button order rather than dictionary order, so the list
            // doesn't reshuffle itself every time it is reloaded.
            for name in leftJoyConButtons + rightJoyConButtons {
                guard let action = layer.bindings[name], name != (layer.key ?? "") else { continue }
                addFnRow(to: fnControls.layers[index], name: name, action: action)
            }
            // A rotation row only appears if it's actually configured — same
            // reasoning as a button binding: a stick left at .off keeps doing
            // whatever it already does, rather than cluttering every layer
            // with two rows nobody set.
            if layer.leftStickRotation.target != .off {
                addFnRow(to: fnControls.layers[index], name: leftStickRotateTargetID, rotation: layer.leftStickRotation)
            }
            if layer.rightStickRotation.target != .off {
                addFnRow(to: fnControls.layers[index], name: rightStickRotateTargetID, rotation: layer.rightStickRotation)
            }
        }
        applyFnEnabled()
    }

    private func applyFnEnabled() {
        let enabled = fnControls.enabledCheckbox.state == .on
        fnControls.body?.alphaValue = enabled ? 1.0 : 0.45
        setControlsEnabled(in: fnControls.body ?? NSStackView(), enabled)

        // `setControlsEnabled` is a blanket pass, so it re-enables fields that
        // only apply to some other selection of the same row — a Mouse/None
        // button row's key field, or an Off rotation row's degrees field —
        // which `readFn` then ignores anyway, but shouldn't look editable.
        for layer in fnControls.layers {
            for fnRow in layer.rows {
                let target = fnRow.buttonPopup.selectedItem?.representedObject as? String ?? ""
                if isStickRotationTarget(target) {
                    fnRow.degreesField.isEnabled = enabled && fnRow.typePopup.indexOfSelectedItem != 0
                } else {
                    fnRow.keyField.isEnabled = enabled && fnRow.typePopup.indexOfSelectedItem == 1
                }
            }
        }
    }

    private func readFn() -> FnConfig {
        var layers: [FnLayer] = []
        var claimed: Set<String> = []

        for layerControls in fnControls.layers {
            let key = layerControls.keyPopup.selectedItem?.representedObject as? String ?? ""
            // Two FN layers on the same button would be indistinguishable, so
            // the later one keeps its combinations but loses the key.
            let unique = key.isEmpty || claimed.contains(key) ? "" : key
            if !unique.isEmpty { claimed.insert(unique) }

            var bindings: [String: ButtonAction] = [:]
            var leftRotation = StickRotationConfig()
            var rightRotation = StickRotationConfig()

            for fnRow in layerControls.rows {
                guard let target = fnRow.buttonPopup.selectedItem?.representedObject as? String else { continue }

                if target == leftStickRotateTargetID {
                    leftRotation = readStickRotation(popup: fnRow.typePopup, field: fnRow.degreesField)
                    continue
                }
                if target == rightStickRotateTargetID {
                    rightRotation = readStickRotation(popup: fnRow.typePopup, field: fnRow.degreesField)
                    continue
                }

                // FN + itself is nothing.
                guard target != unique else { continue }
                switch fnRow.typePopup.indexOfSelectedItem {
                case 1:
                    let combo = fnRow.keyField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
                    highlightIfUnknown(fnRow.keyField, text: combo)
                    if !combo.isEmpty && isFullyKnown(combo) {
                        bindings[target] = ButtonAction(key: combo, mouseButton: nil)
                    }
                case 2: bindings[target] = ButtonAction(key: nil, mouseButton: "left")
                case 3: bindings[target] = ButtonAction(key: nil, mouseButton: "right")
                case 4: bindings[target] = ButtonAction(key: nil, mouseButton: "center")
                default: fnRow.keyField.textColor = .labelColor
                }
            }

            layers.append(FnLayer(
                key: unique.isEmpty ? nil : unique, bindings: bindings,
                leftStickRotation: leftRotation, rightStickRotation: rightRotation
            ))
        }

        return FnConfig(enabled: fnControls.enabledCheckbox.state == .on, layers: layers)
    }

    private func loadStickRotation(_ rotation: StickRotationConfig, into popup: NSPopUpButton, field: NSTextField) {
        switch rotation.target {
        case .off: popup.selectItem(at: 0)
        case .ctrl: popup.selectItem(at: 1)
        case .option: popup.selectItem(at: 2)
        case .command: popup.selectItem(at: 3)
        }
        field.stringValue = String(rotation.degreesPerStep)
    }

    private func readStickRotation(popup: NSPopUpButton, field: NSTextField) -> StickRotationConfig {
        let target: StickRotationTarget
        switch popup.indexOfSelectedItem {
        case 1: target = .ctrl
        case 2: target = .option
        case 3: target = .command
        default: target = .off
        }
        // Floored the same way the tracker floors it, so what's displayed
        // matches what's actually in effect rather than silently diverging.
        let degreesPerStep = max(5, Double(field.stringValue) ?? 90)
        return StickRotationConfig(target: target, degreesPerStep: degreesPerStep)
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
        guard !isReloading else { return }

        var newConfig = AppConfig()
        newConfig.buttons = readButtons(from: buttonRows)
        newConfig.leftStick = readStick(leftStickControls)
        newConfig.rightStick = readStick(rightStickControls)
        newConfig.leftGyro = readGyro(leftGyroControls)
        newConfig.rightGyro = readGyro(rightGyroControls)

        // Start from the stored combine settings so the profile that isn't on
        // screen survives — only the visible one is read back from controls.
        var combine = config.combine
        combine.mode = combineMode
        combine.fn = readFn()
        combine[combineMode] = readCombineProfile()
        newConfig.combine = combine

        config = newConfig
        onSave(newConfig)
    }

    private func readCombineProfile() -> CombineProfile {
        var source = combineSourceRadios.first { $0.value.state == .on }?.key ?? .right
        // The fused radio is disabled outside the grip profile, but a stale
        // selection must not survive into one where fusing is meaningless.
        if combineMode == .separate && source == .fused { source = .right }

        return CombineProfile(gyroSource: source, fusionAlignment: combineSavedAlignment)
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
        return StickConfig(
            mode: mode,
            speed: Double(controls.speedField.stringValue) ?? 10.0,
            keys: keys
        )
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
        // Belt and suspenders alongside the tab-switch handler below: closing
        // the window while a test tab happens to be selected must not leave
        // that controller's real output suppressed with no tab left to leave.
        onTestModeChanged(false, false)
    }

    // MARK: - NSTabViewDelegate

    /// Real output is suppressed only while a Left/Right Test tab is the one
    /// actually on screen — everything else (including switching to a
    /// different tab) restores it.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let identifier = tabViewItem?.identifier as? String
        onTestModeChanged(identifier == "leftTest", identifier == "rightTest")
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        commit()
    }

    // MARK: - Actions

    @objc private func buttonTypeChanged(_ sender: NSPopUpButton) {
        if let r = buttonRows.first(where: { $0.typePopup === sender }) {
            r.keyField.isEnabled = sender.indexOfSelectedItem == 1
            commit()
            return
        }
        let fnRows = fnControls.layers.flatMap { $0.rows }
        guard let fnRow = fnRows.first(where: { $0.typePopup === sender }) else { return }
        let target = fnRow.buttonPopup.selectedItem?.representedObject as? String ?? ""
        if isStickRotationTarget(target) {
            fnRow.degreesField.isEnabled = sender.indexOfSelectedItem != 0
        } else {
            fnRow.keyField.isEnabled = sender.indexOfSelectedItem == 1
        }
        commit()
    }

    @objc private func fnEnabledChanged(_ sender: NSButton) {
        applyFnEnabled()
        commit()
    }

    /// Moving an FN key changes which buttons are still free to bind under it,
    /// so the lists are rebuilt from the saved result rather than left showing
    /// choices that would be dropped on the next save.
    ///
    /// Two layers keyed to the same physical button is meaningless — holding
    /// it can't mean two different layers at once — and `readFn()` already
    /// has to pick one silently if this is somehow reached anyway (the later
    /// layer keeps its combinations but loses the key). Checking here first
    /// means that never happens without the user having said yes to it.
    @objc private func fnKeyChanged(_ sender: NSPopUpButton) {
        guard let layer = fnControls.layers.first(where: { $0.keyPopup === sender }) else { return }
        let newValue = sender.selectedItem?.representedObject as? String ?? ""

        if !newValue.isEmpty,
           let conflict = fnControls.layers.first(where: { $0 !== layer && ($0.keyPopup.selectedItem?.representedObject as? String) == newValue }) {
            guard confirmButtonCollision(buttonName: newValue, existingUse: "another FN key") else {
                selectButton(confirmedButtonSelections[ObjectIdentifier(sender)] ?? "", in: sender)
                return
            }
            selectButton("", in: conflict.keyPopup)
            confirmedButtonSelections[ObjectIdentifier(conflict.keyPopup)] = ""
        }

        confirmedButtonSelections[ObjectIdentifier(sender)] = newValue
        commit()
        let fn = readFn()
        isReloading = true
        loadFn(fn)
        isReloading = false
    }

    /// A row's target popup offers every button not already claimed as an FN
    /// *key* (see `availableFnButtons`), plus the two stick-rotation targets,
    /// but nothing stops picking one a sibling row in the same layer already
    /// targets — `readFn()` would then silently keep whichever row it
    /// iterates last (see `nextFnButton`'s note on exactly this). Checked
    /// here instead of left to collapse quietly.
    @objc private func fnRowButtonChanged(_ sender: NSPopUpButton) {
        guard let layer = fnControls.layers.first(where: { $0.rows.contains { $0.buttonPopup === sender } }),
              let fnRow = layer.rows.first(where: { $0.buttonPopup === sender }) else { return }
        let newValue = sender.selectedItem?.representedObject as? String ?? ""
        let previousValue = confirmedButtonSelections[ObjectIdentifier(sender)] ?? ""

        if !newValue.isEmpty,
           let conflict = layer.rows.first(where: { $0 !== fnRow && ($0.buttonPopup.selectedItem?.representedObject as? String) == newValue }) {
            guard confirmButtonCollision(buttonName: fnRowTargetDisplayName(newValue), existingUse: "another combination under this FN key") else {
                selectButton(previousValue, in: sender)
                return
            }
            resetFnRowToNone(conflict)
        }

        // Crossing between a real button and a stick-rotation target changes
        // what the row's type popup even means (action kind vs. rotation
        // target), so it's rebuilt from scratch rather than kept as whatever
        // it showed for the old kind.
        if isStickRotationTarget(newValue) != isStickRotationTarget(previousValue) {
            configureRowKind(fnRow, isRotation: isStickRotationTarget(newValue))
        }

        confirmedButtonSelections[ObjectIdentifier(sender)] = newValue
        commit()
    }

    private func fnRowTargetDisplayName(_ id: String) -> String {
        stickRotationRowTargets.first { $0.id == id }?.title ?? id
    }

    /// The same physical controller button (or stick-rotation target)
    /// claimed twice is ambiguous — a single press or sweep can't mean two
    /// different things — so this asks before letting the second claim
    /// quietly win. This is about the controller's own input identity only;
    /// different bindings sharing the same *keyboard* output key is
    /// unrelated and perfectly fine.
    private func confirmButtonCollision(buttonName: String, existingUse: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\"\(buttonName)\" is already used"
        alert.informativeText = "Already assigned to \(existingUse). Continuing clears that assignment so only this one uses \"\(buttonName)\"."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func selectButton(_ name: String, in popup: NSPopUpButton) {
        guard let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == name }) else { return }
        popup.selectItem(at: index)
    }

    @objc private func addFnLayer(_ sender: NSButton) {
        addFnLayerControls(key: availableFnButtons().first)
        applyFnEnabled()
        commit()
    }

    @objc private func removeFnLayer(_ sender: NSButton) {
        guard let index = fnControls.layers.firstIndex(where: { $0.removeButton === sender }) else { return }
        fnControls.layers[index].container?.removeFromSuperview()
        fnControls.layers.remove(at: index)
        commit()
    }

    @objc private func addFnCombination(_ sender: NSButton) {
        guard let layer = fnControls.layers.first(where: { $0.addRowButton === sender }) else { return }
        addFnRow(to: layer, name: nil, action: nil)
        applyFnEnabled()
        commit()
    }

    @objc private func removeFnCombination(_ sender: NSButton) {
        for layer in fnControls.layers {
            guard let index = layer.rows.firstIndex(where: { $0.removeButton === sender }) else { continue }
            layer.rows[index].container?.removeFromSuperview()
            layer.rows.remove(at: index)
        }
        commit()
    }

    @objc private func settingsChanged(_ sender: Any) {
        commit()
    }

    @objc private func combineModeChanged(_ sender: NSSegmentedControl) {
        let newMode: CombineMode = sender.selectedSegment == 1 ? .gripMounted : .separate
        guard newMode != combineMode else { return }

        // Flush what's on screen into the profile it still belongs to *before*
        // switching, or the outgoing profile ends up holding the incoming
        // one's values — every edit made before the switch silently lost.
        commit()
        combineMode = newMode
        loadCombineProfile(config.combine[newMode])
        commit()
    }

    @objc private func gyroSourceChanged(_ sender: NSButton) {
        for radio in combineSourceRadios.values {
            radio.state = radio === sender ? .on : .off
        }
        applyCombineLayout()
        commit()
    }

    // MARK: - Combine page layout

    /// Fusing only makes sense clipped into a grip — one rigid body, two
    /// IMUs — so the radio is disabled (dimmed, not hidden, so the page
    /// doesn't change shape under the pointer) outside that holding mode.
    private func applyCombineLayout() {
        let isGrip = combineMode == .gripMounted
        combineSourceRadios[.fused]?.isEnabled = isGrip
        combineFusedRadioHint?.textColor = isGrip ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// Reflects what the fusion is actually doing. Whether the second Joy-Con
    /// has been placed is the one thing about fusing that can't be read off the
    /// cursor, so it gets said in words.
    func updateFusionState(status: FusionStatus, learned: FusionAlignment) {
        latestLearnedAlignment = learned

        switch status {
        case .inactive:
            // Worth seeing even with nothing connected: it says whether this
            // profile is ready to fuse the moment the pair shows up.
            if let saved = combineSavedAlignment, !saved.isEmpty {
                combineFusionStatusLabel.stringValue = "Saved calibration: \(saved.description(horizontalAxis: fusedAxisIndex(.horizontal), verticalAxis: fusedAxisIndex(.vertical)))"
            } else {
                combineFusionStatusLabel.stringValue = "No saved calibration — the second Joy-Con will place itself once you turn the grip every way."
            }
            combineFusionStatusLabel.textColor = .secondaryLabelColor
        case .learning:
            combineFusionStatusLabel.stringValue = "◌ Waiting for motion to place the second Joy-Con — turn the grip left/right, up/down, and tilt it. Right Joy-Con only for now."
            combineFusionStatusLabel.textColor = .secondaryLabelColor
        case .partial(let placed):
            combineFusionStatusLabel.stringValue = "◑ \(placed) of 3 axes placed — keep turning the grip: left/right, up/down, and tilt it side to side."
            combineFusionStatusLabel.textColor = .secondaryLabelColor
        case .aligned(let saved):
            combineFusionStatusLabel.stringValue = saved
                ? "● Fusing on the saved calibration — no warm-up needed."
                : "● Placed and fusing. Save it and the next session won't have to work it out again."
            combineFusionStatusLabel.textColor = .systemGreen
        case .suspended:
            combineFusionStatusLabel.stringValue = "⚠ The two Joy-Cons disagree about how they're moving — is one out of the grip? Running on the right Joy-Con alone."
            combineFusionStatusLabel.textColor = .systemOrange
        }

        // Nothing to save until something has been worked out, and nothing to
        // save if it's already what's stored.
        saveCalibrationButton.isEnabled = !latestLearnedAlignment.isEmpty
            && latestLearnedAlignment != combineSavedAlignment
        clearCalibrationButton.isEnabled = combineSavedAlignment.map { !$0.isEmpty } ?? false
    }

    /// Live x/y plus a running rotation-step count, so "did I actually enable
    /// this on the profile that's running" and "is my sweep even wide enough"
    /// can be answered by watching a number instead of guessing from behaviour.
    /// `nil` means that physical stick's controller isn't connected right now.
    func updateStickDebugState(left: StickDebugState?, right: StickDebugState?) {
        applyStickDebug(left, to: leftStickControls)
        applyStickDebug(right, to: rightStickControls)
    }

    private func applyStickDebug(_ state: StickDebugState?, to controls: StickControls) {
        let text: String
        let color: NSColor
        if let state = state {
            let engaged = (state.x * state.x + state.y * state.y).squareRoot() >= 0.5
            text = String(format: "live: x=%+.2f y=%+.2f%@  |  rotations fired: %d",
                           state.x, state.y, engaged ? " (past deadzone)" : "", state.rotationSteps)
            color = engaged ? .systemGreen : .secondaryLabelColor
        } else {
            text = "live: not connected"
            color = .secondaryLabelColor
        }
        controls.debugLabel.stringValue = text
        controls.debugLabel.textColor = color
    }

    /// One side's diagnostic page: which buttons are down, the stick's live
    /// dot, and the gyro's raw rate. `nil` means that controller isn't
    /// connected — shown as such rather than left on stale numbers.
    func updateTestPage(isLeft: Bool, held: Set<String>, stick: StickDebugState?, gyro: SIMD3<Double>?) {
        let controls = isLeft ? leftTestControls : rightTestControls

        for (name, label) in controls.buttonLabels {
            if held.contains(name) {
                label.stringValue = "● held"
                label.textColor = .systemGreen
            } else {
                label.stringValue = ""
            }
        }

        if let stick = stick {
            controls.stickIndicator.position = CGPoint(x: stick.x, y: stick.y)
            controls.stickText.stringValue = String(format: "x=%+.2f  y=%+.2f", stick.x, stick.y)
        } else {
            controls.stickIndicator.position = .zero
            controls.stickText.stringValue = "not connected"
        }

        if let gyro = gyro {
            controls.gyroText.stringValue = String(format: "x=%+6.1f  y=%+6.1f  z=%+6.1f", gyro.x, gyro.y, gyro.z)
        } else {
            controls.gyroText.stringValue = "not connected"
        }
    }

    /// Shows whether an FN key is being held right now. Hold one while this
    /// page is open and it says so — which separates "the hold didn't register"
    /// from "the binding didn't apply", the two things that look identical from
    /// the outside.
    func updateFnState(engaged: String?) {
        if let engaged = engaged {
            fnControls.liveLabel.stringValue = "● Holding \(engaged) — its combinations are live right now."
            fnControls.liveLabel.textColor = .systemGreen
        } else {
            fnControls.liveLabel.stringValue = "Hold an FN key on a connected controller and this line will say so."
            fnControls.liveLabel.textColor = .secondaryLabelColor
        }
    }

    private enum FusedAxis { case horizontal, vertical }

    private func fusedAxisIndex(_ axis: FusedAxis) -> Int {
        // Fusing tunes as the right half's own gyro (see `CombineProfile`), so
        // its axis choice is what a saved calibration is described against.
        let popup = axis == .horizontal ? rightGyroControls.horizontalAxisPopup : rightGyroControls.verticalAxisPopup
        let index = popup.indexOfSelectedItem
        return (index >= 0 && index < 3) ? index : (axis == .horizontal ? 0 : 1)
    }

    @objc private func saveFusionCalibration() {
        guard !latestLearnedAlignment.isEmpty else { return }
        combineSavedAlignment = latestLearnedAlignment
        commit()
        updateFusionState(status: .aligned(saved: true), learned: latestLearnedAlignment)
    }

    @objc private func clearFusionCalibration() {
        combineSavedAlignment = nil
        commit()
        updateFusionState(status: .inactive, learned: latestLearnedAlignment)
    }

    private func setControlsEnabled(in view: NSView, _ enabled: Bool) {
        for subview in view.subviews {
            // Labels are NSControls too; the section's alpha already dims
            // those, and disabling them on top of it reads as broken.
            let isLabel = (subview as? NSTextField).map { !$0.isEditable } ?? false
            if let control = subview as? NSControl, !isLabel {
                control.isEnabled = enabled
            }
            setControlsEnabled(in: subview, enabled)
        }
    }

    // MARK: - Connection state

    /// Told by `AppController` which halves are actually plugged in, so the
    /// page can say whether it is the one describing them — the alternative is
    /// a page whose settings quietly apply to nothing.
    func updateConnectionState(leftConnected: Bool, rightConnected: Bool) {
        switch (leftConnected, rightConnected) {
        case (true, true):
            combineStatusLabel.stringValue = "● Both Joy-Cons connected — these settings are the ones running."
            combineStatusLabel.textColor = .systemGreen
        case (true, false):
            combineStatusLabel.stringValue = "○ Only the Left Joy-Con is connected — the Left Joy-Con tab is the one running."
            combineStatusLabel.textColor = .secondaryLabelColor
        case (false, true):
            combineStatusLabel.stringValue = "○ Only the Right Joy-Con is connected — the Right Joy-Con tab is the one running."
            combineStatusLabel.textColor = .secondaryLabelColor
        case (false, false):
            combineStatusLabel.stringValue = "○ No Joy-Con connected."
            combineStatusLabel.textColor = .secondaryLabelColor
        }

        // FN works on either a lone half or a combined pair, so the page just
        // says whether anything is connected to try it on.
        if leftConnected || rightConnected {
            fnControls.statusLabel.stringValue = "● FN keys are in effect."
            fnControls.statusLabel.textColor = .systemGreen
        } else {
            fnControls.statusLabel.stringValue = "○ Connect a Joy-Con to try an FN key."
            fnControls.statusLabel.textColor = .secondaryLabelColor
        }
    }
}
