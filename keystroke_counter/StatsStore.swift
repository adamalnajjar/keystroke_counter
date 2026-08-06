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
        didSet { persist() }
    }

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

    /// On-disk snapshot shape. Bumping nothing fancy — a plain container.
    private struct Persisted: Codable {
        var keystrokeCount: Int
        var clickCount: Int
        var since: Date
        var days: [DailyStats]
        var reachedMilestones: [Int]
        var dailyGoal: Int
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
        var loadedGoal = 0

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder.iso.decode(Persisted.self, from: data) {
            loadedKeystrokes = snapshot.keystrokeCount
            loadedClicks = snapshot.clickCount
            loadedSince = snapshot.since
            loadedDays = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0) })
            loadedMilestones = Set(snapshot.reachedMilestones)
            loadedGoal = snapshot.dailyGoal
        }

        self.keystrokeCount = loadedKeystrokes
        self.clickCount = loadedClicks
        self.since = loadedSince
        self.days = loadedDays
        self.reachedMilestones = loadedMilestones
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

    /// Top keys used today (frequency only), highest first.
    func topKeys(limit: Int = 10) -> [(name: String, count: Int)] {
        today.keyFrequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
    }

    /// Top apps today by combined event count, highest first.
    func topApps(limit: Int = 10) -> [(name: String, count: Int)] {
        today.appFrequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
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

    // MARK: Private helpers

    /// Mutate today's bucket in place, creating it if needed.
    private func mutateToday(_ body: (inout DailyStats) -> Void) {
        let key = Self.startOfDay(Date())
        var bucket = days[key] ?? DailyStats(day: key)
        body(&bucket)
        days[key] = bucket
    }

    private func persist() {
        let snapshot = Persisted(
            keystrokeCount: keystrokeCount,
            clickCount: clickCount,
            since: since,
            days: Array(days.values),
            reachedMilestones: Array(reachedMilestones),
            dailyGoal: dailyGoal
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
