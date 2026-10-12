//
//  NotificationManager.swift
//  keystroke_counter
//
//  Thin wrapper around UserNotifications for milestone alerts. Keeps things
//  non-spammy: the "already reached" bookkeeping lives in StatsStore, so this
//  type only ever fires when explicitly told to.
//

import UserNotifications
import Foundation

@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    private var authorized = false

    private init() {}

    /// Request permission to post local notifications. Safe to call repeatedly.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in NotificationManager.shared.authorized = granted }
        }
    }

    /// Fire a milestone notification for crossing `combinedTotal` events.
    func fireMilestone(_ milestone: Int) {
        guard enabled("notifyMilestones") else { return }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Milestone reached!"
        content.body = "You've logged \(CountFormatter.grouped(milestone)) keystrokes + clicks. Keep going!"
        if enabled("notificationSound") { content.sound = .default }

        // nil trigger => deliver immediately.
        let request = UNNotificationRequest(identifier: "milestone-\(milestone)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Fire a notification for hitting the user's configured daily goal.
    func fireDailyGoal(_ goal: Int) {
        guard enabled("notifyDailyGoal") else { return }
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily goal reached!"
        content.body = "You hit your goal of \(CountFormatter.grouped(goal)) events today."
        if enabled("notificationSound") { content.sound = .default }

        let request = UNNotificationRequest(identifier: "daily-goal-\(goal)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func fireRecord(_ periods: String) {
        post(category: "notifyRecords", title: "New personal best!",
             body: "You've beaten your previous best \(periods) for combined events.")
    }

    func fireAchievement(_ names: String) {
        post(category: "notifyAchievements", title: "Achievement unlocked!", body: names)
    }

    func fireConsistency(_ days: Int) {
        post(category: "notifyConsistency", title: "Weekly goal reached!",
             body: "You've met your daily goal on \(days) days this week.")
    }

    private func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func post(category: String, title: String, body: String) {
        guard authorized, enabled(category) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if enabled("notificationSound") { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "\(category)-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
