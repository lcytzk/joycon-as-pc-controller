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
    private var gyroRuntime: GyroRuntime

    var config: AppConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return storedConfig
        }
        set {
            configLock.lock()
            storedConfig = newValue
            gyroRuntime = GyroRuntime(newValue.gyro)
            configLock.unlock()
            // A button that just got remapped would otherwise never see its
            // release and stay held down system-wide.
            KeyboardOutput.shared.releaseAll(ownedBy: ObjectIdentifier(self))
        }
    }

    // MARK: - Shared state (written on the IOHID thread, drained on renderQueue)

    private let inputLock = NSLock()
    private var sampleSumH: Double = 0
    private var sampleSumV: Double = 0
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

    private var pressedButtons: Set<JoyCon.Button> = [] // IOHID thread only
    private var diagnostics: GyroDiagnostics?

    init(controller: JoyConSwift.Controller, config: AppConfig) {
        self.controller = controller
        self.storedConfig = config
        self.gyroRuntime = GyroRuntime(config.gyro)

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
            self.handleStickPos(pos, stick: self.config.leftStick)
        }
        controller.rightStickPosHandler = { [weak self] pos in
            guard let self = self else { return }
            self.handleStickPos(pos, stick: self.config.rightStick)
        }
        controller.leftStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            self.handleStickDirection(newDir, oldDir, stick: self.config.leftStick, prefix: "lstick")
        }
        controller.rightStickHandler = { [weak self] newDir, oldDir in
            guard let self = self else { return }
            self.handleStickDirection(newDir, oldDir, stick: self.config.rightStick, prefix: "rstick")
        }
        controller.sensorHandler = { [weak self] in self?.handleGyro() }
    }

    private func gyroSnapshot() -> GyroRuntime {
        configLock.lock()
        defer { configLock.unlock() }
        return gyroRuntime
    }

    private func outputKey(_ source: String) -> OutputKey {
        OutputKey(owner: ObjectIdentifier(self), source: source)
    }

    // MARK: - Buttons (IOHID thread)

    private func handleButton(_ button: JoyCon.Button, isDown: Bool) {
        if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }

        if let activation = gyroSnapshot().activationButton, activation == button {
            inputLock.lock()
            activationHeld = isDown
            if isDown { needsRecenter = true }
            inputLock.unlock()
        }

        guard let name = buttonNames[button], let action = config.buttons[name] else { return }
        perform(action, isDown: isDown, source: "button.\(name)")
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
    private func rawAxisValue(_ axisName: String, gyro: SCNVector3) -> Double {
        switch axisName {
        case "y": return Double(gyro.y)
        case "z": return Double(gyro.z)
        default: return Double(gyro.x)
        }
    }

    /// The IMU samples at a fixed 200 Hz but its reports arrive in bursts of
    /// three, ~15 ms apart. Summing here and averaging per render tick decimates
    /// the burst properly instead of aliasing it into the cursor.
    private func handleGyro() {
        let runtime = gyroSnapshot()
        guard runtime.enabled else { return }

        let gyro = controller.gyro
        let h = rawAxisValue(runtime.horizontalAxis, gyro: gyro)
        let v = rawAxisValue(runtime.verticalAxis, gyro: gyro)

        inputLock.lock()
        sampleSumH += h
        sampleSumV += v
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
        let sumH = sampleSumH, sumV = sampleSumV, count = sampleCount
        let held = activationHeld
        let recenter = needsRecenter
        var dx = pendingMouseDx, dy = pendingMouseDy
        let scrollX = pendingScrollX, scrollY = pendingScrollY
        sampleSumH = 0; sampleSumV = 0; sampleCount = 0
        needsRecenter = false
        pendingMouseDx = 0; pendingMouseDy = 0
        pendingScrollX = 0; pendingScrollY = 0
        inputLock.unlock()

        diagnostics?.record(sampleCount: count, now: now)

        let runtime = gyroSnapshot()
        // While the activation button is held the controller is being aimed,
        // so nothing observed then is evidence about the sensor's zero.
        let mayLearnBias = runtime.activationButton == nil || !held
        updateAngularVelocity(sumH: sumH, sumV: sumV, count: count, dt: dt, now: now, enabled: runtime.enabled, mayLearnBias: mayLearnBias)

        if runtime.enabled, runtime.activationButton != nil {
            applyLaser(runtime: runtime, held: held, recenter: recenter, dt: dt, stickDx: dx, stickDy: dy)
        } else {
            if runtime.enabled {
                let (gx, gy) = continuousGyroDelta(runtime: runtime, dt: dt)
                dx += gx
                dy += gy
            }
            if dx != 0 || dy != 0 { moveMouseBy(dx: dx, dy: dy) }
        }

        flushScroll(x: scrollX, y: scrollY)
    }

    /// Turns however many (or few) raw samples arrived into a continuously
    /// defined angular velocity. This is what absorbs the burstiness: rather
    /// than moving the cursor when data happens to show up, the cursor always
    /// moves at the current best estimate of how fast the controller is turning.
    private func updateAngularVelocity(sumH: Double, sumV: Double, count: Int, dt: Double, now: CFTimeInterval, enabled: Bool, mayLearnBias: Bool) {
        guard enabled else { return }

        if count > 0 {
            let rawH = sumH / Double(count)
            let rawV = sumV / Double(count)
            lastSampleTime = now

            if mayLearnBias && abs(rawH) < stillnessThreshold && abs(rawV) < stillnessThreshold {
                let alpha = 1 - exp(-dt / biasTimeConstant)
                biasH += (rawH - biasH) * alpha
                biasV += (rawV - biasV) * alpha
            }
            targetRateH = rawH - biasH
            targetRateV = rawV - biasV
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
private struct GyroRuntime {
    var enabled = false
    var sensitivity: Double = 8
    var horizontalAxis = "x"
    var verticalAxis = "y"
    var invertHorizontal = false
    var invertVertical = false
    var activationButton: JoyCon.Button?
    var minCutoff: Double = 2.5

    init(_ config: GyroConfig) {
        enabled = config.enabled
        sensitivity = config.sensitivity
        horizontalAxis = config.horizontalAxis
        verticalAxis = config.verticalAxis
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
