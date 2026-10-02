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
    @Bindable var sync: SyncClient

    /// Which time scope the headline totals summarise. Persisted across launches.
    @AppStorage("statsScope") private var scope: StatsScope = .today

    /// Expansion state for the collapsible stat sections. Persisted across launches.
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("showKeys") private var showKeys = true
    @AppStorage("showApps") private var showApps = true
    @AppStorage("showSettings") private var showSettings = false

    /// Launch-at-login toggle, backed by SMAppService.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showResetConfirm = false
    @State private var showGoalEditor = false
    @State private var goalText = ""
    @State private var tokenText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scopePicker

            // Only meaningful once another Mac has synced.
            if store.hasOtherMacs {
                sourcePicker
            }

            if !monitor.isTrusted {
                permissionBanner
            }

            totals

            // Goal progress is a "today" concept: only shown on the Today tab
            // when a goal is set.
            if scope == .today, store.dailyGoal > 0 {
                goalProgress
            }

            liveSpeed

            Divider()
            CollapsibleSection(title: "History", isExpanded: $showHistory) {
                StatsChartView(store: store)
            }

            Divider()
            CollapsibleSection(title: "Most-used keys \(scopeSuffix)", isExpanded: $showKeys) {
                topKeysContent
            }

            Divider()
            CollapsibleSection(title: "Top apps \(scopeSuffix)", isExpanded: $showApps) {
                topAppsContent
            }

            Divider()
            CollapsibleSection(title: "Settings", isExpanded: $showSettings) {
                goalSection
                syncSection
            }

            Divider()
            privacyFooter

            controls
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { sync.syncIfStale() }
    }

    // MARK: Sections

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(StatsScope.allCases) { scope in
                Text(scope.tabTitle).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// This Mac vs all synced Macs. Applies to every section on every tab.
    private var sourcePicker: some View {
        Picker("Source", selection: Binding(get: { store.source }, set: { store.source = $0 })) {
            ForEach(StatsSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
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
        let counts = store.totals(for: scope)
        return VStack(alignment: .leading, spacing: 6) {
            statRow(symbol: "keyboard", label: "Keystrokes", value: counts.keystrokes)
            statRow(symbol: "cursorarrow.click", label: "Clicks", value: counts.clicks)
            // The record to beat — best previous period of this kind. Not shown
            // for Lifetime (no repeating period to compare against).
            if scope != .lifetime {
                recordRow
            }
            Text(totalsCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Today's progress toward the daily goal: a bar with "X / goal · N%" that
    /// turns green with a checkmark once the goal is reached.
    private var goalProgress: some View {
        let reached = store.isDailyGoalReached
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: reached ? "checkmark.circle.fill" : "target")
                    .foregroundStyle(reached ? Color.green : Color.secondary)
                Text(reached ? "Goal reached!" : "Daily goal")
                    .font(.caption).bold()
                    .foregroundStyle(reached ? Color.green : Color.primary)
                Spacer()
                Text("\(CountFormatter.grouped(store.combinedToday)) / \(CountFormatter.grouped(store.dailyGoal)) · \(Int(store.goalFraction * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: store.goalFraction)
                .tint(reached ? Color.green : Color.accentColor)
        }
    }

    /// Row showing the combined-events record for a previous period, with an
    /// info icon whose hover tooltip explains what the record is.
    private var recordRow: some View {
        let record = store.record(for: scope)
        return HStack {
            Image(systemName: "trophy").frame(width: 20)
            Text("Record")
            Spacer()
            if let record {
                Text(CountFormatter.grouped(record.combined))
                    .monospacedDigit()
                    .bold()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(recordTooltip(record))
        }
    }

    /// Hover tooltip text describing the record (keystrokes + clicks combined).
    private func recordTooltip(_ record: (combined: Int, periodStart: Date)?) -> String {
        guard let record else {
            switch scope {
            case .today: return "Your record to beat — set once you've had a full previous day of activity."
            case .week: return "Your record to beat — set once your first full week completes."
            case .month: return "Your record to beat — set once your first full month completes."
            case .lifetime: return ""
            }
        }
        let count = CountFormatter.grouped(record.combined)
        let date = record.periodStart
        switch scope {
        case .today:
            return "Best day so far: \(count) keystrokes + clicks on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .week:
            return "Best week so far: \(count) keystrokes + clicks (week of \(date.formatted(date: .abbreviated, time: .omitted)))."
        case .month:
            return "Best month so far: \(count) keystrokes + clicks in \(date.formatted(.dateTime.month(.wide).year()))."
        case .lifetime:
            return ""
        }
    }

    /// Sub-caption under the totals describing the active scope's period, plus
    /// whose activity it covers when other Macs are synced.
    private var totalsCaption: String {
        guard store.hasOtherMacs else { return periodCaption }
        let macs = store.source == .combined
            ? "\(store.syncedDeviceNames.count + 1) Macs"
            : "this Mac"
        return "\(periodCaption) · \(macs)"
    }

    private var periodCaption: String {
        switch scope {
        case .lifetime:
            return "since \(store.displaySince.formatted(date: .abbreviated, time: .shortened))"
        case .today:
            return "today"
        case .month:
            return Date().formatted(.dateTime.month(.wide).year())
        case .week:
            return "this week"
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

    /// Suffix describing the active scope, used in section titles / empty states.
    private var scopeSuffix: String {
        switch scope {
        case .today: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .lifetime: return "all-time"
        }
    }

    private var topKeysContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            let keys = store.topKeys(for: scope)
            if keys.isEmpty {
                Text("No keys recorded \(scopeSuffix)").font(.caption2).foregroundStyle(.secondary)
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

    private var topAppsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            let apps = store.topApps(for: scope)
            if apps.isEmpty {
                Text("No activity recorded \(scopeSuffix)").font(.caption2).foregroundStyle(.secondary)
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
        // Edited inline rather than via a system `.alert`: an alert with a
        // TextField presented from a MenuBarExtra(.window) panel is torn down the
        // moment the field takes focus (the panel resigns key), so it errors out.
        // An inline editor keeps stable view identity and holds focus.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "target").frame(width: 20)
                Text("Daily goal")
                Spacer()
                if store.dailyGoal > 0 {
                    Text(CountFormatter.grouped(store.dailyGoal)).monospacedDigit()
                } else {
                    Text("off").foregroundStyle(.secondary)
                }
                Button(showGoalEditor ? "Done" : "Set") {
                    if !showGoalEditor {
                        goalText = store.dailyGoal > 0 ? "\(store.dailyGoal)" : ""
                    }
                    showGoalEditor.toggle()
                }
                .controlSize(.small)
            }
            .font(.callout)

            if showGoalEditor {
                HStack {
                    TextField("Events per day (0 to disable)", text: $goalText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveGoal() }
                    Button("Save") { saveGoal() }
                        .controlSize(.small)
                }
                Text("Get a notification when you reach this many keystrokes + clicks in a day.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $sync.isEnabled) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 20)
                    Text("Sync across Macs")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)

            if sync.isEnabled {
                TextField("Server URL (https://…)", text: $sync.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await sync.syncNow() } }
                HStack {
                    SecureField(sync.hasToken ? "Token saved — enter to replace" : "Sync token",
                                text: $tokenText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveToken() }
                    Button("Save") { saveToken() }
                        .controlSize(.small)
                        .disabled(tokenText.isEmpty)
                }
                HStack {
                    Text(syncStatusText)
                        .font(.caption2)
                        .foregroundStyle(syncStatusIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sync now") { Task { await sync.syncNow() } }
                        .controlSize(.small)
                        .disabled(sync.status == .syncing)
                }
            }
        }
    }

    private var syncStatusText: String {
        switch sync.status {
        case .idle:
            return "Not synced yet"
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let others = store.syncedDeviceNames
            let with = others.isEmpty ? "no other Macs yet" : others.joined(separator: ", ")
            return "Synced \(date.formatted(date: .omitted, time: .shortened)) · with \(with)"
        case .failed(let message):
            return message
        }
    }

    private var syncStatusIsError: Bool {
        if case .failed = sync.status { return true }
        return false
    }

    private func saveToken() {
        sync.saveToken(tokenText)
        tokenText = ""
    }

    private func saveGoal() {
        store.dailyGoal = max(0, Int(goalText) ?? 0)
        showGoalEditor = false
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text(sync.isEnabled
                 ? "Counts only — never what you type. Per-day counts sync to your server only."
                 : "Counts only — never what you type. All data stays on this Mac; no network access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                // Let the text wrap to as many lines as it needs instead of
                // truncating to one line with an ellipsis.
                .fixedSize(horizontal: false, vertical: true)
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
        .confirmationDialog("Reset all-time totals on this Mac?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset totals", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This zeroes this Mac's all-time keystroke and click totals and the 'since' date. Your daily history charts, and other synced Macs' totals, are kept.")
        }
    }
}

/// A titled section whose body can be collapsed by clicking its header. Used to
/// let the panel's stat sections be minimised individually.
struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}
