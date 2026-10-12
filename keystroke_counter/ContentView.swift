//
//  ContentView.swift
//  keystroke_counter
//
//  The dropdown panel shown from the menu bar. Reads everything from StatsStore.
//

import SwiftUI
import ServiceManagement

private enum ActivityTab: String {
    case keys, apps
}

struct ContentView: View {
    let store: StatsStore
    let monitor: EventMonitor
    @Bindable var sync: SyncClient
    let game: GameProgress

    /// Which time scope the headline totals summarise. Persisted across launches.
    @AppStorage("statsScope") private var scope: StatsScope = .today

    /// Expansion state for the collapsible stat sections. Persisted across launches.
    @AppStorage("showHistory") private var showHistory = true
    @AppStorage("showTopActivity") private var showTopActivity = true
    @AppStorage("topActivityTab") private var activityTab: ActivityTab = .keys
    @AppStorage("showSettings") private var showSettings = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("prioritiseCombinedCount") private var prioritiseCombinedCount = false
    @AppStorage("showAchievements") private var showAchievements = false
    @AppStorage("weeklyGoalDays") private var weeklyGoalDays = 4
    @AppStorage("notifyDailyGoal") private var notifyDailyGoal = true
    @AppStorage("notifyMilestones") private var notifyMilestones = true
    @AppStorage("notifyRecords") private var notifyRecords = true
    @AppStorage("notifyAchievements") private var notifyAchievements = true
    @AppStorage("notifyConsistency") private var notifyConsistency = true
    @AppStorage("notificationSound") private var notificationSound = true

    /// Launch-at-login toggle, backed by SMAppService.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showResetConfirm = false
    @State private var showRecordDetails = false
    @State private var showGoalEditor = false
    @State private var goalText = ""
    @State private var tokenText = ""
    @State private var showSyncEditor = false

    /// Measured height of the scrollable middle section, so the panel can be
    /// exactly as tall as its content until it hits the screen limit.
    @State private var scrollContentHeight: CGFloat = 600

    var body: some View {
        // Tabs pinned at the top, Quit pinned at the bottom, everything
        // else scrolls once the panel would be taller than the screen.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                scopePicker

                // Only meaningful once another Mac has synced.
                if store.hasOtherMacs {
                    sourcePicker
                }
            }
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 10)

            ScrollView(.vertical) {
                scrollingContent
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        scrollContentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(scrollContentHeight, maxScrollHeight))

            VStack(alignment: .leading, spacing: 12) {
                Divider()
                privacyFooter
                controls
            }
            .padding([.horizontal, .bottom], 14)
        }
        .frame(width: 320)
        .onAppear { sync.syncIfStale() }
    }

    /// Room for the scrolling section: the screen's usable height minus the
    /// pinned header and footer, with a margin below the panel.
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 190)
    }

    private var scrollingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !monitor.isTrusted {
                permissionBanner
            }

            totals

            // Goal progress is a "today" concept: only shown on the Today tab
            // when a goal is set.
            if scope == .today, store.dailyGoal > 0 {
                goalProgress
            }

            Divider()
            CollapsibleSection(title: "Achievements", isExpanded: $showAchievements) {
                achievementsSection
            }

            Divider()
            CollapsibleSection(title: "Top activity \(scopeSuffix)", isExpanded: $showTopActivity) {
                Picker("Activity", selection: $activityTab) {
                    Text("Keys").tag(ActivityTab.keys)
                    Text("Apps").tag(ActivityTab.apps)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                if activityTab == .keys {
                    topKeysContent
                } else {
                    topAppsContent
                }
            }

            Divider()
            CollapsibleSection(title: "History", isExpanded: $showHistory) {
                StatsChartView(store: store)
            }

            Divider()
            CollapsibleSection(title: "Settings", isExpanded: $showSettings) {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                Toggle("Prioritise combined count", isOn: $prioritiseCombinedCount)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                Text("Show keystrokes + clicks as one total in the panel, menu bar and history chart.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                goalSection
                Stepper("Weekly goal: \(weeklyGoalDays) days", value: $weeklyGoalDays, in: 1...7)
                    .font(.callout)
                Text("Days this week that meet your current daily goal. Days off don't erase earned badges.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                notificationSettings
                syncSection
                settingsControls
            }
        }
    }

    // MARK: Sections

    private var achievementsSection: some View {
        let summary = store.gameSummary()
        return VStack(alignment: .leading, spacing: 10) {
            if store.dailyGoal > 0 {
                HStack {
                    Text("Weekly consistency").font(.caption).bold()
                    Spacer()
                    Text("\(summary.weeklyGoalDays) / \(weeklyGoalDays) days").font(.caption).monospacedDigit()
                }
                ProgressView(value: min(1, Double(summary.weeklyGoalDays) / Double(max(1, weeklyGoalDays))))
                    .tint(summary.weeklyGoalDays >= weeklyGoalDays ? .green : .accentColor)
            } else {
                Text("Set a daily goal to track weekly consistency.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            let publicBadges = Achievement.all.filter { !$0.hiddenUntilEarned }
            let secretBadges = Achievement.all.filter { $0.hiddenUntilEarned && game.status(for: $0, summary: summary).earnedTier > 0 }
            let visibleBadges = publicBadges + secretBadges
            let earnedCount = visibleBadges.filter { game.status(for: $0, summary: summary).earnedTier > 0 }.count
            Text("\(earnedCount) of \(visibleBadges.count) challenges earned · \(game.goalDays.count) goal days")
                .font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 16) {
                ForEach(publicBadges) { badge in
                    AchievementTile(status: game.status(for: badge, summary: summary))
                }
            }
            ForEach(secretBadges) { badge in
                HStack {
                    Spacer()
                    AchievementTile(status: game.status(for: badge, summary: summary))
                        .frame(width: 90)
                    Spacer()
                }
            }
            Text("Gold icons are earned. Blue rings track the next target. Uses all synced Macs; earned tiers and progress are kept.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications").font(.caption).foregroundStyle(.secondary)
            Toggle("Daily goal", isOn: $notifyDailyGoal)
            Toggle("Lifetime milestones", isOn: $notifyMilestones)
            Toggle("Personal bests", isOn: $notifyRecords)
            Toggle("Achievements", isOn: $notifyAchievements)
            Toggle("Weekly consistency", isOn: $notifyConsistency)
            Toggle("Notification sound", isOn: $notificationSound)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
    }

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
            if prioritiseCombinedCount {
                statRow(symbol: "sum", label: "Combined events", value: counts.keystrokes + counts.clicks)
            } else {
                statRow(symbol: "keyboard", label: "Keystrokes", value: counts.keystrokes)
                statRow(symbol: "cursorarrow.click", label: "Clicks", value: counts.clicks)
            }
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
    /// clickable info icon explaining which previous period set the record.
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
            Button {
                showRecordDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Explain record")
            .popover(isPresented: $showRecordDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Record to beat").font(.headline)
                    Text(recordTooltip(record))
                    Text("Records use keystrokes + clicks from previous calendar periods, for the Mac selection shown above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 250)
            }
        }
    }

    /// Popup text describing the record (keystrokes + clicks combined).
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
                // Text fields only exist while editing (or before setup), so
                // they can't grab focus — and your typing — whenever the
                // panel opens.
                if showSyncEditor || !sync.isConfigured {
                    syncEditor
                } else {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(sync.serverHost ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Edit") { showSyncEditor = true }
                            .controlSize(.small)
                    }
                    .font(.callout)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(syncStatusText)
                        .font(.caption2)
                        .foregroundStyle(syncStatusIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if sync.isConfigured {
                        Button("Sync now") { Task { await sync.syncNow() } }
                            .controlSize(.small)
                            .disabled(sync.status == .syncing)
                    }
                }
            }
        }
    }

    private var syncEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            if sync.isConfigured {
                HStack {
                    Spacer()
                    Button("Done") {
                        showSyncEditor = false
                        Task { await sync.syncNow() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var syncStatusText: String {
        let last = sync.lastSynced.map { "last synced \($0.formatted(date: .omitted, time: .shortened))" }
        switch sync.status {
        case .needsSetup:
            return "Add your server URL and token to start syncing."
        case .syncing:
            return "Syncing…"
        case .synced:
            let others = store.syncedDeviceNames
            let with = others.isEmpty ? "no other Macs yet" : others.joined(separator: ", ")
            return "Synced \(sync.lastSynced?.formatted(date: .omitted, time: .shortened) ?? "") · with \(with)"
        case .retrying(let reason):
            return [reason, last, "retrying"].compactMap { $0 }.joined(separator: " · ")
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
        // Once set up, fold back to the compact row.
        if sync.isConfigured { showSyncEditor = false }
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
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private var settingsControls: some View {
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
