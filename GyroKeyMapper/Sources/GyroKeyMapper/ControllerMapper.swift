import AppKit
import JoyConSwift
import QuartzCore
import SceneKit
import simd

/// Wraps one connected JoyConSwift.Controller and drives keyboard/mouse
/// output from its buttons, sticks, and gyro according to `config`.
///
/// Threading, which the smoothness depends on:
///
/// - JoyConSwift's IOHID read thread calls the handlers below. They may only
///   do cheap, non-blocking work: update state, accumulate numbers, hand work
///   off. Posting a CGEvent (a round trip to the window server) or touching
///   AppKit there stalls report delivery, and IOHID's per-device value queue
///   is shallow enough that a stall of a few tens of milliseconds drops
///   reports outright — which is what "the gyro keeps cutting out" looks like.
/// - `renderQueue` owns all mouse output and all of the gyro's filter and
///   orientation state; it ticks on a timer independent of however irregularly
///   reports actually arrive.
/// - `KeyboardOutput` owns all keyboard output on its own queue.
///
/// Nothing runs on the main thread, so opening Settings can't hitch the cursor.
final class ControllerMapper {
    let controller: JoyConSwift.Controller

    private let configLock = NSLock()
    private var storedConfig: AppConfig
    private let combine: CombineCoordinator
    /// What this controller currently does — resolved once whenever the config
    /// or the set of connected controllers changes, rather than re-derived on
    /// every report.
    private var mapping: ActiveMapping

    var config: AppConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return storedConfig
        }
        set {
            configLock.lock()
            storedConfig = newValue
            configLock.unlock()
            refreshMapping()
        }
    }

    /// Called when the *other* Joy-Con connects or disconnects. Which buttons
    /// and which gyro settings apply depends on whether the pair is complete,
    /// so completing or breaking it re-resolves this half too.
    func combineStateChanged() {
        refreshMapping()
    }

    // MARK: - Test mode

    private let testModeLock = NSLock()
    private var testModeSuppressed = false

    /// While this half's test page is open, every handler below still
    /// publishes what the test page shows (held buttons, stick x/y, raw
    /// gyro) but stops short of producing any real output — otherwise a
    /// button press meant only to light up on screen would also fire
    /// whatever it's actually bound to, system-wide, at the same time.
    private var isTestModeSuppressed: Bool {
        testModeLock.lock()
        defer { testModeLock.unlock() }
        return testModeSuppressed
    }

    /// Told by the settings window whenever its Left/Right Test tab becomes
    /// (or stops being) the selected one, and unconditionally on window
    /// close — so leaving the test page by any route restores real mapping.
    func setTestModeSuppressed(_ suppressed: Bool) {
        testModeLock.lock()
        let changed = testModeSuppressed != suppressed
        testModeSuppressed = suppressed
        testModeLock.unlock()
        guard changed else { return }
        // Whatever a real press was mid-producing when the test page opened
        // must not outlive that press — same cleanup `refreshMapping` does
        // for a remap, for the same reason.
        KeyboardOutput.shared.releaseAll(ownedBy: ObjectIdentifier(self))
        inputLock.lock()
        session.reset()
        leftRotationTracker.reset()
        rightRotationTracker.reset()
        leftHeldRotationKey = nil
        rightHeldRotationKey = nil
        inputLock.unlock()
    }

    private func refreshMapping() {
        // Snapshot the shared state before taking our own lock — the two are
        // never held at once, so there is no ordering to get wrong.
        let combineState = combine.snapshot()
        configLock.lock()
        mapping = Self.resolveMapping(for: controller.type, config: storedConfig, combineState: combineState)
        configLock.unlock()
        // A button that just got remapped would otherwise never see its
        // release and stay held down system-wide.
        KeyboardOutput.shared.releaseAll(ownedBy: ObjectIdentifier(self))
        inputLock.lock()
        session.reset()
        leftRotationTracker.reset()
        rightRotationTracker.reset()
        leftHeldRotationKey = nil
        rightHeldRotationKey = nil
        inputLock.unlock()
        // The learned placement of the other IMU is relative to *these* axis
        // choices, so choosing again throws it away rather than carrying a
        // stale answer into a different question.
        renderQueue.async { self.alignment.reset() }
    }

    /// Works out which button map and gyro settings are in force, and what part
    /// this half plays in producing cursor motion. Depends on nothing but the
    /// controller's side, so it is `static`: the decision can be checked
    /// without a controller to hand.
    static func resolveMapping(for type: JoyCon.ControllerType, config: AppConfig, combineState: CombineCoordinator.Snapshot) -> ActiveMapping {
        let isLeft = type == .JoyConL

        guard combineState.isCombined else {
            return ActiveMapping(
                gyro: GyroRuntime(isLeft ? config.leftGyro : config.rightGyro),
                role: .driver,
                buttons: config.buttons,
                // FN doesn't require both halves — a lone Joy-Con can hold its
                // own FN key and drive its own stick's rotation layer. `combine`
                // already tracks this config and its hold-state independent of
                // `isCombined` (see `CombineCoordinator`), so it's just a matter
                // of not discarding it here.
                fn: combineState.fn,
                leftStick: config.leftStick,
                rightStick: config.rightStick
            )
        }

        let profile = combineState.profile
        let role = CombineCoordinator.role(for: type, isCombined: true, source: profile.gyroSource)

        // Fusing tunes as a single gyro, and that single gyro is always the
        // right half's own settings: `role(for:)` always makes the right half
        // the fused driver, so there's no separate "fused" tuning to keep in
        // sync with it — see `CombineProfile`. Where the second IMU's axes
        // sit relative to those is learned at runtime rather than configured
        // — see `GyroAlignment`.
        let gyro: GyroRuntime
        switch role {
        case .driver:
            gyro = GyroRuntime(profile.gyroSource == .left ? config.leftGyro : config.rightGyro)
        case .contributor:
            // Only reachable while fused: this half doesn't drive the cursor,
            // but still has to sample and feed the fusion bus every tick,
            // regardless of whether its own standalone gyro happens to be on.
            var runtime = GyroRuntime(GyroConfig())
            runtime.enabled = true
            gyro = runtime
        case .off:
            gyro = GyroRuntime(GyroConfig())
        }

        return ActiveMapping(
            gyro: gyro,
            role: role,
            // Buttons and sticks don't change with combine state — only which
            // gyro drives the cursor does. See `CombineProfile`.
            buttons: config.buttons,
            fn: combineState.fn,
            leftStick: config.leftStick,
            rightStick: config.rightStick,
            savedAlignment: profile.fusionAlignment,
            isCombined: true,
            isFused: profile.gyroSource == .fused
        )
    }

    // MARK: - Shared state (written on the IOHID thread, drained on renderQueue)

    private let inputLock = NSLock()
    private var sampleSum = SIMD3<Double>()
    private var sampleCount = 0
    private var activationHeld = false
    private var needsRecenter = false
    private var pendingMouseDx: CGFloat = 0 // CGEvent space: +x right, +y down
    private var pendingMouseDy: CGFloat = 0
    private var pendingScrollX: CGFloat = 0
    private var pendingScrollY: CGFloat = 0

    // MARK: - renderQueue-only state

    private let renderQueue = DispatchQueue(label: "GyroKeyMapper.mouse-output", qos: .userInteractive)
    private var renderTimer: DispatchSourceTimer?
    private static let sharedEventSource = CGEventSource(stateID: .hidSystemState)

    private var lastTickTime: CFTimeInterval = 0
    private var lastSampleTime: CFTimeInterval = 0
    private var targetRateH: Double = 0
    private var targetRateV: Double = 0
    private var filterH = OneEuroFilter()
    private var filterV = OneEuroFilter()

    // Joy-Con gyros have a real zero-offset even after factory calibration, and
    // a couple of deg/s integrated over a few seconds of holding is enough to
    // walk the cursor across the screen on its own. Learn the offset from
    // stretches where the controller is essentially still, and never from
    // stretches where it isn't, so genuine slow aiming is left alone.
    private var biasH: Double = 0
    private var biasV: Double = 0
    private let stillnessThreshold: Double = 3.0 // deg/s — above any plausible residual offset
    private let biasTimeConstant: Double = 2.0   // seconds

    /// renderQueue-only, like the filters and the orientation they feed.
    private var fusion: GyroFusion
    private var alignment = GyroAlignment()

    private let statusLock = NSLock()
    private var storedFusionStatus: FusionStatus = .inactive
    private var storedLearnedAlignment = FusionAlignment()

    /// How fusing is getting on, for the settings window to show. Whether the
    /// second Joy-Con has been placed yet is the one part of this the user
    /// can't tell by watching the cursor.
    var fusionStatus: FusionStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedFusionStatus
    }

    private func publishFusionStatus(_ status: FusionStatus) {
        statusLock.lock()
        if storedFusionStatus != status { storedFusionStatus = status }
        statusLock.unlock()
    }

    /// What has been worked out live, for the settings window to offer to save.
    var learnedAlignment: FusionAlignment {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedLearnedAlignment
    }

    private func publishLearnedAlignment(_ alignment: FusionAlignment) {
        statusLock.lock()
        if storedLearnedAlignment != alignment { storedLearnedAlignment = alignment }
        statusLock.unlock()
    }

    private var storedLeftStickDebug = StickDebugState()
    private var storedRightStickDebug = StickDebugState()

    /// Live readout for the settings window: lets "is this stick even being
    /// read" and "did that sweep actually register as a rotation step" be
    /// answered by looking at a number instead of guessing from behaviour that
    /// might just be a misconfigured profile.
    var leftStickDebug: StickDebugState {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedLeftStickDebug
    }
    var rightStickDebug: StickDebugState {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedRightStickDebug
    }

    private func publishStickDebug(isLeft: Bool, x: Double, y: Double, addedSteps: Int) {
        statusLock.lock()
        if isLeft {
            storedLeftStickDebug.x = x
            storedLeftStickDebug.y = y
            storedLeftStickDebug.rotationSteps += addedSteps
        } else {
            storedRightStickDebug.x = x
            storedRightStickDebug.y = y
            storedRightStickDebug.rotationSteps += addedSteps
        }
        statusLock.unlock()
    }

    private var storedHeldButtons: Set<String> = []
    private var storedRawGyro = SIMD3<Double>()

    /// Which of this controller's own buttons are down right now — for the
    /// per-side test page, so a dead button shows up as "never highlights"
    /// instead of a guess about whether the press even reached the app.
    var heldButtons: Set<String> {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedHeldButtons
    }

    /// The gyro's raw x/y/z, deg/s, before axis selection or bias correction
    /// — the same reason the test page shows raw stick x/y rather than
    /// whatever a configured mode turns it into: a hardware problem should be
    /// visible independent of how anything is currently mapped.
    var rawGyro: SIMD3<Double> {
        statusLock.lock()
        defer { statusLock.unlock() }
        return storedRawGyro
    }

    private func publishHeldButton(_ name: String, isDown: Bool) {
        statusLock.lock()
        if isDown { storedHeldButtons.insert(name) } else { storedHeldButtons.remove(name) }
        statusLock.unlock()
    }

    private func publishRawGyro(_ raw: SIMD3<Double>) {
        statusLock.lock()
        storedRawGyro = raw
        statusLock.unlock()
    }

    // Orientation accumulated since the activation button went down. Reset on
    // each press, so integration error never has more than one hold to build up in.
    private var gyroOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var gyroOrigin: CGPoint = .zero
    private var lastPostedPosition: CGPoint = .zero
    private var desktopBounds: CGRect = .null

    private var isLeftDragging = false
    private var isRightDragging = false
    private var isCenterDragging = false

    /// Reports arrive roughly every 15 ms; past about two of those with nothing
    /// new, treat the controller as standing still rather than assuming the
    /// last velocity continues.
    private let staleSampleGrace: CFTimeInterval = 0.035

    /// Press/release bookkeeping and the FN layer's engaged state. Written from
    /// the IOHID thread and reset when the mapping changes, so it sits under
    /// `inputLock` like the rest of the shared input state.
    private var session = ButtonSession()
    private var diagnostics: GyroDiagnostics?

    /// Circular-sweep tracking for the rotation-to-tab-switch gesture, one per
    /// physical stick. Under `inputLock` like `session`: read and updated from
    /// the IOHID thread, reset from whatever thread applies a config change.
    private var leftRotationTracker = StickRotationTracker()
    private var rightRotationTracker = StickRotationTracker()

    /// The combo actually pressed for the held side of an in-progress rotation
    /// gesture, captured at press time. Releasing it later must replay this
    /// same string rather than re-deriving `rotation.target.heldKeyName` from
    /// whatever the config resolves to *now* — if the release is provoked by
    /// FN letting go, that fresh lookup has already flipped to `.off`, whose
    /// `heldKeyName` is empty and releases nothing, leaving the real key stuck.
    private var leftHeldRotationKey: String?
    private var rightHeldRotationKey: String?

    init(controller: JoyConSwift.Controller, config: AppConfig, combine: CombineCoordinator) {
        self.controller = controller
        self.storedConfig = config
        self.combine = combine
        self.mapping = ActiveMapping(gyro: GyroRuntime(GyroConfig()))
        self.fusion = GyroFusion(stillnessThreshold: stillnessThreshold)
        refreshMapping()

        var framesPerSecond = 120
        if #available(macOS 12.0, *) {
            framesPerSecond = max(60, NSScreen.main?.maximumFramesPerSecond ?? 120)
        }
        if ProcessInfo.processInfo.environment["GYROKEYMAPPER_DEBUG"] != nil {
            diagnostics = GyroDiagnostics(controller: controller)
        }

        setupHandlers()
        startRenderLoop(framesPerSecond: framesPerSecond)
    }

    deinit {
        renderTimer?.cancel()
        KeyboardOutput.shared.releaseAll(ownedBy: ObjectIdentifier(self))
    }

    /// Drop every key this controller is holding — called when it disconnects.
    func releaseAllHeldKeys() {
        KeyboardOutput.shared.releaseAll(ownedBy: ObjectIdentifier(self))
    }

    private func setupHandlers() {
        controller.setPlayerLights(l1: .on, l2: .off, l3: .off, l4: .off)
        controller.enableIMU(enable: true)
        controller.setInputMode(mode: .standardFull)

        controller.buttonPressHandler = { [weak self] button in
            self?.handleButton(button, isDown: true)
        }
        controller.buttonReleaseHandler = { [weak self] button in
            self?.handleButton(button, isDown: false)
        }
        controller.leftStickPosHandler = { [weak self] pos in
            guard let self = self else { return }
            let mapping = self.mappingSnapshot()
            self.handleStickPos(pos, stick: mapping.leftStick, rotation: self.activeStickRotation(mapping, isLeft: true), isLeft: true)
        }
        controller.rightStickPosHandler = { [weak self] pos in
            guard let self = self else { return }
            let mapping = self.mappingSnapshot()
            self.handleStickPos(pos, stick: mapping.rightStick, rotation: self.activeStickRotation(mapping, isLeft: false), isLeft: false)
        }
        controller.leftStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            let mapping = self.mappingSnapshot()
            self.handleStickDirection(newDir, oldDir, stick: mapping.leftStick, rotation: self.activeStickRotation(mapping, isLeft: true), prefix: "lstick")
        }
        controller.rightStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            let mapping = self.mappingSnapshot()
            self.handleStickDirection(newDir, oldDir, stick: mapping.rightStick, rotation: self.activeStickRotation(mapping, isLeft: false), prefix: "rstick")
        }
        controller.sensorHandler = { [weak self] in self?.handleGyro() }
    }

    private func mappingSnapshot() -> ActiveMapping {
        configLock.lock()
        defer { configLock.unlock() }
        return mapping
    }

    private func outputKey(_ source: String) -> OutputKey {
        OutputKey(owner: ObjectIdentifier(self), source: source)
    }

    // MARK: - Buttons (IOHID thread)

    private func handleButton(_ button: JoyCon.Button, isDown: Bool) {
        let mapping = mappingSnapshot()
        let name = buttonNames[button]

        // Independent of every mapping decision below — the test page needs
        // to see a press even when nothing is bound to it.
        if let name = name { publishHeldButton(name, isDown: isDown) }
        guard !isTestModeSuppressed else { return }

        if let activation = mapping.gyro.activationButton, activation == button {
            // While both halves are connected the activation state is shared:
            // the button that arms the gyro can sit on the controller that
            // isn't the one driving the cursor.
            switch mapping.gyro.activationMode {
            case .hold:
                if mapping.isCombined {
                    combine.setActivation(held: isDown)
                } else {
                    inputLock.lock()
                    activationHeld = isDown
                    if isDown { needsRecenter = true }
                    inputLock.unlock()
                }
            case .toggle:
                // Only the press flips state — a release of the same button
                // must not immediately toggle it back off.
                if isDown {
                    if mapping.isCombined {
                        combine.toggleActivation()
                    } else {
                        inputLock.lock()
                        activationHeld.toggle()
                        if activationHeld { needsRecenter = true }
                        inputLock.unlock()
                    }
                }
            }
        }

        guard let name = name else { return }

        if diagnostics != nil {
            // Answers the three questions that "FN doesn't work" could mean, in
            // one line: is the pair even recognised, is the layer switched on,
            // and is the key being held seen as an FN key at all.
            let engaged = combine.fnEngagedKeys()
            // stderr, not stdout: start.sh redirects both to the log, but
            // stdout to a file is block-buffered and would show nothing until
            // the process exits.
            FileHandle.standardError.write(Data(("[fn] \(controller.type.rawValue) btn=\(name) down=\(isDown) "
                + "combined=\(mapping.isCombined) fnEnabled=\(mapping.fn.enabled) "
                + "fnKeys=\(mapping.fn.activeLayers.compactMap { $0.key }) "
                + "isFnKey=\(mapping.fn.isFnKey(name)) held=\(engaged) "
                + "-> \(String(describing: mapping.fn.action(for: name, base: mapping.buttons, engaged: engaged)))\n").utf8))
        }

        // The FN key drives the shared layer state and emits nothing of its own
        // while held. Its ordinary binding fires on release, and only if the
        // release turned out to be a tap — by which time the button is already
        // up, so it goes out as press-then-release.
        if mapping.fn.isFnKey(name) {
            let now = CACurrentMediaTime()
            if isDown {
                combine.fnPress(name, now: now)
            } else if combine.fnRelease(name, now: now), let tap = mapping.buttons[name] {
                perform(tap, isDown: true, source: "button.\(name).tap")
                perform(tap, isDown: false, source: "button.\(name).tap")
            }
            return
        }

        // Settles any held FN key as a hold rather than a tap. Done before the
        // lookup, and through the coordinator, because the FN key in question is
        // routinely on the other half.
        if isDown { combine.fnNoteOtherPress() }

        // Read outside the input lock: the two locks are then never held at
        // once, so there is no ordering to get wrong.
        let engaged = combine.fnEngagedKeys()
        inputLock.lock()
        let outcome = session.handle(
            button: button, name: name, isDown: isDown,
            base: mapping.buttons, fn: mapping.fn, engaged: engaged
        )
        inputLock.unlock()

        switch outcome {
        case .none:
            break
        case .press(let action):
            perform(action, isDown: true, source: "button.\(name)")
        case .release(let action):
            perform(action, isDown: false, source: "button.\(name)")
        }
    }

    private func perform(_ action: ButtonAction, isDown: Bool, source: String) {
        if let key = action.key, !key.isEmpty {
            let identifier = outputKey(source)
            if isDown {
                KeyboardOutput.shared.press(key, identifier: identifier)
            } else {
                KeyboardOutput.shared.release(key, identifier: identifier)
            }
        }
        if let mouseButton = action.mouseButton {
            renderQueue.async { self.postMouseButton(mouseButton, isDown: isDown) }
        }
    }

    // MARK: - Sticks (IOHID thread)

    private func cardinals(for direction: JoyCon.StickDirection) -> Set<String> {
        switch direction {
        case .Up: return ["up"]
        case .UpRight: return ["up", "right"]
        case .Right: return ["right"]
        case .DownRight: return ["down", "right"]
        case .Down: return ["down"]
        case .DownLeft: return ["down", "left"]
        case .Left: return ["left"]
        case .UpLeft: return ["up", "left"]
        case .Neutral: return []
        }
    }

    /// Rotate-to-switch is a property of *holding a specific FN key* (see
    /// `FnLayer`), not a fixed setting, so it can't be resolved once into
    /// `ActiveMapping` the way buttons and sticks are — it has to be looked
    /// up fresh against whichever FN key (if any) is unambiguously engaged
    /// right now. Two or more held at once is the same "no output" ambiguity
    /// `FnConfig.action(for:base:engaged:)` already applies to buttons.
    private func activeStickRotation(_ mapping: ActiveMapping, isLeft: Bool) -> StickRotationConfig {
        let engaged = combine.fnEngagedKeys()
        guard engaged.count == 1, let layer = mapping.fn.layer(forKey: engaged[0]) else { return StickRotationConfig() }
        return isLeft ? layer.leftStickRotation : layer.rightStickRotation
    }

    private func handleStickDirection(_ newDir: JoyCon.StickDirection, _ oldDir: JoyCon.StickDirection, stick: StickConfig, rotation: StickRotationConfig, prefix: String) {
        guard !isTestModeSuppressed else { return }
        // The rotation gesture sweeps through all four cardinal positions on
        // its way around, so Key mode's directional output is suppressed
        // while the gesture actually owns the stick — which is only while an
        // FN key is held — otherwise a sweep would fire both a tab switch and
        // a burst of arrow keys. Outside that window Key mode plays normally.
        guard stick.mode == .key else { return }
        // `rotation` already reflects whether a specific, unambiguously
        // engaged FN key configures this stick's rotation — see
        // `activeStickRotation` — so this alone is the gate.
        if rotation.target != .off { return }
        let oldSet = cardinals(for: oldDir)
        let newSet = cardinals(for: newDir)

        for direction in oldSet.subtracting(newSet) {
            if let action = stick.keys[direction] { perform(action, isDown: false, source: "\(prefix).\(direction)") }
        }
        for direction in newSet.subtracting(oldSet) {
            if let action = stick.keys[direction] { perform(action, isDown: true, source: "\(prefix).\(direction)") }
        }
    }

    /// Accumulates only — the movement is posted by the render tick, so the
    /// cursor advances on a steady clock rather than in one jump per report.
    private func handleStickPos(_ pos: CGPoint, stick: StickConfig, rotation: StickRotationConfig, isLeft: Bool) {
        guard !isTestModeSuppressed else {
            // Nothing left to clean up here: `setTestModeSuppressed` already
            // released any held key and reset both trackers the moment
            // suppression turned on. The test page still needs the raw x/y.
            publishStickDebug(isLeft: isLeft, x: Double(pos.x), y: Double(pos.y), addedSteps: 0)
            return
        }

        let holdIdentifier = outputKey(isLeft ? "lstick.rotate.hold" : "rstick.rotate.hold")
        // Gated on an FN key actually being held, not just on `rotation`
        // being configured — a bare circular sweep is common enough in
        // ordinary play (aiming, menu navigation) that firing on it alone
        // misfires regularly. `rotation` is already resolved from whichever
        // FN key is unambiguously engaged right now (see
        // `activeStickRotation`), so a bare `.off` check is the whole gate.
        let active = rotation.target != .off

        guard active else {
            // Mutually exclusive with the gesture: FN not held (or rotation
            // off) means this stick is entirely Mode's — mouse/wheel/key —
            // same as if the gesture didn't exist. The two never run together,
            // so a right stick set to Wheel can't also dribble scroll events
            // out from underneath an FN-held rotation sweep.
            let speed = CGFloat(stick.speed)
            switch stick.mode {
            case .mouse:
                if pos.x != 0 || pos.y != 0 {
                    inputLock.lock()
                    pendingMouseDx += pos.x * speed
                    pendingMouseDy -= pos.y * speed // stick "up" is negative in CGEvent space
                    inputLock.unlock()
                }
            case .wheel:
                if pos.x != 0 || pos.y != 0 {
                    inputLock.lock()
                    pendingScrollX += pos.x * speed
                    pendingScrollY += pos.y * speed
                    inputLock.unlock()
                }
            case .key, .none:
                break
            }

            inputLock.lock()
            let wasEngaged = isLeft ? leftRotationTracker.engaged : rightRotationTracker.engaged
            // `rotation` is `.off` here — that's what put us in this branch —
            // so the key to release has to come from what press actually used,
            // not from re-deriving it off the now-stale config.
            let heldKey = isLeft ? leftHeldRotationKey : rightHeldRotationKey
            if isLeft {
                leftRotationTracker.reset()
                leftHeldRotationKey = nil
            } else {
                rightRotationTracker.reset()
                rightHeldRotationKey = nil
            }
            inputLock.unlock()
            // Off (or FN let go, or the stick recentered right as either
            // happened) mid-gesture — the held key must not outlive it.
            if wasEngaged, let heldKey = heldKey { KeyboardOutput.shared.release(heldKey, identifier: holdIdentifier) }
            // Published even with the gesture inactive, so the settings
            // window can confirm raw stick input is arriving before FN is
            // even held.
            publishStickDebug(isLeft: isLeft, x: Double(pos.x), y: Double(pos.y), addedSteps: 0)
            return
        }

        let heldKey = rotation.target.heldKeyName

        inputLock.lock()
        let wasEngaged = isLeft ? leftRotationTracker.engaged : rightRotationTracker.engaged
        let steps = isLeft
            ? leftRotationTracker.update(pos: pos, degreesPerStep: rotation.degreesPerStep)
            : rightRotationTracker.update(pos: pos, degreesPerStep: rotation.degreesPerStep)
        let nowEngaged = isLeft ? leftRotationTracker.engaged : rightRotationTracker.engaged
        if nowEngaged && !wasEngaged {
            if isLeft { leftHeldRotationKey = heldKey } else { rightHeldRotationKey = heldKey }
        } else if wasEngaged && !nowEngaged {
            if isLeft { leftHeldRotationKey = nil } else { rightHeldRotationKey = nil }
        }
        inputLock.unlock()
        publishStickDebug(isLeft: isLeft, x: Double(pos.x), y: Double(pos.y), addedSteps: abs(steps))

        // The chosen key goes down the moment the stick is pushed to the
        // bottom (see `StickRotationTracker`'s anchor) and stays down for as
        // long as the stick is still out — exactly like a person holding it
        // and tapping Tab: Ctrl shows a browser's tab switcher, Cmd shows
        // macOS's app switcher, both only committing once released. Letting
        // go on every step (a full "ctrl+tab" tap each time) would never
        // trigger that preview — it would just hop one at a time.
        if nowEngaged && !wasEngaged {
            KeyboardOutput.shared.press(heldKey, identifier: holdIdentifier)
        } else if wasEngaged && !nowEngaged {
            KeyboardOutput.shared.release(heldKey, identifier: holdIdentifier)
        }

        guard steps != 0 else { return }

        // Forward (clockwise) is a bare Tab, matching a held switcher's
        // default direction; backward (counter-clockwise) adds Shift for that
        // one tap only — the held key underneath is untouched either way.
        let tapKey = steps > 0 ? "shift+tab" : "tab"
        let tapIdentifier = outputKey(isLeft ? "lstick.rotate.tap" : "rstick.rotate.tap")
        for _ in 0..<abs(steps) {
            KeyboardOutput.shared.press(tapKey, identifier: tapIdentifier)
            KeyboardOutput.shared.release(tapKey, identifier: tapIdentifier)
        }
    }

    // MARK: - Gyro sampling (IOHID thread)

    /// Which physical axis corresponds to which felt motion (yaw/pitch/roll)
    /// depends on the controller and how it's held, so this is user-picked in
    /// Settings rather than hardcoded. Whichever axis isn't picked for either
    /// (roll, around the direction the "laser" points) is dropped: spinning a
    /// rigidly-held forward-pointing laser about its own axis can't move where
    /// it lands.
    private static func axisIndex(_ axisName: String) -> Int {
        switch axisName {
        case "y": return 1
        case "z": return 2
        default: return 0
        }
    }

    /// The IMU samples at a fixed 200 Hz but its reports arrive in bursts of
    /// three, ~15 ms apart. Summing here and averaging per render tick decimates
    /// the burst properly instead of aliasing it into the cursor.
    private func handleGyro() {
        let gyro = controller.gyro
        let raw = SIMD3<Double>(Double(gyro.x), Double(gyro.y), Double(gyro.z))
        // Ahead of every mapping decision below, same as the button state
        // above — the test page needs to see this even with gyro-to-mouse
        // turned off, since that's routinely the state it's used to debug.
        publishRawGyro(raw)
        guard !isTestModeSuppressed else { return }

        let mapping = mappingSnapshot()
        let runtime = mapping.gyro
        guard runtime.enabled, mapping.role != .off else { return }

        // A contributor hands over its axes untouched — which of them answers
        // to horizontal and vertical is the driver's to work out, and its own
        // pipeline stays idle.
        if mapping.role == .contributor {
            combine.deposit(raw)
            return
        }

        inputLock.lock()
        sampleSum += raw
        sampleCount += 1
        inputLock.unlock()
    }

    // MARK: - Render loop (renderQueue)

    private func startRenderLoop(framesPerSecond: Int) {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(framesPerSecond), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        renderTimer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTickTime == 0 ? 1.0 / 120 : min(max(now - lastTickTime, 1.0 / 1000), 1.0 / 20)
        lastTickTime = now

        inputLock.lock()
        let sum = sampleSum, count = sampleCount
        var held = activationHeld
        var recenter = needsRecenter
        var dx = pendingMouseDx, dy = pendingMouseDy
        let scrollX = pendingScrollX, scrollY = pendingScrollY
        sampleSum = SIMD3<Double>(); sampleCount = 0
        needsRecenter = false
        pendingMouseDx = 0; pendingMouseDy = 0
        pendingScrollX = 0; pendingScrollY = 0
        inputLock.unlock()

        diagnostics?.record(sampleCount: count, now: now)

        let mapping = mappingSnapshot()
        let runtime = mapping.gyro
        // A contributor feeds the other half's fusion and an `.off` half feeds
        // nothing — neither posts cursor motion of its own, but both still
        // drive their stick and scroll output below.
        let drivesGyro = mapping.role == .driver && runtime.enabled

        if mapping.isCombined && drivesGyro {
            let shared = combine.takeActivation()
            held = shared.held
            recenter = shared.recenter
        }

        // Which axis drives which direction is applied here rather than per
        // report: picking a component of the mean is the same as averaging that
        // component, and it keeps the sampling path down to one vector add.
        let rawMean: SIMD3<Double>? = count > 0 ? sum / Double(count) : nil
        var rate: (h: Double, v: Double)? = rawMean.map {
            (h: $0[Self.axisIndex(runtime.horizontalAxis)], v: $0[Self.axisIndex(runtime.verticalAxis)])
        }
        var bothSidesStill = true
        if drivesGyro && mapping.isFused {
            (rate, bothSidesStill) = fuseWithOtherHalf(
                own: rate, raw: rawMean, runtime: runtime, saved: mapping.savedAlignment, dt: dt
            )
        } else {
            publishFusionStatus(.inactive)
        }

        // While the activation button is held the controller is being aimed,
        // so nothing observed then is evidence about the sensor's zero.
        let mayLearnBias = (runtime.activationButton == nil || !held) && bothSidesStill
        updateAngularVelocity(rate: rate, dt: dt, now: now, enabled: drivesGyro, mayLearnBias: mayLearnBias)

        if drivesGyro, runtime.activationButton != nil {
            applyLaser(runtime: runtime, held: held, recenter: recenter, dt: dt, stickDx: dx, stickDy: dy)
        } else {
            if drivesGyro {
                let (gx, gy) = continuousGyroDelta(runtime: runtime, dt: dt)
                dx += gx
                dy += gy
            }
            if dx != 0 || dy != 0 { moveMouseBy(dx: dx, dy: dy) }
        }

        flushScroll(x: scrollX, y: scrollY)
    }

    /// Places the other half's IMU against this one's chosen axes, then averages
    /// the two. Both steps degrade to "this IMU alone", which is the whole
    /// safety story of fusing: the fallback is exactly the behaviour the user
    /// would have had with a single Joy-Con, never something invented.
    private func fuseWithOtherHalf(
        own: (h: Double, v: Double)?,
        raw: SIMD3<Double>?,
        runtime: GyroRuntime,
        saved: FusionAlignment?,
        dt: Double
    ) -> (rate: (h: Double, v: Double)?, bothSidesStill: Bool) {
        let other = combine.drainBus()
        let horizontal = Self.axisIndex(runtime.horizontalAxis)
        let vertical = Self.axisIndex(runtime.verticalAxis)

        // A saved calibration covering the axes actually in use is the whole
        // answer, and nothing needs learning. It covering only some of them —
        // after the user re-picks which axis aims sideways, say — leaves the
        // learner to fill in the rest rather than starting over.
        let saved = saved ?? FusionAlignment()
        let savedCoversUse = saved.knows(driverAxis: horizontal) && saved.knows(driverAxis: vertical)
        if !savedCoversUse, let other = other, let raw = raw {
            alignment.update(driverRaw: raw, other: other, dt: dt)
        }
        let inUse = saved.merging(alignment.result)

        let projected: (h: Double, v: Double)?
        if let other = other {
            let mappedH = inUse.value(driverAxis: horizontal, from: other)
            let mappedV = inUse.value(driverAxis: vertical, from: other)
            if let own = own {
                // An axis that isn't placed falls back to the driver's own
                // reading, so it averages to exactly what one Joy-Con would
                // have produced — one direction can start fusing before the
                // other without the second one misbehaving.
                projected = (mappedH ?? own.h, mappedV ?? own.v)
            } else if let mappedH = mappedH, let mappedV = mappedV {
                // This half dropped a report and the other didn't. Covering the
                // gap needs both directions placed: there is nothing of our own
                // left to fall back to.
                projected = (mappedH, mappedV)
            } else {
                projected = nil
            }
        } else {
            projected = nil
        }

        let result = fusion.combine(own: own, other: projected, dt: dt)
        publishFusionStatus(status(inUse: inUse, savedCoversUse: savedCoversUse, horizontal: horizontal, vertical: vertical))
        publishLearnedAlignment(alignment.result)
        return result
    }

    private func status(inUse: FusionAlignment, savedCoversUse: Bool, horizontal: Int, vertical: Int) -> FusionStatus {
        if fusion.isSuspended { return .suspended }
        let knowsHorizontal = inUse.knows(driverAxis: horizontal)
        let knowsVertical = inUse.knows(driverAxis: vertical)
        if knowsHorizontal && knowsVertical { return .aligned(saved: savedCoversUse) }
        let placed = alignment.placedAxisCount
        return placed > 0 ? .partial(placed: placed) : .learning
    }

    /// Turns however many (or few) raw samples arrived into a continuously
    /// defined angular velocity. This is what absorbs the burstiness: rather
    /// than moving the cursor when data happens to show up, the cursor always
    /// moves at the current best estimate of how fast the controller is turning.
    private func updateAngularVelocity(rate: (h: Double, v: Double)?, dt: Double, now: CFTimeInterval, enabled: Bool, mayLearnBias: Bool) {
        guard enabled else { return }

        if let rate = rate {
            lastSampleTime = now

            if mayLearnBias && abs(rate.h) < stillnessThreshold && abs(rate.v) < stillnessThreshold {
                let alpha = 1 - exp(-dt / biasTimeConstant)
                biasH += (rate.h - biasH) * alpha
                biasV += (rate.v - biasV) * alpha
            }
            targetRateH = rate.h - biasH
            targetRateV = rate.v - biasV
        } else if now - lastSampleTime > staleSampleGrace {
            // A delivery gap — Bluetooth stalls of 100 ms+ are routine for a
            // Joy-Con on a Mac. Aim at a standstill and let the filter glide
            // there, rather than freezing mid-motion or coasting indefinitely.
            targetRateH = 0
            targetRateV = 0
        }
        // Otherwise hold the last estimate: a tick with no new sample only
        // means the render loop is faster than the report rate.
    }

    private func filteredRates(dt: Double) -> (h: Double, v: Double) {
        (filterH.filter(targetRateH, dt: dt), filterV.filter(targetRateV, dt: dt))
    }

    private func continuousGyroDelta(runtime: GyroRuntime, dt: Double) -> (CGFloat, CGFloat) {
        let (h, v) = filteredRates(dt: dt)
        var dx = -h * dt * runtime.sensitivity
        var dy = -v * dt * runtime.sensitivity
        if runtime.invertHorizontal { dx = -dx }
        if runtime.invertVertical { dy = -dy }
        return (CGFloat(dx), CGFloat(-dy)) // caller works in CGEvent space
    }

    /// Project the "laser" — a forward vector rotated by the orientation
    /// accumulated since activation — onto a plane in front of the controller,
    /// and place the cursor at the corresponding offset from wherever it was
    /// when the hold began. Composing in the fixed frame captured at activation
    /// rather than the controller's own tilting frame is what keeps horizontal
    /// motion feeling like "turn to point at a spot on the wall".
    private func applyLaser(runtime: GyroRuntime, held: Bool, recenter: Bool, dt: Double, stickDx: CGFloat, stickDy: CGFloat) {
        if recenter {
            gyroOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            desktopBounds = Self.activeDisplayBounds()
            gyroOrigin = currentCursorLocation()
            lastPostedPosition = gyroOrigin
            filterH.reset()
            filterV.reset()
        }

        guard held else {
            if stickDx != 0 || stickDy != 0 { moveMouseBy(dx: stickDx, dy: stickDy) }
            return
        }

        // A stick nudge during a hold shifts where the laser is anchored,
        // rather than fighting the absolute positioning.
        gyroOrigin.x += stickDx
        gyroOrigin.y += stickDy

        let (h, v) = filteredRates(dt: dt)
        let wx = Float(h * .pi / 180 * dt) // horizontal driver -> rotation about the up axis
        let wy = Float(v * .pi / 180 * dt) // vertical driver -> rotation about the right axis
        let step = simd_quatf(angle: wx, axis: simd_float3(0, 1, 0)) * simd_quatf(angle: wy, axis: simd_float3(1, 0, 0))
        gyroOrientation = simd_normalize(step * gyroOrientation)

        let rotated = gyroOrientation.act(simd_float3(0, 0, 1))
        guard rotated.z > 0.05 else { return } // rotated ~85°+ away from the start; stop rather than blow up

        // (rotated.x / rotated.z) is tan(effective angle); scaling by 180/pi
        // keeps sensitivity in "pixels per degree" for small movements while
        // large or combined rotations follow the correct projection.
        var dx = Double(rotated.x / rotated.z) * (180 / .pi) * runtime.sensitivity
        var dy = Double(rotated.y / rotated.z) * (180 / .pi) * runtime.sensitivity
        if runtime.invertHorizontal { dx = -dx }
        if runtime.invertVertical { dy = -dy }

        // CGEvent space is Y-down, so "up" means subtracting.
        moveMouseTo(CGPoint(x: gyroOrigin.x + CGFloat(dx), y: gyroOrigin.y - CGFloat(dy)))
    }

    // MARK: - Mouse output (renderQueue)

    /// `CGEvent(source:).location`, unlike `NSEvent.mouseLocation`, is already
    /// in CGEvent's coordinate space and safe to call off the main thread.
    private func currentCursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? lastPostedPosition
    }

    private static func activeDisplayBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    private func moveMouseBy(dx: CGFloat, dy: CGFloat) {
        let current = currentCursorLocation()
        moveMouseTo(CGPoint(x: current.x + dx, y: current.y + dy), knownDelta: CGPoint(x: dx, y: dy))
    }

    private func moveMouseTo(_ position: CGPoint, knownDelta: CGPoint? = nil) {
        if desktopBounds.isNull { desktopBounds = Self.activeDisplayBounds() }
        let clamped = CGPoint(
            x: min(max(desktopBounds.minX, position.x), desktopBounds.maxX - 1),
            y: min(max(desktopBounds.minY, position.y), desktopBounds.maxY - 1)
        )
        let delta = knownDelta ?? CGPoint(x: clamped.x - lastPostedPosition.x, y: clamped.y - lastPostedPosition.y)
        // Holding the controller still still ticks 120 times a second; don't
        // flood the system with moves that don't land on a different pixel.
        // Absolute positioning only — a relative nudge has to be posted even
        // when it's sub-pixel, since it's measured against the live cursor and
        // dropping it would stall slow stick movement outright rather than
        // letting it accumulate.
        if knownDelta == nil,
           clamped.x.rounded() == lastPostedPosition.x.rounded(),
           clamped.y.rounded() == lastPostedPosition.y.rounded() {
            lastPostedPosition = clamped
            return
        }
        lastPostedPosition = clamped

        let type: CGEventType
        let button: CGMouseButton
        if isLeftDragging { type = .leftMouseDragged; button = .left }
        else if isRightDragging { type = .rightMouseDragged; button = .right }
        else if isCenterDragging { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }

        guard let event = CGEvent(mouseEventSource: Self.sharedEventSource, mouseType: type, mouseCursorPosition: clamped, mouseButton: button) else { return }
        // Games and anything else reading relative motion look at these rather
        // than at the absolute position; a real mouse always carries them.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.post(tap: .cghidEventTap)
    }

    private func postMouseButton(_ name: String, isDown: Bool) {
        let button: CGMouseButton
        switch name.lowercased() {
        case "right": button = .right
        case "center", "middle": button = .center
        default: button = .left
        }
        let type: CGEventType
        switch (button, isDown) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }

        let position = currentCursorLocation()
        lastPostedPosition = position
        if let event = CGEvent(mouseEventSource: Self.sharedEventSource, mouseType: type, mouseCursorPosition: position, mouseButton: button) {
            event.post(tap: .cghidEventTap)
        }

        switch button {
        case .left: isLeftDragging = isDown
        case .right: isRightDragging = isDown
        default: isCenterDragging = isDown
        }
    }

    /// Scroll accumulates in floating point and only whole pixels are sent, so
    /// a slow push still scrolls instead of truncating to zero every tick.
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    private func flushScroll(x: CGFloat, y: CGFloat) {
        scrollRemainderX += x
        scrollRemainderY += y
        let stepX = scrollRemainderX.rounded(.towardZero)
        let stepY = scrollRemainderY.rounded(.towardZero)
        guard stepX != 0 || stepY != 0 else { return }
        scrollRemainderX -= stepX
        scrollRemainderY -= stepY

        if let event = CGEvent(scrollWheelEvent2Source: Self.sharedEventSource, units: .pixel, wheelCount: 2, wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Live stick reading for the settings window's debug readout — not used by
/// the mapping logic itself, which reads the raw `CGPoint` directly.
struct StickDebugState {
    var x: Double = 0
    var y: Double = 0
    /// Cumulative count of rotation steps fired, so a slow deliberate sweep
    /// can be confirmed to have registered without having to watch a browser
    /// tab bar at the same time as the controller.
    var rotationSteps: Int = 0
}

/// Turns the stick being swept in a circle into discrete steps. Arming needs
/// a full push (any direction — the FN hold this is already gated behind is
/// what rules out an accident, so there's no anchor angle to also require),
/// and once armed a much smaller push is enough to keep going. Direction is
/// meaningless near center, so no angle is trusted below that floor either
/// way. `degreesPerStep` defaults to a full quarter turn rather than
/// something twitchier, so a slow, deliberate sweep can be walked one tab at
/// a time instead of skipping several from a quick flick.
struct StickRotationTracker {
    /// Whether the gesture is currently mid-sweep. The caller holds the
    /// chosen key down for exactly as long as this is true, so it's read
    /// before and after every `update`.
    private(set) var engaged = false
    private var lastAngle: Double?
    private var accumulatedDegrees: Double = 0

    /// Once engaged, the gesture ends here regardless of where it started —
    /// easing off doesn't have to mean easing all the way back to the anchor.
    /// Set well below `anchorMagnitude` on purpose: a real sweep's magnitude
    /// dips as it crosses toward a diagonal (the stick's travel isn't a
    /// perfect circle) and a hand mid-gesture relaxes a little without
    /// meaning to let go. If this sat close to `anchorMagnitude`, either one
    /// would drop below it, disengage, and then re-arm on the very next
    /// sample — each re-arm firing its own free anchor tick, which is exactly
    /// what "fires several times in a row for one sweep" looks like.
    private let disengageMagnitude: Double = 0.3
    /// Arming needs a deliberate full push, not just past the disengage
    /// threshold — direction doesn't matter (no anchor angle to hit) since
    /// the FN hold already rules out an incidental nudge; this just tells a
    /// real push from a half-hearted one.
    private let anchorMagnitude: Double = 0.85

    /// Positive return = counter-clockwise steps crossed this update,
    /// negative = clockwise. Ordinarily -1, 0, or 1 — except the very update
    /// that arms the gesture, which always returns exactly -1: the push
    /// that arms it is itself the first (forward) tick, not just the
    /// starting line. `degreesPerStep` comes from `StickConfig` rather than
    /// being fixed here — floored well above zero so a stray 0 or negative
    /// typed into Settings can't spin this into an infinite loop.
    mutating func update(pos: CGPoint, degreesPerStep: Double) -> Int {
        let step = max(degreesPerStep, 5)
        let magnitude = (Double(pos.x) * Double(pos.x) + Double(pos.y) * Double(pos.y)).squareRoot()
        guard magnitude >= disengageMagnitude else {
            reset()
            return 0
        }

        let angle = atan2(Double(pos.y), Double(pos.x))

        guard engaged else {
            guard magnitude >= anchorMagnitude else { return 0 }
            engaged = true
            lastAngle = angle
            return -1
        }

        defer { lastAngle = angle }
        guard let last = lastAngle else { return 0 }

        // Shortest-path delta: a rotation can't cover more than half a turn
        // between two samples a few milliseconds apart, so wrapping this way
        // rather than taking the raw difference is always the right choice,
        // not just a tie-break.
        var delta = angle - last
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        accumulatedDegrees += delta * 180 / .pi

        var steps = 0
        while accumulatedDegrees >= step { accumulatedDegrees -= step; steps += 1 }
        while accumulatedDegrees <= -step { accumulatedDegrees += step; steps -= 1 }
        return steps
    }

    mutating func reset() {
        engaged = false
        lastAngle = nil
        accumulatedDegrees = 0
    }
}

/// The hot subset of `GyroConfig`, resolved once per config change so the
/// sample path never walks dictionaries or does string lookups.
/// What a controller is currently mapped to: the button bindings in force, the
/// gyro settings in force, and the part this half plays in producing cursor
/// motion. Resolved from the config plus whether both halves are connected.
struct ActiveMapping {
    var gyro: GyroRuntime
    var role: GyroRole = .driver
    var buttons: [String: ButtonAction] = [:]
    var fn: FnConfig = FnConfig()
    var leftStick: StickConfig = StickConfig()
    var rightStick: StickConfig = StickConfig()
    /// A calibration saved in the profile, if there is one. Its presence is
    /// what spares the user having to wave the grip about at every launch.
    var savedAlignment: FusionAlignment?
    var isCombined = false
    var isFused = false
}

struct GyroRuntime {
    var enabled = false
    var sensitivity: Double = 8
    var horizontalAxis = "x"
    var verticalAxis = "y"
    var invertHorizontal = false
    var invertVertical = false
    var activationButton: JoyCon.Button?
    var activationMode: GyroActivationMode = .hold
    var minCutoff: Double = 2.5

    init(_ config: GyroConfig) {
        enabled = config.enabled
        sensitivity = config.sensitivity
        horizontalAxis = config.horizontalAxis
        verticalAxis = config.verticalAxis
        activationMode = config.activationMode
        invertHorizontal = config.invertHorizontal
        invertVertical = config.invertVertical
        if let name = config.activationButton, !name.isEmpty {
            activationButton = buttonNames.first(where: { $0.value == name })?.key
        }
        // Geometric between snappy and glassy; movement raises the cutoff from
        // here regardless, so this only sets how steady a held-still aim is.
        minCutoff = 8.0 * pow(0.1, min(max(config.smoothing, 0), 1))
    }
}

/// Opt-in (`GYROKEYMAPPER_DEBUG=1`) counter that separates "Bluetooth dropped
/// the report" from "we were too slow to read it": the controller stamps every
/// report with a timer that advances one tick per 5 ms IMU sample, so a jump in
/// it is the radio's fault, while samples we simply never saw are ours.
private final class GyroDiagnostics {
    private let controller: JoyConSwift.Controller
    private var windowStart: CFTimeInterval = 0
    private var samples = 0
    private var emptyTicks = 0
    private var longestGap: CFTimeInterval = 0
    private var lastSample: CFTimeInterval = 0
    private var missedAtWindowStart = 0

    init(controller: JoyConSwift.Controller) {
        self.controller = controller
    }

    func record(sampleCount: Int, now: CFTimeInterval) {
        if windowStart == 0 {
            windowStart = now
            lastSample = now
            missedAtWindowStart = controller.missedSensorFrames
        }
        if sampleCount > 0 {
            samples += sampleCount
            longestGap = max(longestGap, now - lastSample)
            lastSample = now
        } else {
            emptyTicks += 1
        }

        let elapsed = now - windowStart
        guard elapsed >= 2 else { return }
        let missed = controller.missedSensorFrames - missedAtWindowStart
        print(String(format: "[gyro] %.0f samples/s (expect 200), longest gap %.0f ms, %d reports missed by the radio, %d idle ticks",
                     Double(samples) / elapsed, longestGap * 1000, missed, emptyTicks))
        windowStart = now
        samples = 0
        emptyTicks = 0
        longestGap = 0
        missedAtWindowStart = controller.missedSensorFrames
    }
}
