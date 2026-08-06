//
//  NotificationManager.swift
//  keystroke_counter
//
//  Thin wrapper around UserNotifications for milestone alerts. Keeps things
//  non-spammy: the "already reached" bookkeeping lives in StatsStore, so this
//  type only ever fires when explicitly told to.
//

import UserNotifications

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
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Milestone reached!"
        content.body = "You've logged \(CountFormatter.grouped(milestone)) keystrokes + clicks. Keep going!"
        content.sound = .default

        // nil trigger => deliver immediately.
        let request = UNNotificationRequest(identifier: "milestone-\(milestone)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Fire a notification for hitting the user's configured daily goal.
    func fireDailyGoal(_ goal: Int) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily goal reached!"
        content.body = "You hit your goal of \(CountFormatter.grouped(goal)) events today."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "daily-goal-\(goal)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
