import Foundation

@main
struct GameProgressChecks {
    @MainActor
    static func main() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
        }
        func row(_ day: Int, _ keys: Int, _ clicks: Int = 0) -> DailyStats {
            DailyStats(day: calendar.startOfDay(for: date(day)), keystrokes: keys, clicks: clicks)
        }
        let now = date(7)
        let days = [row(1, 90), row(5, 70, 30), row(6, 100), row(7, 70, 40), row(8, 999)]
        let summary = GameSummary.calculate(days: days, lifetime: 1_000_000, goal: 100, now: now, calendar: calendar)
        precondition(summary.goalDays.count == 3, "Goal uses keys + clicks, including equality, and ignores future days")
        precondition(summary.weeklyGoalDays == 3, "Week counts qualifying days once")
        precondition(summary.recordKeys.count == 2, "Day and week beat prior periods; first month has no record")
        precondition(summary.eligibleBadges == ["million"], "Lifetime badge unlocks at exact threshold")
        let disabled = GameSummary.calculate(days: days, lifetime: 999_999, goal: 0, now: now, calendar: calendar)
        precondition(disabled.goalDays.isEmpty && disabled.weeklyGoalDays == 0 && disabled.eligibleBadges.isEmpty)
        let tied = GameSummary.calculate(days: [row(6, 100), row(7, 100)], lifetime: 0, goal: 100, now: now, calendar: calendar)
        precondition(tied.recordKeys.isEmpty, "Tying a record is not a new personal best")
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let monthRecord = GameSummary.calculate(days: [DailyStats(day: september, keystrokes: 100), row(7, 101)],
                                               lifetime: 5_000_000, goal: 100, now: now, calendar: calendar)
        precondition(monthRecord.recordKeys.contains { $0.hasPrefix("month-") }, "Month compares against prior calendar months")
        precondition(monthRecord.eligibleBadges == ["million", "five-million"])
        let nextWeek = GameSummary.calculate(days: days, lifetime: 0, goal: 100, now: date(12), calendar: calendar)
        precondition(nextWeek.weeklyGoalDays == 0, "Weekly progress resets with the calendar week")

        let suite = "KeystrokeCounterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let game = GameProgress(defaults: defaults)
        game.apply(summary: summary, goalEnabled: true, notify: false, now: now)
        precondition(game.goalDays.count == 3 && game.unlocked == ["first-goal", "million"])
        let saved = defaults.stringArray(forKey: "celebratedRecords")!
        game.apply(summary: summary, goalEnabled: true, notify: false, now: now)
        precondition(defaults.stringArray(forKey: "celebratedRecords")!.count == saved.count, "Records are deduplicated")
        let reloaded = GameProgress(defaults: defaults)
        precondition(reloaded.unlocked == game.unlocked && reloaded.goalDays == game.goalDays, "Badges survive relaunch")
        let lowerGoal = GameSummary.calculate(days: days, lifetime: 0, goal: 1, now: now, calendar: calendar)
        reloaded.apply(summary: lowerGoal, goalEnabled: true, notify: false, now: now)
        precondition(reloaded.goalDays.count == 3, "Changing the goal doesn't retroactively credit more history")
        precondition(reloaded.unlocked.contains("million"), "Resetting totals doesn't remove earned badges")
        let lounge = Achievement.all.first { $0.id == "five-million" }!
        for (value, expectedTier, expectedProgress) in [(4_000_000, 0, 0.8), (5_000_000, 1, 0.0),
                                                      (10_000_000, 2, 0.0), (17_500_000, 2, 0.5),
                                                      (25_000_000, 3, 0.0), (50_000_000, 4, 0.0),
                                                      (100_000_000, 5, 1.0)] {
            let tier = lounge.targets.filter { value >= $0 }.count
            let status = AchievementStatus(badge: lounge, value: value, earnedTier: tier)
            precondition(status.earnedTier == expectedTier && abs(status.progress - expectedProgress) < 0.0001,
                         "Lounge tiers reset the ring and progress only through the next interval")
        }
        let secret = Achievement.all.first { $0.id == "billionaires-club" }!
        precondition(secret.hiddenUntilEarned && secret.targets == [1_000_000_000])
        precondition(Achievement.all.filter { !$0.hiddenUntilEarned }.count == 9)
        var milestone = summary
        milestone.metrics = ChallengeMetrics(events: 10_000_000, keystrokes: 1_000_000, clicks: 100_000,
                                             spaces: 10_000, appEvents: 100_000, topApp: "Xcode")
        reloaded.apply(summary: milestone, goalEnabled: true, notify: false, now: now)
        precondition(reloaded.earnedTiers["five-million"] == 2)
        precondition(reloaded.earnedTiers["keyboard-voyager"] == 2 && reloaded.earnedTiers["click-collector"] == 2)
        precondition(reloaded.earnedTiers["space-cadet"] == 1 && reloaded.earnedTiers["app-devotee"] == 1)
        precondition(reloaded.status(for: secret, summary: milestone).earnedTier == 0, "Secret remains hidden below a billion")
        reloaded.flush()
        let restored = GameProgress(defaults: defaults)
        restored.apply(summary: disabled, goalEnabled: false, notify: false, now: now)
        precondition(restored.highWater["five-million"] == 10_000_000 && restored.earnedTiers["five-million"] == 2,
                     "Earned tiers and progress survive relaunch and reset")
        milestone.metrics.events = 1_000_000_000
        restored.apply(summary: milestone, goalEnabled: true, notify: false, now: now)
        precondition(restored.status(for: secret, summary: milestone).complete, "Secret appears only at its threshold")
        restored.flush()
        let firstFinish = Achievement.all.first { $0.id == "first-goal" }!
        let firstStatus = game.status(for: firstFinish, summary: summary)
        precondition(calendar.isDate(firstStatus.earnedDates[1]!, inSameDayAs: date(5)),
                     "Goal achievement date is recovered from credited days")
        precondition(firstStatus.inferredTiers.contains(1))
        precondition(!firstStatus.tooltip.contains("Recorded:"), "Achievement info omits current count")
        let knownHistory = GameSummary.calculate(days: [row(6, 999_900), row(7, 100)], lifetime: 1_000_000,
                                                 goal: 0, now: now, calendar: calendar)
        precondition(knownHistory.historicalTierDates["million:1"] == calendar.startOfDay(for: now))
        precondition(summary.historicalTierDates["million:1"] == nil,
                     "Incomplete history must not invent lifetime unlock dates")
        let newSuite = "KeystrokeCounterDates-\(UUID().uuidString)"
        let dateDefaults = UserDefaults(suiteName: newSuite)!
        defer { dateDefaults.removePersistentDomain(forName: newSuite) }
        let fresh = GameProgress(defaults: dateDefaults)
        fresh.apply(summary: disabled, goalEnabled: false, notify: false, now: now)
        fresh.apply(summary: milestone, goalEnabled: false, notify: true, now: now)
        precondition(fresh.earnedDates["five-million:1"] == now.timeIntervalSince1970 &&
                     fresh.earnedDates["five-million:5"] == now.timeIntervalSince1970,
                     "Each newly crossed tier gets its unlock date")
        let dateRestored = GameProgress(defaults: dateDefaults)
        dateRestored.apply(summary: milestone, goalEnabled: false, notify: true, now: date(8))
        precondition(dateRestored.earnedDates["five-million:1"] == now.timeIntervalSince1970,
                     "Unlock dates survive relaunch and never get overwritten")
        fresh.flush()
        dateRestored.flush()
        print("Gamification checks passed")
    }
}
