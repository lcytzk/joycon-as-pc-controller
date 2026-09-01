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
                leftStick: config.leftStick,
                rightStick: config.rightStick
            )
        }

        let profile = combineState.profile
        let role = CombineCoordinator.role(for: type, isCombined: true, source: profile.gyroSource)
        let mine = isLeft ? profile.leftGyro : profile.rightGyro

        let gyro: GyroRuntime
        switch profile.gyroSource {
        case .fused:
            // One gyro as far as the user is concerned: the fused config is the
            // whole of it, describing the driver's IMU. Where the second IMU's
            // axes sit relative to that is learned at runtime rather than
            // configured — see `GyroAlignment`.
            gyro = GyroRuntime(profile.fused)
        case .left, .right:
            gyro = role == .driver ? GyroRuntime(mine) : GyroRuntime(GyroConfig())
        }

        return ActiveMapping(
            gyro: gyro,
            role: role,
            buttons: profile.buttons,
            fn: combineState.fn,
            leftStick: profile.leftStick,
            rightStick: profile.rightStick,
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
            self.handleStickPos(pos, stick: self.mappingSnapshot().leftStick)
        }
        controller.rightStickPosHandler = { [weak self] pos in
            guard let self = self else { return }
            self.handleStickPos(pos, stick: self.mappingSnapshot().rightStick)
        }
        controller.leftStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            self.handleStickDirection(newDir, oldDir, stick: self.mappingSnapshot().leftStick, prefix: "lstick")
        }
        controller.rightStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            self.handleStickDirection(newDir, oldDir, stick: self.mappingSnapshot().rightStick, prefix: "rstick")
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

    private func handleStickDirection(_ newDir: JoyCon.StickDirection, _ oldDir: JoyCon.StickDirection, stick: StickConfig, prefix: String) {
        guard stick.mode == .key else { return }
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
    private func handleStickPos(_ pos: CGPoint, stick: StickConfig) {
        let speed = CGFloat(stick.speed)
        switch stick.mode {
        case .mouse:
            guard pos.x != 0 || pos.y != 0 else { return }
            inputLock.lock()
            pendingMouseDx += pos.x * speed
            pendingMouseDy -= pos.y * speed // stick "up" is negative in CGEvent space
            inputLock.unlock()
        case .wheel:
            guard pos.x != 0 || pos.y != 0 else { return }
            inputLock.lock()
            pendingScrollX += pos.x * speed
            pendingScrollY += pos.y * speed
            inputLock.unlock()
        case .key, .none:
            break
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
        let mapping = mappingSnapshot()
        let runtime = mapping.gyro
        guard runtime.enabled, mapping.role != .off else { return }

        let gyro = controller.gyro
        let raw = SIMD3<Double>(Double(gyro.x), Double(gyro.y), Double(gyro.z))

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
