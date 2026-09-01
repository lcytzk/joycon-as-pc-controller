import Foundation
import JoyConSwift

/// Per-controller press/release bookkeeping.
///
/// Exists for one rule, which is easy to get wrong and worth being able to test
/// without a controller plugged in: **a release undoes what the press did**, not
/// what the button would mean now. Press A (holding "z"), then hold FN, then
/// release A — look the binding up afresh and you get FN's binding for A, so "z"
/// is never released and stays down for the whole system.
///
/// Deliberately knows nothing about which FN keys are held: that state is shared
/// between the two halves and lives in `CombineCoordinator`. What a button does
/// arrives here as `engaged`. A button's press and release always come from the
/// same controller, so `held` is correctly per-controller.
///
/// Owned by the IOHID read thread, under the mapper's input lock so the mapping
/// can be reset from elsewhere. Does nothing but bookkeeping.
struct ButtonSession {
    enum Outcome: Equatable {
        /// Nothing to emit: an unbound button, a release of one, or a button
        /// pressed while the FN state is ambiguous.
        case none
        case press(ButtonAction)
        case release(ButtonAction)
    }

    private var held: [JoyCon.Button: ButtonAction] = [:]

    mutating func handle(
        button: JoyCon.Button,
        name: String,
        isDown: Bool,
        base: [String: ButtonAction],
        fn: FnConfig,
        engaged: [String]
    ) -> Outcome {
        if isDown {
            guard let action = fn.action(for: name, base: base, engaged: engaged) else { return .none }
            held[button] = action
            return .press(action)
        }

        guard let action = held.removeValue(forKey: button) else { return .none }
        return .release(action)
    }

    /// Called when the mapping is re-resolved and every held key has been let go
    /// of anyway.
    mutating func reset() {
        held.removeAll()
    }
}
