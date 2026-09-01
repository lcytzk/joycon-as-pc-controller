import CoreGraphics
import Foundation
import QuartzCore

/// Identifies what is holding a key down, so two mappings (or two controllers)
/// pressing the same key don't release each other's.
struct OutputKey: Hashable {
    let owner: ObjectIdentifier
    let source: String
}

/// The single writer for every synthetic keyboard event the app produces.
///
/// Two things here are load-bearing:
///
/// 1. **Modifiers are not keys.** A real macOS keyboard never emits
///    keyDown/keyUp for Control/Shift/Command/Option/fn — it emits
///    `flagsChanged`, carrying the changed key's code plus the resulting
///    modifier state, and that event is what updates the system-wide modifier
///    state. Anything watching for a modifier being *held* (push-to-talk,
///    dictation, WeChat's hold-to-talk hotkey) either listens for flagsChanged
///    or polls that state. A keyDown carrying keycode 0x3B touches neither —
///    which is exactly why a keycode viewer happily displays "left control"
///    while the app the shortcut was set in stays silent.
///
/// 2. **Posting runs here, not on the caller's thread.** Callers are on
///    JoyConSwift's IOHID read thread; the `usleep` spacing below (and
///    CGEvent's round trip to the window server) would stall report delivery
///    there and show up as gyro stutter.
final class KeyboardOutput {
    static let shared = KeyboardOutput()

    private let queue = DispatchQueue(label: "GyroKeyMapper.keyboard-output", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    // Refcounted: releasing "ctrl+c" must not drop a Control that "ctrl+v" is
    // still holding.
    private var heldModifiers: [CGKeyCode: Int] = [:]
    private var activeCombos: [OutputKey: String] = [:]
    private var heldMainKeys: [OutputKey: CGKeyCode] = [:]
    private var repeatDeadlines: [OutputKey: CFTimeInterval] = [:]
    private var repeatTimer: DispatchSourceTimer?

    // A real keypress never lands with zero spacing from the modifier before
    // it, and some global-hotkey listeners miss combos that do.
    private let interKeyDelay: useconds_t = 4000

    // A synthetic keyDown does not trigger the driver-level key repeat a real
    // held key produces, and some hold-to-activate listeners watch for that
    // repeat rather than just "is it down". Mirror the user's own keyboard
    // settings, including having repeat turned off.
    private let initialRepeatDelay: CFTimeInterval
    private let repeatInterval: CFTimeInterval
    private let repeatEnabled: Bool

    private init() {
        // Both are stored in 1/60 s ticks; macOS writes 300000 for "Off".
        let initialTicks = (UserDefaults.standard.object(forKey: "InitialKeyRepeat") as? Double) ?? 25
        let repeatTicks = (UserDefaults.standard.object(forKey: "KeyRepeat") as? Double) ?? 6
        repeatEnabled = repeatTicks < 1000
        initialRepeatDelay = max(0.05, initialTicks / 60)
        repeatInterval = max(1.0 / 60, repeatTicks / 60)
    }

    // MARK: - API

    func press(_ combo: String, identifier: OutputKey) {
        queue.async { self.apply(combo, isDown: true, identifier: identifier) }
    }

    func release(_ combo: String, identifier: OutputKey) {
        queue.async { self.apply(combo, isDown: false, identifier: identifier) }
    }

    /// Let go of everything `owner` still holds. A controller disconnecting or
    /// being remapped mid-press must not leave a modifier stuck down for the
    /// whole system.
    func releaseAll(ownedBy owner: ObjectIdentifier) {
        queue.async {
            for (key, combo) in self.activeCombos where key.owner == owner {
                self.apply(combo, isDown: false, identifier: key)
            }
        }
    }

    // MARK: - Combo handling

    /// Press order is modifiers-then-key; release is the reverse, matching a
    /// real keyboard's flagsChanged/keyDown sequence.
    private func apply(_ combo: String, isDown: Bool, identifier: OutputKey) {
        var modifiers: [CGKeyCode] = []
        var mainKey: CGKeyCode?

        for token in combo.lowercased().split(separator: "+").map(String.init) {
            guard let code = keyCodes[token] else { continue }
            if modifierFlagsByKeyCode[code] != nil {
                if !modifiers.contains(code) { modifiers.append(code) }
            } else {
                mainKey = code // last non-modifier token wins if more than one is given
            }
        }
        guard !modifiers.isEmpty || mainKey != nil else { return }

        if isDown {
            guard activeCombos[identifier] == nil else { return }
            activeCombos[identifier] = combo

            for (index, code) in modifiers.enumerated() {
                retainModifier(code)
                if index < modifiers.count - 1 || mainKey != nil { usleep(interKeyDelay) }
            }
            if let mainKey = mainKey {
                postKey(mainKey, down: true)
                if repeatEnabled {
                    heldMainKeys[identifier] = mainKey
                    repeatDeadlines[identifier] = CACurrentMediaTime() + initialRepeatDelay
                    startRepeatTimer()
                }
            }
        } else {
            guard activeCombos.removeValue(forKey: identifier) != nil else { return }
            heldMainKeys.removeValue(forKey: identifier)
            repeatDeadlines.removeValue(forKey: identifier)

            if let mainKey = mainKey {
                postKey(mainKey, down: false)
                if !modifiers.isEmpty { usleep(interKeyDelay) }
            }
            for (index, code) in modifiers.reversed().enumerated() {
                releaseModifier(code)
                if index < modifiers.count - 1 { usleep(interKeyDelay) }
            }
            stopRepeatTimerIfIdle()
        }
    }

    private func retainModifier(_ code: CGKeyCode) {
        let count = (heldModifiers[code] ?? 0) + 1
        heldModifiers[code] = count
        if count == 1 { postFlagsChanged(code) }
    }

    private func releaseModifier(_ code: CGKeyCode) {
        guard let count = heldModifiers[code] else { return }
        if count > 1 {
            heldModifiers[code] = count - 1
            return
        }
        heldModifiers.removeValue(forKey: code)
        postFlagsChanged(code) // flags now reflect the key already being up
    }

    // MARK: - Event posting

    /// Flags as hardware reports them: the generic mask plus the side-specific
    /// device bit for every modifier currently held, and the non-coalesced bit
    /// every real key event carries. Releasing the last modifier therefore
    /// posts flags of exactly `maskNonCoalesced`, same as a real keyboard.
    private func currentFlags() -> CGEventFlags {
        var flags: CGEventFlags = [.maskNonCoalesced]
        for code in heldModifiers.keys {
            if let generic = modifierFlagsByKeyCode[code] { flags.insert(generic) }
            if let device = modifierDeviceMaskByKeyCode[code] { flags.insert(device) }
        }
        return flags
    }

    private func postFlagsChanged(_ code: CGKeyCode) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        event.flags = currentFlags()
        event.post(tap: .cghidEventTap)
    }

    private func postKey(_ code: CGKeyCode, down: Bool, autorepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        var flags = currentFlags()
        // Function keys and arrows carry the fn bit on real hardware, and global
        // hotkey matching compares it (see functionGroupKeyCodes) — without it an
        // F12 reaches the focused app but never fires an F12 global hotkey.
        if functionGroupKeyCodes.contains(code) { flags.insert(.maskSecondaryFn) }
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Auto-repeat

    private func startRepeatTimer() {
        guard repeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + repeatInterval, repeating: min(repeatInterval, 1.0 / 60), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.fireRepeats() }
        timer.resume()
        repeatTimer = timer
    }

    private func fireRepeats() {
        let now = CACurrentMediaTime()
        for (identifier, deadline) in Array(repeatDeadlines) where deadline <= now {
            guard let code = heldMainKeys[identifier] else { continue }
            postKey(code, down: true, autorepeat: true)
            // Skip missed slots outright rather than bursting to catch up.
            repeatDeadlines[identifier] = max(now + repeatInterval, deadline + repeatInterval)
        }
        stopRepeatTimerIfIdle()
    }

    private func stopRepeatTimerIfIdle() {
        guard heldMainKeys.isEmpty, let timer = repeatTimer else { return }
        timer.cancel()
        repeatTimer = nil
    }
}
