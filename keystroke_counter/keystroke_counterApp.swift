//
//  keystroke_counterApp.swift
//  keystroke_counter
//
//  Menu-bar-only app. The label shows BOTH the keystroke and click totals using
//  the compact abbreviation rule; the dropdown (window style) shows full detail.
//
//  PRIVACY: This app records aggregate counts only — never what you type — and
//  keeps everything local unless the user opts in to syncing with their own
//  server. See StatsStore and SyncClient for details.
//

import SwiftUI

@main
struct keystroke_counterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: appDelegate.store, monitor: appDelegate.monitor, sync: appDelegate.sync)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact menu bar label showing TODAY's keystrokes and clicks as
/// `keys | clicks`.
///
/// NOTE on rendering constraints: `MenuBarExtra` renders its label into the
/// system status bar, which restricts custom views. A single `Text` renders
/// reliably there, so we compose both abbreviated counts into one string
/// separated by a pipe (e.g. `703 | 77`). Values use `CountFormatter.abbreviated`.
struct MenuBarLabel: View {
    let store: StatsStore

    var body: some View {
        Text("\(CountFormatter.abbreviated(store.today.keystrokes)) | \(CountFormatter.abbreviated(store.today.clicks))")
    }
}
