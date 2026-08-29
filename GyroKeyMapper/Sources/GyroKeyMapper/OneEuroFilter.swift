import Foundation

/// 1€ filter (Casiez, Roussel & Vogel) — a low-pass whose cutoff rises with the
/// signal's own speed.
///
/// A fixed low-pass forces one choice for two opposite needs: enough smoothing
/// to kill sensor noise and hand tremor while aiming at something, little
/// enough to not lag a flick. This adapts between them, so holding still is
/// steady and fast motion stays responsive. Its DC gain is 1, so the *total*
/// rotation integrated over a movement is unchanged — only its phase is — and
/// pointing stays accurate.
struct OneEuroFilter {
    /// Cutoff (Hz) approached as the signal goes still. Lower = smoother.
    var minCutoff: Double
    /// How sharply the cutoff opens up with speed.
    var beta: Double
    var derivativeCutoff: Double = 1.0

    private var previous: Double?
    private var previousDerivative: Double = 0

    init(minCutoff: Double = 2.5, beta: Double = 0.01) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard dt > 0 else { return previous ?? value }
        guard let previous = previous else {
            self.previous = value
            return value
        }

        let derivative = (value - previous) / dt
        previousDerivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (derivative - previousDerivative)

        let cutoff = minCutoff + beta * abs(previousDerivative)
        let smoothed = previous + Self.alpha(cutoff: cutoff, dt: dt) * (value - previous)
        self.previous = smoothed
        return smoothed
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
    }
}
