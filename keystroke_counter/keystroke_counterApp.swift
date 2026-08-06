//
//  keystroke_counterApp.swift
//  keystroke_counter
//
//  Menu-bar-only app. The label shows BOTH the keystroke and click totals using
//  the compact abbreviation rule; the dropdown (window style) shows full detail.
//
//  PRIVACY: This app records aggregate counts only — never what you type — and
//  keeps everything local with no network access. See StatsStore for details.
//

import SwiftUI

@main
struct keystroke_counterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: appDelegate.store, monitor: appDelegate.monitor)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact menu bar label showing keystrokes and clicks side by side.
///
/// NOTE on rendering constraints: `MenuBarExtra` renders its label into the
/// system status bar, which restricts custom views (it effectively wants a
/// template image + text). A stacked two-line SwiftUI view does NOT render
/// reliably there. The reliable approach — used here — is a single-line
/// `Label`-free HStack of small SF Symbols and abbreviated numbers, which the
/// status bar renders as expected. Values use `CountFormatter.abbreviated`.
struct MenuBarLabel: View {
    let store: StatsStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
            Text(CountFormatter.abbreviated(store.keystrokeCount))
            Image(systemName: "cursorarrow.click")
            Text(CountFormatter.abbreviated(store.clickCount))
        }
    }
}
