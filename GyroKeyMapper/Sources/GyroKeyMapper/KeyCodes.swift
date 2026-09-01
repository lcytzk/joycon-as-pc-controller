import Foundation
import CoreGraphics

// Standard macOS ANSI virtual keycodes (HIToolbox/Events.h), keyed by a
// lowercase human-readable name so the JSON config stays readable.
let keyCodes: [String: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
    "equal": 0x18, "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D,
    "rightbracket": 0x1E, "o": 0x1F, "u": 0x20, "leftbracket": 0x21,
    "i": 0x22, "p": 0x23, "return": 0x24, "enter": 0x24, "l": 0x25,
    "j": 0x26, "quote": 0x27, "k": 0x28, "semicolon": 0x29,
    "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C, "n": 0x2D, "m": 0x2E,
    "period": 0x2F, "tab": 0x30, "space": 0x31, "grave": 0x32,
    "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
    // Left/right modifier variants are genuinely different virtual keycodes on
    // macOS. The bare name ("command", "option"/"alt", "control"/"ctrl",
    // "shift") is the left side; "left..."/"right..." are explicit aliases so
    // you never have to remember that convention.
    "command": 0x37, "cmd": 0x37, "leftcommand": 0x37, "leftcmd": 0x37,
    "rightcommand": 0x36, "rightcmd": 0x36,
    "shift": 0x38, "leftshift": 0x38, "rightshift": 0x3C,
    "capslock": 0x39,
    "option": 0x3A, "alt": 0x3A, "leftoption": 0x3A, "leftalt": 0x3A,
    "rightoption": 0x3D, "rightalt": 0x3D,
    "control": 0x3B, "ctrl": 0x3B, "leftcontrol": 0x3B, "leftctrl": 0x3B,
    "rightcontrol": 0x3E, "rightctrl": 0x3E,
    "function": 0x3F, "fn": 0x3F,
    "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
    "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
    "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
    "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    "help": 0x72, "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75,
    "end": 0x77, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
]

// Which keycodes are modifiers, and the generic CGEventFlags each contributes.
// Keyed by code rather than by name so the left/right aliases can't disagree
// with each other, and so an event can be classified from the code alone.
let modifierFlagsByKeyCode: [CGKeyCode: CGEventFlags] = [
    0x37: .maskCommand, 0x36: .maskCommand,     // left / right command
    0x38: .maskShift, 0x3C: .maskShift,         // left / right shift
    0x3A: .maskAlternate, 0x3D: .maskAlternate, // left / right option
    0x3B: .maskControl, 0x3E: .maskControl,     // left / right control
    0x39: .maskAlphaShift,                      // caps lock
    0x3F: .maskSecondaryFn,                     // fn
]

// Keys macOS puts in the "function-key group". Hardware reports the fn bit
// (NX_SECONDARYFNMASK / .maskSecondaryFn) alongside these, and the window
// server's global-hotkey matching compares it: a synthetic F12 posted without
// the bit does not match a hotkey registered from a real F12 press (iTerm2's
// hotkey window, Carbon RegisterEventHotKey generally), even though a focused
// app still sees the key perfectly well — AppKit re-derives the flag from the
// keycode when it builds the NSEvent, which is why a key-code viewer happily
// shows "F12" for an event no global hotkey will accept.
let functionGroupKeyCodes: Set<CGKeyCode> = Set([
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
    "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    "left", "right", "up", "down",
    "help", "home", "pageup", "forwarddelete", "end", "pagedown",
].compactMap { keyCodes[$0] })

// The side-specific bit hardware sets alongside the generic mask
// (NX_DEVICE*KEYMASK in IOKit's IOLLEvent.h — not exposed as CGEventFlags
// constants). A listener has no other way to tell left Control from right
// Control by flags alone, so a shortcut recorded from a real keyboard is
// matched against these; an event missing them looks like neither side.
let modifierDeviceMaskByKeyCode: [CGKeyCode: CGEventFlags] = [
    0x3B: CGEventFlags(rawValue: 0x00000001), // left control
    0x3E: CGEventFlags(rawValue: 0x00002000), // right control
    0x38: CGEventFlags(rawValue: 0x00000002), // left shift
    0x3C: CGEventFlags(rawValue: 0x00000004), // right shift
    0x37: CGEventFlags(rawValue: 0x00000008), // left command
    0x36: CGEventFlags(rawValue: 0x00000010), // right command
    0x3A: CGEventFlags(rawValue: 0x00000020), // left option
    0x3D: CGEventFlags(rawValue: 0x00000040), // right option
]

// Preferred display name per keycode, for turning a recorded physical
// keypress back into a config string. Several names can map to the same
// code (e.g. "alt"/"option"); this picks one canonical form per code.
private let canonicalKeyNameOrder: [String] = [
    "a", "s", "d", "f", "h", "g", "z", "x", "c", "v", "b", "q",
    "w", "e", "r", "y", "t",
    "1", "2", "3", "4", "6", "5", "equal", "9", "7", "minus", "8", "0",
    "rightbracket", "o", "u", "leftbracket",
    "i", "p", "return", "l", "j", "quote", "k", "semicolon",
    "backslash", "comma", "slash", "n", "m", "period",
    "tab", "space", "grave", "delete", "escape",
    "rightcommand", "leftcommand", "leftshift", "capslock", "leftalt",
    "leftctrl", "rightshift", "rightalt", "rightctrl", "fn",
    "volumeup", "volumedown", "mute",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10",
    "f11", "f12", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
    "help", "home", "pageup", "forwarddelete", "end", "pagedown",
    "left", "right", "down", "up",
]

let keyCodeToCanonicalName: [CGKeyCode: String] = {
    var result: [CGKeyCode: String] = [:]
    for name in canonicalKeyNameOrder {
        guard let code = keyCodes[name], result[code] == nil else { continue }
        result[code] = name
    }
    return result
}()
