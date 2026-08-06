//
//  KeyName.swift
//  keystroke_counter
//
//  Maps a key event to a short, readable, PRIVACY-SAFE name for frequency
//  tallies. We only ever produce a label for a single key press — never a
//  sequence. For character keys we use `charactersIgnoringModifiers` (lowercased
//  so "a" and "Shift+a" tally together); for non-character keys we map common
//  key codes to names, falling back to "key<code>".
//

import AppKit

enum KeyName {

    /// Produce a readable name for a keyDown event.
    static func from(_ event: NSEvent) -> String {
        // Named special keys first (arrows, return, delete, ...).
        if let named = specialKeys[event.keyCode] {
            return named
        }
        // Character-producing keys: use the base character, ignoring modifiers,
        // lowercased so case variants aggregate together.
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let trimmed = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == " " || chars == " " { return "space" }
            if !trimmed.isEmpty { return trimmed.lowercased() }
        }
        // Unknown / non-printing key: fall back to the raw key code.
        return "key\(event.keyCode)"
    }

    /// Common virtual key codes that don't yield a useful character.
    private static let specialKeys: [UInt16: String] = [
        36: "return",
        48: "tab",
        49: "space",
        51: "delete",
        53: "escape",
        76: "enter",
        117: "forward delete",
        123: "left",
        124: "right",
        125: "down",
        126: "up",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        115: "home", 119: "end",
        116: "page up", 121: "page down",
    ]
}
