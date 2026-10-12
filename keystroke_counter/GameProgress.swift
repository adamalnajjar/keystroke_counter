import Foundation
import Observation

enum ChallengeMetric {
    case goalDays, events, keystrokes, clicks, spaces, appEvents
}

struct Achievement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let metric: ChallengeMetric
    let targets: [Int]
    var hiddenUntilEarned = false

    static let all = [
        Achievement(id: "first-goal", title: "First finish", detail: "Days you have reached your daily goal", symbol: "flag.checkered", metric: .goalDays, targets: [1]),
        Achievement(id: "ten-goals", title: "Finding a rhythm", detail: "Days you have reached your daily goal", symbol: "sparkles", metric: .goalDays, targets: [10, 25, 50]),
        Achievement(id: "fifty-goals", title: "Steady hand", detail: "Days you have reached your daily goal", symbol: "hand.thumbsup.fill", metric: .goalDays, targets: [50, 100, 250]),
        Achievement(id: "million", title: "Million club", detail: "Combined keystrokes and mouse clicks", symbol: "star.fill", metric: .events, targets: [1_000_000]),
        Achievement(id: "five-million", title: "Millionaires lounge", detail: "Combined keystrokes and mouse clicks", symbol: "crown.fill", metric: .events, targets: [5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000]),
        Achievement(id: "keyboard-voyager", title: "Keyboard voyager", detail: "Keystrokes recorded across your Macs", symbol: "keyboard", metric: .keystrokes, targets: [100_000, 1_000_000, 10_000_000]),
        Achievement(id: "click-collector", title: "Click collector", detail: "Mouse clicks recorded across your Macs", symbol: "cursorarrow.click", metric: .clicks, targets: [10_000, 100_000, 1_000_000]),
        Achievement(id: "space-cadet", title: "Space cadet", detail: "Space-bar presses in your recorded history", symbol: "space", metric: .spaces, targets: [10_000, 100_000, 1_000_000]),
        Achievement(id: "app-devotee", title: "App devotee", detail: "Keystrokes and clicks in a single app in your recorded history", symbol: "app.fill", metric: .appEvents, targets: [100_000, 1_000_000, 10_000_000]),
        Achievement(id: "billionaires-club", title: "Billionaires club", detail: "One billion combined keystrokes and mouse clicks", symbol: "diamond.fill", metric: .events, targets: [1_000_000_000], hiddenUntilEarned: true),
    ]

    static func numeral(_ tier: Int) -> String {
        ["I", "II", "III", "IV", "V"][min(4, max(0, tier - 1))]
    }
}

struct ChallengeMetrics {
    var events = 0
    var keystrokes = 0
    var clicks = 0
    var spaces = 0
    var appEvents = 0
    var topApp: String?

    func value(for metric: ChallengeMetric, goalDays: Int) -> Int {
        switch metric {
        case .goalDays: return goalDays
        case .events: return events
        case .keystrokes: return keystrokes
        case .clicks: return clicks
        case .spaces: return spaces
        case .appEvents: return appEvents
        }
    }
}

struct AchievementStatus {
    let badge: Achievement
    let value: Int
    let earnedTier: Int
    var context: String? = nil
    var earnedDates: [Int: Date] = [:]
    var inferredTiers: Set<Int> = []

    var complete: Bool { earnedTier == badge.targets.count }
    var targetTier: Int { complete ? earnedTier : earnedTier + 1 }
    var target: Int { badge.targets[max(0, targetTier - 1)] }
    var progress: Double {
        guard !complete else { return 1 }
        let previous = earnedTier > 0 ? badge.targets[earnedTier - 1] : 0
        return min(1, max(0, Double(value - previous) / Double(target - previous)))
    }
    var title: String {
        badge.targets.count > 1 ? "\(badge.title) \(Achievement.numeral(max(1, earnedTier)))" : badge.title
    }
    var tooltip: String {
        let earned = earnedTier == 0 ? "Not earned yet." : (1...earnedTier).map { tier in
            let label = badge.targets.count > 1 ? "Tier \(Achievement.numeral(tier))" : "Achievement"
            guard let date = earnedDates[tier] else { return "\(label) earned · date unavailable." }
            return "\(label) earned \(date.formatted(date: .abbreviated, time: .omitted))."
        }.joined(separator: "\n")
        let next = complete ? "All targets completed." : "Next: \(badge.title)\(badge.targets.count > 1 ? " " + Achievement.numeral(targetTier) : "") at \(CountFormatter.grouped(target))."
        let contextLine = context.map { "\n\($0)" } ?? ""
        return "\(badge.detail).\n\(earned)\n\(next)\(contextLine)"
    }
}

/// Pure calculations shared by the panel and event-driven celebrations.
struct GameSummary {
    let goalDays: [Date]
    let weeklyGoalDays: Int
    let recordKeys: [String]
    let eligibleBadges: Set<String>
    var metrics = ChallengeMetrics()
    var historicalTierDates: [String: Date] = [:]

    static func calculate(days: [DailyStats], lifetime: Int, goal: Int,
                          now: Date = Date(), calendar: Calendar = .current,
                          keystrokes: Int? = nil, clicks: Int? = nil,
                          includeHistoricalDates: Bool = true) -> GameSummary {
        let goalDays = days.filter { $0.day <= now && goal > 0 && $0.keystrokes + $0.clicks >= goal }.map(\.day)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let weeklyGoalDays = goalDays.filter { week?.contains($0) == true }.count
        var recordKeys: [String] = []
        for (name, component) in [("day", Calendar.Component.day), ("week", .weekOfYear), ("month", .month)] {
            guard let current = calendar.dateInterval(of: component, for: now)?.start else { continue }
            var periods: [Date: Int] = [:]
            for day in days where day.day <= now {
                guard let start = calendar.dateInterval(of: component, for: day.day)?.start else { continue }
                periods[start, default: 0] += day.keystrokes + day.clicks
            }
            let previous = periods.filter { $0.key < current }.map(\.value).max() ?? 0
            if previous > 0 && periods[current, default: 0] > previous {
                recordKeys.append("\(name)-\(Int(current.timeIntervalSince1970))")
            }
        }
        var badges: Set<String> = []
        if lifetime >= 1_000_000 { badges.insert("million") }
        if lifetime >= 5_000_000 { badges.insert("five-million") }
        let history = days.filter { $0.day <= now }
        var apps: [String: Int] = [:]
        for day in history {
            apps.merge(day.appFrequency, uniquingKeysWith: +)
        }
        let topApp = apps.max { $0.value < $1.value }
        let metrics = ChallengeMetrics(events: lifetime,
            keystrokes: keystrokes ?? history.reduce(0) { $0 + $1.keystrokes },
            clicks: clicks ?? history.reduce(0) { $0 + $1.clicks },
            spaces: history.reduce(0) { $0 + $1.keyFrequency["space", default: 0] },
            appEvents: topApp?.value ?? 0, topApp: topApp?.key)
        var historicalDates: [String: Date] = [:]
        let historyKeys = history.reduce(0) { $0 + $1.keystrokes }
        let historyClicks = history.reduce(0) { $0 + $1.clicks }
        var running = ChallengeMetrics()
        var runningApps: [String: Int] = [:]
        for day in includeHistoricalDates ? history.sorted(by: { $0.day < $1.day }) : [] {
            running.keystrokes += day.keystrokes
            running.clicks += day.clicks
            running.events = running.keystrokes + running.clicks
            running.spaces += day.keyFrequency["space", default: 0]
            runningApps.merge(day.appFrequency, uniquingKeysWith: +)
            running.appEvents = runningApps.values.max() ?? 0
            for badge in Achievement.all {
                // Lifetime dates are recoverable only when the retained history
                // matches the counters; resets or missing history make them uncertain.
                switch badge.metric {
                case .goalDays: continue // Uses permanently credited goal days below.
                case .events: guard historyKeys + historyClicks == metrics.events else { continue }
                case .keystrokes: guard historyKeys == metrics.keystrokes else { continue }
                case .clicks: guard historyClicks == metrics.clicks else { continue }
                case .spaces, .appEvents: break
                }
                let value = running.value(for: badge.metric, goalDays: 0)
                for (index, target) in badge.targets.enumerated() where value >= target {
                    let key = "\(badge.id):\(index + 1)"
                    if historicalDates[key] == nil { historicalDates[key] = day.day }
                }
            }
        }
        return GameSummary(goalDays: goalDays, weeklyGoalDays: weeklyGoalDays,
                           recordKeys: recordKeys, eligibleBadges: badges, metrics: metrics,
                           historicalTierDates: historicalDates)
    }
}

@MainActor
@Observable
final class GameProgress {
    private(set) var unlocked: Set<String>
    private(set) var goalDays: Set<String>
    private(set) var earnedTiers: [String: Int]
    private(set) var highWater: [String: Int]
    private(set) var earnedDates: [String: Double]
    private(set) var inferredDates: Set<String>
    @ObservationIgnored private var celebrated: Set<String>
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unlocked = Set(defaults.stringArray(forKey: "earnedBadges") ?? [])
        goalDays = Set(defaults.stringArray(forKey: "earnedGoalDays") ?? [])
        celebrated = Set(defaults.stringArray(forKey: "celebratedRecords") ?? [])
        earnedTiers = defaults.dictionary(forKey: "achievementTiers") as? [String: Int] ?? [:]
        highWater = defaults.dictionary(forKey: "achievementHighWater") as? [String: Int] ?? [:]
        earnedDates = defaults.dictionary(forKey: "achievementEarnedDates") as? [String: Double] ?? [:]
        inferredDates = Set(defaults.stringArray(forKey: "achievementInferredDates") ?? [])
        // Preserve the original five badges when moving to tiered challenges.
        for badge in Achievement.all where unlocked.contains(badge.id) {
            earnedTiers[badge.id] = max(1, earnedTiers[badge.id, default: 0])
            highWater[badge.id] = max(badge.targets[0], highWater[badge.id, default: 0])
        }
    }

    /// Import existing history silently, and suppress alerts for already-beaten records.
    func check(store: StatsStore, notify: Bool = true, now: Date = Date()) {
        guard !notify || now.timeIntervalSince(lastCheck) >= 1 else { return }
        lastCheck = now
        let summary = store.gameSummary(now: now,
            includeHistoricalDates: !defaults.bool(forKey: "importedAchievementDates"))
        apply(summary: summary, goalEnabled: store.dailyGoal > 0, notify: notify, now: now)
    }

    func apply(summary: GameSummary, goalEnabled: Bool, notify: Bool, now: Date) {
        let importHistory = !defaults.bool(forKey: "importedGameHistory")
        let creditedDays = importHistory ? summary.goalDays : summary.goalDays.filter {
            Calendar.current.isDate($0, inSameDayAs: now)
        }
        let newGoalDays = Set(creditedDays.map { String(Int($0.timeIntervalSince1970)) })
        if importHistory { defaults.set(true, forKey: "importedGameHistory") }
        let allGoalDays = goalDays.union(newGoalDays)
        if allGoalDays != goalDays {
            goalDays = allGoalDays
            defaults.set(Array(goalDays), forKey: "earnedGoalDays")
        }
        var newTiers: [String] = []
        var nextHighWater = highWater
        var nextTiers = earnedTiers
        var nextUnlocked = unlocked
        var nextDates = earnedDates
        var nextInferred = inferredDates
        let creditedDates = goalDays.compactMap(Double.init).map(Date.init(timeIntervalSince1970:)).sorted()
        for badge in Achievement.all {
            let value = max(highWater[badge.id, default: 0], summary.metrics.value(for: badge.metric, goalDays: goalDays.count))
            nextHighWater[badge.id] = value
            let reached = badge.targets.filter { value >= $0 }.count
            let oldTier = earnedTiers[badge.id, default: 0]
            let tier = max(oldTier, reached)
            nextTiers[badge.id] = tier
            if tier > 0 { nextUnlocked.insert(badge.id) }
            if tier > oldTier {
                newTiers.append(badge.title + (badge.targets.count > 1 ? " " + Achievement.numeral(tier) : ""))
            }
            if tier > 0 {
                for earnedTier in 1...tier {
                    let key = "\(badge.id):\(earnedTier)"
                    guard nextDates[key] == nil else { continue }
                    if earnedTier > oldTier && notify {
                        nextDates[key] = now.timeIntervalSince1970
                    } else {
                        let target = badge.targets[earnedTier - 1]
                        let inferred = badge.metric == .goalDays && creditedDates.count >= target
                            ? creditedDates[target - 1] : summary.historicalTierDates[key]
                        if let inferred {
                            nextDates[key] = inferred.timeIntervalSince1970
                            nextInferred.insert(key)
                        }
                    }
                }
            }
        }
        if nextHighWater != highWater {
            highWater = nextHighWater
            scheduleSave()
        }
        if nextTiers != earnedTiers {
            earnedTiers = nextTiers
            defaults.set(earnedTiers, forKey: "achievementTiers")
        }
        if nextUnlocked != unlocked {
            unlocked = nextUnlocked
            defaults.set(Array(unlocked), forKey: "earnedBadges")
        }
        if nextDates != earnedDates {
            earnedDates = nextDates
            inferredDates = nextInferred
            defaults.set(earnedDates, forKey: "achievementEarnedDates")
            defaults.set(Array(inferredDates), forKey: "achievementInferredDates")
        }
        if !defaults.bool(forKey: "importedAchievementDates") {
            defaults.set(true, forKey: "importedAchievementDates")
        }
        if notify, !newTiers.isEmpty {
            NotificationManager.shared.fireAchievement(newTiers.joined(separator: ", "))
        }
        var keys = summary.recordKeys
        let target = max(1, min(7, defaults.object(forKey: "weeklyGoalDays") as? Int ?? 4))
        if goalEnabled, summary.weeklyGoalDays >= target,
           let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start {
            keys.append("consistency-\(Int(start.timeIntervalSince1970))")
        }
        let fresh = Set(keys).subtracting(celebrated)
        if !fresh.isEmpty {
            celebrated.formUnion(fresh)
            defaults.set(Array(celebrated), forKey: "celebratedRecords")
            if notify {
                let records = ["day", "week", "month"].filter { name in fresh.contains { $0.hasPrefix(name + "-") } }
                if !records.isEmpty { NotificationManager.shared.fireRecord(records.joined(separator: ", ")) }
                if fresh.contains(where: { $0.hasPrefix("consistency-") }) {
                    NotificationManager.shared.fireConsistency(target)
                }
            }
        }
    }
    func status(for badge: Achievement, summary: GameSummary) -> AchievementStatus {
        let value = max(highWater[badge.id, default: 0], summary.metrics.value(for: badge.metric, goalDays: goalDays.count))
        let tier = max(earnedTiers[badge.id, default: 0], badge.targets.filter { value >= $0 }.count)
        let context = badge.id == "app-devotee" ? summary.metrics.topApp.map { "Currently leading app: \($0)." } : nil
        var dates: [Int: Date] = [:]
        var inferred: Set<Int> = []
        if tier > 0 {
            for index in 1...tier {
                let key = "\(badge.id):\(index)"
                if let date = earnedDates[key] { dates[index] = Date(timeIntervalSince1970: date) }
                if inferredDates.contains(key) { inferred.insert(index) }
            }
        }
        return AchievementStatus(badge: badge, value: value, earnedTier: tier, context: context,
                                 earnedDates: dates, inferredTiers: inferred)
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.defaults.set(self.highWater, forKey: "achievementHighWater")
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        defaults.set(highWater, forKey: "achievementHighWater")
    }

}
