//
//  StatsStore.swift
//  keystroke_counter
//
//  The per-day statistics backbone. Everything the UI shows reads from here.
//
//  PRIVACY: This store records COUNTS ONLY. It tallies how many keystrokes and
//  clicks happened, how often each individual key was pressed, and which app was
//  frontmost when events happened. It NEVER stores what you type — no words, no
//  sequences, no ordered input, no window titles, no content of any kind. All
//  data lives locally in Application Support; nothing is ever sent anywhere.
//

import Foundation
import Observation

/// Time scope for the headline keystroke/click totals shown at the top of the
/// panel. Declaration order is the tab order.
enum StatsScope: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This Week"
    case month = "This Month"
    case lifetime = "Lifetime"

    var id: String { rawValue }

    /// The calendar component that defines one period of this scope (nil for
    /// lifetime, which has no repeating period).
    var periodComponent: Calendar.Component? {
        switch self {
        case .today: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .lifetime: return nil
        }
    }
}

/// One day's worth of aggregate statistics. `Codable` so we can persist the
/// whole history as JSON.
struct DailyStats: Codable, Identifiable {
    /// Start-of-day (local) date this bucket represents. Also the identity.
    var day: Date
    var keystrokes: Int = 0
    var clicks: Int = 0

    /// Per-key press tallies. Key = readable key name (e.g. "a", "space",
    /// "return"), value = count. Frequency only — never an ordered sequence.
    var keyFrequency: [String: Int] = [:]

    /// Per-app event tallies. Key = app localized name (or bundle id fallback),
    /// value = combined event count while that app was frontmost.
    var appFrequency: [String: Int] = [:]

    var id: Date { day }
}

/// Observable, persisted statistics store. Fed by `EventMonitor`; read by the UI.
@MainActor
@Observable
final class StatsStore {

    // MARK: All-time totals (preserve the original app's semantics)

    /// All-time keystroke total. Survives relaunch; zeroed by `reset()`.
    private(set) var keystrokeCount: Int
    /// All-time click total. Survives relaunch; zeroed by `reset()`.
    private(set) var clickCount: Int

    /// Timestamp of the last reset (or first launch). Shown as "since <date>".
    private(set) var since: Date

    /// Per-day history, keyed by start-of-day date. Persisted.
    private(set) var days: [Date: DailyStats]

    /// Combined-event milestones already reached, so we never re-fire a
    /// notification for the same milestone.
    private(set) var reachedMilestones: Set<Int>

    /// User-configurable daily combined-event goal (0 = disabled).
    var dailyGoal: Int {
        didSet {
            // Any change through the panel is an explicit choice — even setting
            // it to 0 (off) — so it must survive relaunch and never be replaced
            // by the fresh-install default. (didSet does not fire for the initial
            // assignment in `init`, so loading a value here doesn't set this.)
            hasSetGoal = true
            persist()
        }
    }

    /// Whether the user has ever explicitly chosen a goal. Distinguishes a
    /// deliberate "off" (0) from a never-configured install, so the fresh-install
    /// default only applies until the user makes a choice. Not UI-observed.
    @ObservationIgnored private var hasSetGoal: Bool

    /// Start-of-day for which we've already posted the daily-goal notification,
    /// so it fires at most once per day even across relaunches. Persisted.
    private(set) var goalNotifiedDay: Date?

    // MARK: Live typing speed (rolling window)

    /// Date-stamped ring buffer of recent keystroke timestamps used to compute a
    /// live keys-per-minute figure over the last `speedWindow` seconds. This is
    /// in-memory only (not persisted) — it is a live gauge, not history.
    ///
    /// `@ObservationIgnored` is essential: the UI reads this (via `keysPerMinute()`)
    /// inside a `TimelineView` body, and it is mutated as events arrive. If it were
    /// observed, that read/mutate pair would invalidate the body that depends on it
    /// and spin an infinite render loop, freezing the app. The `TimelineView`'s own
    /// timer drives the live refresh, so observation here is neither needed nor safe.
    @ObservationIgnored private var recentKeystrokes: [Date] = []
    private let speedWindow: TimeInterval = 60

    // MARK: Persistence

    private let fileURL: URL

    /// Pending debounced save. A burst of events reschedules this so we write
    /// once after the burst instead of once per event. Not UI-observed.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// How long to wait after the last change before writing to disk.
    private let saveDebounce: Duration = .seconds(2)

    /// On-disk snapshot shape. Bumping nothing fancy — a plain container.
    private struct Persisted: Codable {
        var keystrokeCount: Int
        var clickCount: Int
        var since: Date
        var days: [DailyStats]
        var reachedMilestones: [Int]
        var dailyGoal: Int
        /// Optional so snapshots written before this flag existed decode as nil
        /// (treated as "never configured" → adopt the fresh-install default).
        var hasSetGoal: Bool?
        /// Start-of-day the goal notification last fired (optional for old files).
        var goalNotifiedDay: Date?
    }

    // MARK: Init / load

    init() {
        // Resolve ~/Library/Application Support/<bundle id>/stats.json
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "keystroke_counter"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("stats.json")

        // Defaults for a fresh install.
        var loadedKeystrokes = 0
        var loadedClicks = 0
        var loadedSince = Date()
        var loadedDays: [Date: DailyStats] = [:]
        var loadedMilestones: Set<Int> = []
        // Fresh installs (and installs predating the goal flag) start with an
        // active daily goal of 25k combined events — a solid "active day" for a
        // heavy keyboard user. Once the user picks a goal it takes over.
        var loadedGoal = 25_000
        var loadedHasSetGoal = false
        var loadedGoalNotifiedDay: Date?

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder.iso.decode(Persisted.self, from: data) {
            loadedKeystrokes = snapshot.keystrokeCount
            loadedClicks = snapshot.clickCount
            loadedSince = snapshot.since
            loadedDays = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0) })
            loadedMilestones = Set(snapshot.reachedMilestones)
            loadedGoalNotifiedDay = snapshot.goalNotifiedDay
            // Only honor the persisted goal if it was an explicit choice;
            // otherwise keep the fresh-install default above.
            if snapshot.hasSetGoal == true {
                loadedGoal = snapshot.dailyGoal
                loadedHasSetGoal = true
            }
        }

        self.keystrokeCount = loadedKeystrokes
        self.clickCount = loadedClicks
        self.since = loadedSince
        self.days = loadedDays
        self.reachedMilestones = loadedMilestones
        self.hasSetGoal = loadedHasSetGoal
        self.goalNotifiedDay = loadedGoalNotifiedDay
        self.dailyGoal = loadedGoal
    }

    // MARK: Recording (called by EventMonitor — knows nothing about SwiftUI)

    /// Record a single keystroke.
    /// - Parameters:
    ///   - keyName: readable name of the key (frequency tally only).
    ///   - appName: frontmost app's localized name / bundle id (count only).
    func recordKeystroke(keyName: String, appName: String?) {
        keystrokeCount += 1

        // Append now and prune anything older than the speed window so the buffer
        // stays bounded. Pruning happens here (on write), never during the UI read.
        let cutoff = Date().addingTimeInterval(-speedWindow)
        recentKeystrokes.removeAll { $0 < cutoff }
        recentKeystrokes.append(Date())

        mutateToday { today in
            today.keystrokes += 1
            today.keyFrequency[keyName, default: 0] += 1
            if let appName { today.appFrequency[appName, default: 0] += 1 }
        }
        persist()
    }

    /// Record a single mouse click.
    func recordClick(appName: String?) {
        clickCount += 1
        mutateToday { today in
            today.clicks += 1
            if let appName { today.appFrequency[appName, default: 0] += 1 }
        }
        persist()
    }

    /// Reset the ALL-TIME totals and the "since" timestamp. History is kept
    /// intact by default (the daily buckets and per-key/per-app tallies remain),
    /// so long-term charts survive a reset. Milestones are cleared so the user
    /// can hit them again after starting over.
    func reset() {
        keystrokeCount = 0
        clickCount = 0
        since = Date()
        reachedMilestones = []
        recentKeystrokes = []
        persist()
    }

    // MARK: Derived / read APIs for the UI

    /// Today's bucket (empty if nothing recorded yet today).
    var today: DailyStats {
        days[Self.startOfDay(Date())] ?? DailyStats(day: Self.startOfDay(Date()))
    }

    /// Headline keystroke/click totals for the given scope. `lifetime` uses the
    /// all-time counters; `month`/`week` sum the per-day buckets that fall in the
    /// current calendar month / week.
    func totals(for scope: StatsScope) -> (keystrokes: Int, clicks: Int) {
        switch scope {
        case .lifetime:
            return (keystrokeCount, clickCount)
        case .today:
            return (today.keystrokes, today.clicks)
        case .month:
            return sumDays { Calendar.current.isDate($0, equalTo: Date(), toGranularity: .month) }
        case .week:
            return sumDays { Calendar.current.isDate($0, equalTo: Date(), toGranularity: .weekOfYear) }
        }
    }

    /// Sum keystrokes and clicks across the day buckets matching `include`.
    private func sumDays(where include: (Date) -> Bool) -> (keystrokes: Int, clicks: Int) {
        var keystrokes = 0
        var clicks = 0
        for (day, stats) in days where include(day) {
            keystrokes += stats.keystrokes
            clicks += stats.clicks
        }
        return (keystrokes, clicks)
    }

    /// The best combined (keystrokes + clicks) total from a *previous* period of
    /// the same kind as `scope` — the record to beat — with the start date of
    /// that period (for a tooltip). Returns nil for `.lifetime`, or when no prior
    /// period has any recorded activity.
    func record(for scope: StatsScope) -> (combined: Int, periodStart: Date)? {
        guard let component = scope.periodComponent else { return nil }

        let cal = Calendar.current
        guard let currentStart = cal.dateInterval(of: component, for: Date())?.start else {
            return nil
        }

        // Sum combined events per period, keyed by the period's start date, and
        // skip the in-progress current period.
        var combinedByPeriod: [Date: Int] = [:]
        for stats in days.values {
            guard let start = cal.dateInterval(of: component, for: stats.day)?.start,
                  start != currentStart else { continue }
            combinedByPeriod[start, default: 0] += stats.keystrokes + stats.clicks
        }

        return combinedByPeriod
            .max { $0.value < $1.value }
            .map { (combined: $0.value, periodStart: $0.key) }
    }

    /// The most recent `count` days including today, oldest first. Missing days
    /// are filled with zeroes so charts have a continuous axis.
    func series(days count: Int) -> [DailyStats] {
        let cal = Calendar.current
        let todayStart = Self.startOfDay(Date())
        return (0..<count).reversed().compactMap { offset -> DailyStats? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            return days[day] ?? DailyStats(day: day)
        }
    }

    /// Top keys (frequency only) over the given scope, highest first.
    func topKeys(for scope: StatsScope, limit: Int = 10) -> [(name: String, count: Int)] {
        topEntries(\.keyFrequency, in: scope, limit: limit)
    }

    /// Top apps by event count over the given scope, highest first.
    func topApps(for scope: StatsScope, limit: Int = 10) -> [(name: String, count: Int)] {
        topEntries(\.appFrequency, in: scope, limit: limit)
    }

    /// Merge a per-day frequency dictionary across the day buckets in `scope`,
    /// then return the highest `limit` entries.
    private func topEntries(_ frequency: KeyPath<DailyStats, [String: Int]>,
                            in scope: StatsScope,
                            limit: Int) -> [(name: String, count: Int)] {
        var merged: [String: Int] = [:]
        for stats in dayBuckets(in: scope) {
            for (name, count) in stats[keyPath: frequency] {
                merged[name, default: 0] += count
            }
        }
        return merged
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
    }

    /// The day buckets that fall within the current period of `scope`.
    private func dayBuckets(in scope: StatsScope) -> [DailyStats] {
        switch scope {
        case .lifetime:
            return Array(days.values)
        case .today:
            return [today]
        case .week, .month:
            let component: Calendar.Component = scope == .week ? .weekOfYear : .month
            return days.values.filter {
                Calendar.current.isDate($0.day, equalTo: Date(), toGranularity: component)
            }
        }
    }

    /// Live keystrokes-per-minute over the trailing `speedWindow`. Pure read: it
    /// counts (without mutating) the timestamps still inside the window, so it is
    /// safe to call from a SwiftUI view body. The buffer is pruned on write in
    /// `recordKeystroke`.
    func keysPerMinute() -> Int {
        let cutoff = Date().addingTimeInterval(-speedWindow)
        let countInWindow = recentKeystrokes.reduce(into: 0) { total, date in
            if date >= cutoff { total += 1 }
        }
        // Scale the count in the window up to a per-minute rate.
        let perSecond = Double(countInWindow) / speedWindow
        return Int((perSecond * 60).rounded())
    }

    /// Rough words-per-minute (chars-per-minute / 5, the standard convention).
    func wordsPerMinute() -> Int {
        keysPerMinute() / 5
    }

    // MARK: Milestones

    /// Combined all-time events (keystrokes + clicks).
    var combinedTotal: Int { keystrokeCount + clickCount }

    /// Check for any newly crossed milestones and return them so the caller can
    /// fire notifications. Each milestone fires at most once (tracked in
    /// `reachedMilestones`). Milestones are every 100k combined events, plus the
    /// user's daily goal if configured.
    func newlyReachedMilestones() -> [Int] {
        var fired: [Int] = []

        // Every 100k combined events.
        let step = 100_000
        let highest = combinedTotal / step * step
        var m = step
        while m <= highest {
            if !reachedMilestones.contains(m) {
                reachedMilestones.insert(m)
                fired.append(m)
            }
            m += step
        }

        if !fired.isEmpty { persist() }
        return fired
    }

    // MARK: Daily goal

    /// Today's combined (keystrokes + clicks) events.
    var combinedToday: Int { today.keystrokes + today.clicks }

    /// Fraction of the daily goal reached today, clamped to 0...1. Zero when no
    /// goal is set.
    var goalFraction: Double {
        guard dailyGoal > 0 else { return 0 }
        return min(Double(combinedToday) / Double(dailyGoal), 1.0)
    }

    /// Whether today's activity has met the daily goal.
    var isDailyGoalReached: Bool {
        dailyGoal > 0 && combinedToday >= dailyGoal
    }

    /// Whether the goal is reached today but the once-per-day notification hasn't
    /// been posted yet. Pair with `markDailyGoalNotified()` so it can't re-fire,
    /// including across relaunches.
    var isDailyGoalReachedUnnotified: Bool {
        isDailyGoalReached && goalNotifiedDay != Self.startOfDay(Date())
    }

    /// Record that today's goal notification has fired (persisted).
    func markDailyGoalNotified() {
        goalNotifiedDay = Self.startOfDay(Date())
        persist()
    }

    // MARK: Private helpers

    /// Mutate today's bucket in place, creating it if needed.
    private func mutateToday(_ body: (inout DailyStats) -> Void) {
        let key = Self.startOfDay(Date())
        var bucket = days[key] ?? DailyStats(day: key)
        body(&bucket)
        days[key] = bucket
    }

    /// Debounced save: coalesce a burst of events into a single disk write a
    /// short while after the last change, instead of re-encoding and rewriting
    /// the whole history on every keystroke. In-memory state is already current,
    /// so the UI stays live; only the file lags by up to `saveDebounce`.
    private func persist() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.saveDebounce)
            guard !Task.isCancelled else { return }
            self.writeNow()
        }
    }

    /// Write current state to disk immediately, cancelling any pending debounced
    /// save. Call on quit so an in-flight save is never lost.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        writeNow()
    }

    private func writeNow() {
        let snapshot = Persisted(
            keystrokeCount: keystrokeCount,
            clickCount: clickCount,
            since: since,
            days: Array(days.values),
            reachedMilestones: Array(reachedMilestones),
            dailyGoal: dailyGoal,
            hasSetGoal: hasSetGoal,
            goalNotifiedDay: goalNotifiedDay
        )
        guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}

// MARK: - JSON coders with stable date handling

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
