//
//  CountFormatter.swift
//  keystroke_counter
//
//  Shared helpers for turning raw counts into compact, human-friendly strings.
//  Privacy note: these helpers only ever see aggregate counts — never any
//  typed content.
//

import Foundation

/// Formatting helpers used by the menu bar label (compact) and the panel (full).
enum CountFormatter {

    /// Compact abbreviation used in the menu bar label, where space is tight.
    ///
    /// Rules (floor everywhere — we never round up so the number shown is never
    /// larger than the true count):
    /// - value < 10_000        → full integer          (e.g. `9999`, `500`, `0`)
    /// - value >= 10_000       → floor to thousands + "k" (e.g. `11999` → `11k`)
    /// - value >= 1_000_000    → floor to millions + "M"  (e.g. `1_000_000` → `1M`)
    static func abbreviated(_ value: Int) -> String {
        if value < 10_000 {
            return "\(value)"
        }
        if value < 1_000_000 {
            return "\(value / 1_000)k"
        }
        return "\(value / 1_000_000)M"
    }

    /// Full, grouped representation for use inside the dropdown panel where we
    /// have room (e.g. `1,234,567`).
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
