import Foundation
import JoyConSwift

/// Which part the controller plays in producing gyro cursor motion.
enum GyroRole {
    /// Owns the cursor: filters, integrates, and posts the movement.
    case driver
    /// Feeds its IMU into the driver's fusion, but posts nothing itself.
    case contributor
    /// Its gyro is not part of the picture at all. Buttons and stick still work.
    case off
}

/// The state the two Joy-Cons have to share while both are connected: which
/// combine profile is live, and — when their IMUs are being fused — the sample
/// bus and the activation state they hold in common.
///
/// Two IOHID threads and two render loops touch this, and the IOHID threads
/// can't afford to block (a stall of a few tens of milliseconds costs dropped
/// reports), so every entry point is one lock around arithmetic and nothing
/// else. No AppKit, no event posting, no allocation in the sampling path.
final class CombineCoordinator {
    struct Snapshot {
        var isCombined = false
        var profile = CombineProfile()
    }

    private let lock = NSLock()
    private var isCombined = false
    private var profile = CombineProfile()

    // Activation lives here rather than per-mapper because the button that
    // arms a fused gyro can sit on either half — in a grip the pair is one
    // device as far as the hands are concerned.
    private var activationHeld = false
    private var needsRecenter = false

    // Samples the non-driving IMU has contributed since the driver last
    // looked, as raw axes — which of them answers to the driver's horizontal
    // and vertical is worked out at runtime by `GyroAlignment`, not configured.
    // Summed rather than averaged here: reports arrive in bursts, and the
    // driver wants the burst decimated against its own tick, not against
    // however many happened to land.
    private var busSum = SIMD3<Double>()
    private var busCount = 0

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(isCombined: isCombined, profile: profile)
    }

    /// Called when a controller connects or disconnects, or the profile is
    /// edited. Anything carried over from the previous arrangement — a
    /// half-full bus, an activation that was held when the other half went
    /// away — describes a setup that no longer exists, so it goes.
    func update(isCombined: Bool, profile: CombineProfile) {
        lock.lock()
        self.isCombined = isCombined
        self.profile = profile
        activationHeld = false
        needsRecenter = false
        busSum = SIMD3<Double>()
        busCount = 0
        lock.unlock()
    }

    func deposit(_ raw: SIMD3<Double>) {
        lock.lock()
        busSum += raw
        busCount += 1
        lock.unlock()
    }

    /// The contributed IMU's mean raw reading since the last call, or nil if it
    /// hasn't reported anything — which is the ordinary case for a tick that
    /// outran the report rate, and also what a Bluetooth stall looks like.
    func drainBus() -> SIMD3<Double>? {
        lock.lock()
        defer {
            busSum = SIMD3<Double>()
            busCount = 0
            lock.unlock()
        }
        guard busCount > 0 else { return nil }
        return busSum / Double(busCount)
    }

    func setActivation(held: Bool) {
        lock.lock()
        activationHeld = held
        if held { needsRecenter = true }
        lock.unlock()
    }

    func toggleActivation() {
        lock.lock()
        activationHeld.toggle()
        if activationHeld { needsRecenter = true }
        lock.unlock()
    }

    /// Reads activation and consumes the one-shot recenter, mirroring how each
    /// mapper drains its own input state per tick.
    func takeActivation() -> (held: Bool, recenter: Bool) {
        lock.lock()
        defer {
            needsRecenter = false
            lock.unlock()
        }
        return (activationHeld, needsRecenter)
    }

    /// Who does what, given which halves are present and what the profile asks
    /// for. Fusion needs a fixed driver rather than a negotiated one, and the
    /// right Joy-Con is the conventional aiming hand — and the side whose gyro
    /// the shipped default config already configures.
    static func role(for type: JoyCon.ControllerType, isCombined: Bool, source: CombineGyroSource) -> GyroRole {
        guard isCombined else { return .driver }
        switch source {
        case .left: return type == .JoyConL ? .driver : .off
        case .right: return type == .JoyConR ? .driver : .off
        case .fused: return type == .JoyConR ? .driver : .contributor
        }
    }
}


/// Averages the two IMUs of a grip-mounted pair into one rate, and decides when
/// it can no longer trust that they are one rigid body.
///
/// Kept separate from `ControllerMapper` because this is where the actual claim
/// of fusing lives — everything else about it is plumbing.
struct GyroFusion {
    /// Running estimate of how far apart the two IMUs are reading, in deg/s.
    private(set) var disagreement: Double = 0

    /// Two sensors bolted into one grip track each other to within noise and
    /// calibration. Past this, sustained, they are not one body: a half has
    /// been pulled out of the grip, and their average describes a motion
    /// neither controller performed.
    var threshold: Double = 30.0
    var timeConstant: Double = 0.5
    /// Mirrors the mapper's own stillness threshold — the rate below which a
    /// reading counts as a hand at rest rather than aiming.
    var stillnessThreshold: Double = 3.0

    init(stillnessThreshold: Double = 3.0) {
        self.stillnessThreshold = stillnessThreshold
    }

    /// The rate to steer by, and whether the zero-offset estimate may move.
    ///
    /// A single sensor cannot tell "held perfectly steady" from "drifting at a
    /// rate that happens to look steady"; two that agree very nearly can, so
    /// the bias gate asks both rather than the average — which would call
    /// +5 and -5 deg/s a controller at rest.
    mutating func combine(
        own: (h: Double, v: Double)?,
        other: (h: Double, v: Double)?,
        dt: Double
    ) -> (rate: (h: Double, v: Double)?, bothSidesStill: Bool) {
        guard let other = other else {
            // Nothing from the other half this tick: either the render loop
            // outran the report rate, or its Bluetooth stalled. Either way this
            // IMU covers the gap — half the point of having two.
            return (own, true)
        }
        guard let own = own else { return (other, true) }

        let gap = max(abs(own.h - other.h), abs(own.v - other.v))
        let alpha = 1 - exp(-dt / timeConstant)
        disagreement += (gap - disagreement) * alpha
        guard disagreement < threshold else { return (own, true) }

        let bothStill = isStill(own) && isStill(other)
        return (((own.h + other.h) / 2, (own.v + other.v) / 2), bothStill)
    }

    /// True while the two are being treated as no longer one rigid body.
    var isSuspended: Bool { disagreement >= threshold }

    private func isStill(_ rate: (h: Double, v: Double)) -> Bool {
        abs(rate.h) < stillnessThreshold && abs(rate.v) < stillnessThreshold
    }
}


/// How far along the second Joy-Con is at joining in — the one thing about
/// fusing that the user can't see for themselves by watching the cursor.
enum FusionStatus: Equatable {
    /// Not fusing: either one Joy-Con, or a profile that names a single side.
    case inactive
    /// Fusing selected, but the second IMU hasn't been placed yet. The driver
    /// runs alone meanwhile, so this is a degraded state, not a broken one.
    case learning
    /// Some of the three axes are placed and the rest aren't — the grip hasn't
    /// been turned every way yet. `placed` counts the ones that are done.
    case partial(placed: Int)
    /// Fusing. `saved` distinguishes a stored calibration from one worked out
    /// live this session, which is exactly the difference the user cares about
    /// when deciding whether to press Save.
    case aligned(saved: Bool)
    /// The two stopped agreeing: a half is out of the grip, or they were never
    /// in one. Running on the driver alone until they agree again.
    case suspended
}

/// How the contributing IMU's axes correspond to the driving IMU's.
///
/// Deliberately expressed sensor-to-sensor, in raw axes, rather than against
/// whichever two axes the user has picked for horizontal and vertical: this way
/// it describes the *hardware* — a fixed property of two controllers in a grip
/// — and stays valid when the user changes their mind about which axis aims
/// where. That is what makes it worth saving instead of relearning every time.
///
/// Entries are optional because a direction the grip has never been turned in
/// can't be known, and pretending otherwise would steer the cursor by a guess.
struct FusionAlignment: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Index into the contributing IMU's raw axes (0 = x, 1 = y, 2 = z).
        var axis: Int
        var sign: Double
    }

    /// Entry `j` says which of the other IMU's axes answers to the driver's
    /// axis `j`, and with what sign.
    var entries: [Entry?]

    init(entries: [Entry?] = [nil, nil, nil]) {
        self.entries = entries
        // A malformed stored value must not be able to index out of bounds
        // later; three axes is the only shape this can have.
        while self.entries.count < 3 { self.entries.append(nil) }
        if self.entries.count > 3 { self.entries = Array(self.entries.prefix(3)) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(entries: try container.decode([Entry?].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    var isEmpty: Bool { entries.allSatisfy { $0 == nil } }

    func knows(driverAxis index: Int) -> Bool {
        index >= 0 && index < entries.count && entries[index] != nil
    }

    /// The other IMU's reading for one of the driver's axes, or nil where that
    /// correspondence isn't known.
    func value(driverAxis index: Int, from other: SIMD3<Double>) -> Double? {
        guard index >= 0, index < entries.count, let entry = entries[index] else { return nil }
        return entry.sign * other[entry.axis]
    }

    /// Fills in what this one doesn't know from `other`. Used to let a saved
    /// calibration cover most of the job while the learner supplies any axis it
    /// didn't record — e.g. after the user re-picks which axis aims sideways.
    func merging(_ other: FusionAlignment) -> FusionAlignment {
        FusionAlignment(entries: (0..<3).map { entries[$0] ?? other.entries[$0] })
    }

    /// `-z,+x,?` — driver x from the other's −z, driver y from its +x, driver z
    /// unknown. One line, and legible in a git diff.
    var textForm: String {
        let names = ["x", "y", "z"]
        return entries.map { entry -> String in
            guard let entry = entry else { return "?" }
            return "\(entry.sign < 0 ? "-" : "+")\(names[entry.axis])"
        }.joined(separator: ",")
    }

    init?(textForm: String) {
        let names = ["x", "y", "z"]
        let tokens = textForm.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard tokens.count == 3 else { return nil }
        var parsed: [Entry?] = []
        for token in tokens {
            if token == "?" {
                parsed.append(nil)
                continue
            }
            guard token.count == 2, let axis = names.firstIndex(of: String(token.dropFirst())) else { return nil }
            let sign: Double
            switch token.first {
            case "-": sign = -1
            case "+": sign = 1
            default: return nil
            }
            parsed.append(Entry(axis: axis, sign: sign))
        }
        self.init(entries: parsed)
    }

    /// Human-readable, for the settings window: "sideways ← −Z, vertical ← +X".
    func description(horizontalAxis: Int, verticalAxis: Int) -> String {
        let names = ["X", "Y", "Z"]
        func part(_ label: String, _ index: Int) -> String {
            guard let entry = entries[index] else { return "\(label) not yet placed" }
            return "\(label) ← \(entry.sign < 0 ? "−" : "+")\(names[entry.axis])"
        }
        return "\(part("sideways", horizontalAxis)), \(part("vertical", verticalAxis))"
    }
}

/// Works out how the second Joy-Con's IMU is oriented relative to the one
/// driving the cursor, so that fusing costs the user no configuration at all:
/// they tune one gyro, the way they would with a single controller, and this
/// places the other sensor against it.
///
/// Two IMUs held in one grip are related by a fixed rotation, and for sensors
/// sitting square to their shells that rotation is a signed axis permutation.
/// So rather than solving for a general rotation, this correlates each of the
/// driver's raw axes against the other IMU's three, and takes the best match
/// with whatever sign the correlation comes out at.
///
/// Nothing is used until the winner is unambiguous. An axis placed wrongly
/// would send the cursor off sideways, which is far worse than not fusing at
/// all — not fusing is merely as good as one Joy-Con.
struct GyroAlignment {
    /// A proposed axis has to keep proposing itself before it is believed.
    ///
    /// This is what separates a real rigid coupling from a coincidence. Two
    /// controllers waved about independently *do* produce brief windows where
    /// one of the six signed axes correlates beautifully with the driver — over
    /// a finite window, unrelated periodic motion is not uncorrelated motion.
    /// What such a window can't do is persist: only sensors actually bolted
    /// together keep agreeing second after second.
    private struct Candidate {
        var proposal: FusionAlignment.Entry?
        var dwell: Double = 0
        var committed: FusionAlignment.Entry?

        mutating func observe(_ proposed: FusionAlignment.Entry?, dt: Double, requiredDwell: Double) {
            guard let proposed = proposed else {
                // Nothing usable right now — a still grip, most likely. That
                // neither confirms nor denies what is already believed, so the
                // commitment stands and only the run of evidence restarts.
                proposal = nil
                dwell = 0
                return
            }
            if proposed == proposal {
                dwell += dt
            } else {
                proposal = proposed
                dwell = 0
            }
            if dwell >= requiredDwell { committed = proposed }
        }
    }

    private var candidates = [Candidate(), Candidate(), Candidate()]

    var timeConstant: Double = 2.0
    /// Mean square rate below which there isn't enough motion to tell the axes
    /// apart — about "slower than 10 deg/s RMS", i.e. a hand at rest.
    var minimumEnergy: Double = 100
    var minimumCorrelation: Double = 0.95
    /// How much better the winning axis has to correlate than the runner-up
    /// before the winner counts as unambiguous.
    var minimumMargin: Double = 1.25
    /// How long the same axis has to keep winning before it is acted on.
    var requiredDwell: Double = 1.0
    /// How far the two IMUs' reported rates of turn may differ, as a fraction,
    /// while still being taken for one rigid body.
    var maximumMagnitudeMismatch: Double = 0.25

    /// `cross[j][i]` — the driver's axis j against the other IMU's axis i.
    private var cross = [SIMD3<Double>](repeating: SIMD3<Double>(), count: 3)
    private var energyDriver = SIMD3<Double>()
    private var energyOther = SIMD3<Double>()
    private var magnitudeGap: Double = 0
    private var magnitudeScale: Double = 0

    /// Correlation alone is too weak a test: it only says the two signals are
    /// proportional, and over a finite window two hands waving independently
    /// throw up such windows regularly. Two gyros on one rigid body owe each
    /// other something stronger — they measure the *same* angular velocity
    /// vector, so however they are turned relative to each other, the length of
    /// that vector has to match. Independent motion violates that constantly,
    /// and it is physics rather than a tuned threshold.
    private var magnitudesAgree: Bool {
        magnitudeScale > minimumEnergy.squareRoot()
            && magnitudeGap < maximumMagnitudeMismatch * magnitudeScale
    }

    /// Claims that survive the structural check.
    ///
    /// Two of the driver's axes claiming the same axis of the other IMU is not
    /// something a rotation can do, so a clash discredits every claim involved
    /// rather than being resolved arbitrarily — the check a per-axis
    /// correlation test can't make on its own.
    private var survivingClaims: [FusionAlignment.Entry?] {
        var entries = candidates.map { $0.committed }
        var claims: [Int: Int] = [:]
        for entry in entries.compactMap({ $0 }) {
            claims[entry.axis, default: 0] += 1
        }
        for index in entries.indices {
            if let entry = entries[index], claims[entry.axis, default: 0] > 1 {
                entries[index] = nil
            }
        }
        return entries
    }

    /// How many of the three axes are placed so far — progress to report while
    /// the user is still turning the grip.
    var placedAxisCount: Int { survivingClaims.compactMap { $0 }.count }

    /// What has been learned, and only once it's a complete answer.
    ///
    /// All or nothing on purpose. Two sensors on one rigid body correspond on
    /// *all three* axes, so a partial answer isn't a partial truth — it is an
    /// answer that hasn't finished being tested, and it is exactly the shape a
    /// coincidence takes: one axis that happened to line up for a second. A
    /// full permutation is far harder to fake, and demanding one costs the user
    /// nothing now that the result can be saved once and reused.
    var result: FusionAlignment {
        let entries = survivingClaims
        guard entries.allSatisfy({ $0 != nil }) else { return FusionAlignment() }
        return FusionAlignment(entries: entries)
    }

    /// Forgets everything.
    mutating func reset() {
        self = GyroAlignment(
            timeConstant: timeConstant,
            minimumEnergy: minimumEnergy,
            minimumCorrelation: minimumCorrelation,
            minimumMargin: minimumMargin,
            requiredDwell: requiredDwell,
            maximumMagnitudeMismatch: maximumMagnitudeMismatch
        )
    }

    init(
        timeConstant: Double = 2.0,
        minimumEnergy: Double = 100,
        minimumCorrelation: Double = 0.95,
        minimumMargin: Double = 1.25,
        requiredDwell: Double = 1.0,
        maximumMagnitudeMismatch: Double = 0.25
    ) {
        self.timeConstant = timeConstant
        self.minimumEnergy = minimumEnergy
        self.minimumCorrelation = minimumCorrelation
        self.minimumMargin = minimumMargin
        self.requiredDwell = requiredDwell
        self.maximumMagnitudeMismatch = maximumMagnitudeMismatch
    }

    mutating func update(driverRaw: SIMD3<Double>, other: SIMD3<Double>, dt: Double) {
        let alpha = 1 - exp(-dt / timeConstant)
        for j in 0..<3 {
            cross[j] += (other * driverRaw[j] - cross[j]) * alpha
        }
        energyDriver += (driverRaw * driverRaw - energyDriver) * alpha
        energyOther += (other * other - energyOther) * alpha

        let ownLength = (driverRaw * driverRaw).sum().squareRoot()
        let otherLength = (other * other).sum().squareRoot()
        magnitudeGap += (abs(otherLength - ownLength) - magnitudeGap) * alpha
        magnitudeScale += (ownLength - magnitudeScale) * alpha

        for j in 0..<3 {
            candidates[j].observe(bestAxis(for: j), dt: dt, requiredDwell: requiredDwell)
        }
    }

    private func bestAxis(for driverAxis: Int) -> FusionAlignment.Entry? {
        let driverEnergy = energyDriver[driverAxis]
        guard driverEnergy > minimumEnergy, magnitudesAgree else { return nil }

        var ranked: [(index: Int, correlation: Double)] = []
        for index in 0..<3 {
            let denominator = (driverEnergy * energyOther[index]).squareRoot()
            guard denominator > 0 else { continue }
            ranked.append((index, cross[driverAxis][index] / denominator))
        }
        ranked.sort { abs($0.correlation) > abs($1.correlation) }

        guard let best = ranked.first, abs(best.correlation) >= minimumCorrelation else { return nil }
        if ranked.count > 1, abs(best.correlation) < abs(ranked[1].correlation) * minimumMargin { return nil }
        return FusionAlignment.Entry(axis: best.index, sign: best.correlation < 0 ? -1 : 1)
    }
}
