//
//  ContentView.swift
//  keystroke_counter
//
//  The dropdown panel shown from the menu bar. Reads everything from StatsStore.
//

import SwiftUI
import ServiceManagement

struct ContentView: View {
    let store: StatsStore
    let monitor: EventMonitor

    /// Launch-at-login toggle, backed by SMAppService.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showResetConfirm = false
    @State private var showGoalEditor = false
    @State private var goalText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !monitor.isTrusted {
                permissionBanner
            }

            totals
            liveSpeed

            Divider()
            StatsChartView(store: store)

            Divider()
            topKeysSection

            Divider()
            topAppsSection

            Divider()
            goalSection

            Divider()
            privacyFooter

            controls
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "keyboard")
            Text("Keystroke Counter")
                .font(.headline)
            Spacer()
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Accessibility permission needed")
                .font(.caption).bold()
            Text("Grant Accessibility access so global keystrokes can be counted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Open Settings") { monitor.requestPermission() }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow(symbol: "keyboard", label: "Keystrokes", value: store.keystrokeCount)
            statRow(symbol: "cursorarrow.click", label: "Clicks", value: store.clickCount)
            Text("since \(store.since.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statRow(symbol: String, label: String, value: Int) -> some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 20)
            Text(label)
            Spacer()
            Text(CountFormatter.grouped(value))
                .monospacedDigit()
                .bold()
        }
    }

    private var liveSpeed: some View {
        // TimelineView re-evaluates on a 2s cadence (no Combine needed), giving a
        // live rolling readout as the ring buffer in the store ages out.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            HStack {
                Image(systemName: "speedometer").frame(width: 20)
                Text("Typing speed")
                Spacer()
                Text("\(store.keysPerMinute()) kpm · \(store.wordsPerMinute()) wpm")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var topKeysSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Most-used keys today")
                .font(.caption).foregroundStyle(.secondary)
            let keys = store.topKeys()
            if keys.isEmpty {
                Text("No keys yet today").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(keys, id: \.name) { entry in
                    HStack {
                        Text(entry.name).monospaced()
                        Spacer()
                        Text(CountFormatter.grouped(entry.count)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top apps today")
                .font(.caption).foregroundStyle(.secondary)
            let apps = store.topApps()
            if apps.isEmpty {
                Text("No activity yet today").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(apps, id: \.name) { entry in
                    HStack {
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Text(CountFormatter.grouped(entry.count)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var goalSection: some View {
        HStack {
            Image(systemName: "target").frame(width: 20)
            Text("Daily goal")
            Spacer()
            if store.dailyGoal > 0 {
                Text(CountFormatter.grouped(store.dailyGoal)).monospacedDigit()
            } else {
                Text("off").foregroundStyle(.secondary)
            }
            Button("Set") {
                goalText = store.dailyGoal > 0 ? "\(store.dailyGoal)" : ""
                showGoalEditor = true
            }
            .controlSize(.small)
        }
        .font(.callout)
        .alert("Daily goal", isPresented: $showGoalEditor) {
            TextField("Events per day (0 to disable)", text: $goalText)
            Button("Save") {
                store.dailyGoal = max(0, Int(goalText) ?? 0)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Get a notification when you reach this many keystrokes + clicks in a day.")
        }
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Counts only — never what you type. All data stays on this Mac; no network access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Revert the toggle if the OS refused the change.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Reset") { showResetConfirm = true }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .confirmationDialog("Reset all-time totals?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset totals", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This zeroes your all-time keystroke and click totals and the 'since' date. Your daily history charts are kept.")
        }
    }
}
