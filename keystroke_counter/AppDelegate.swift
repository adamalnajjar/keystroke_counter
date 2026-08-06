//
//  AppDelegate.swift
//  keystroke_counter
//
//  Owns the long-lived model objects (StatsStore + EventMonitor), kicks off the
//  Accessibility-permission flow and event monitoring, and wires event-driven
//  milestone notifications.
//

import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Single source of truth for statistics. Injected into the UI.
    let store = StatsStore()

    /// Raw event source that feeds `store`.
    lazy var monitor = EventMonitor(store: store)

    /// The day (start-of-day) whose goal notification we've already fired, so we
    /// only alert once per day for the configurable daily goal.
    private var goalFiredForDay: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon: this is a menu-bar-only ("agent") app. Done in code so we
        // don't rely on an Info.plist LSUIElement key.
        NSApp.setActivationPolicy(.accessory)

        // Ask for the permissions we need. Both are no-ops if already granted.
        monitor.requestPermission()
        NotificationManager.shared.requestAuthorization()

        // Check milestones after each recorded event (cheap; bookkeeping in store
        // guarantees we never double-fire).
        monitor.onEventRecorded = { [weak self] in
            self?.checkMilestones()
        }

        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    /// Fire any newly-crossed milestone notifications and the daily-goal alert.
    private func checkMilestones() {
        for milestone in store.newlyReachedMilestones() {
            NotificationManager.shared.fireMilestone(milestone)
        }

        // Configurable daily goal: fire at most once per calendar day.
        let goal = store.dailyGoal
        guard goal > 0 else { return }
        let combinedToday = store.today.keystrokes + store.today.clicks
        let todayStart = StatsStore.startOfDay(Date())
        if combinedToday >= goal, goalFiredForDay != todayStart {
            goalFiredForDay = todayStart
            NotificationManager.shared.fireDailyGoal(goal)
        }
    }
}
