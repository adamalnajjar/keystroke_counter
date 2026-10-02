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
//  data lives locally in Application Support. If the user opts in to sync,
//  these same per-day counts are uploaded to their own server (SyncClient).
//
//  SYNC MODEL: `days` and the lifetime counters only ever hold THIS Mac's
//  activity. Other Macs' contributions arrive as `remote*` (already summed by
//  the server) and are added on top in every read API, so the two never mix
//  and nothing can be counted twice.
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

    /// Tab label. Kept short so the four-segment picker always fits the panel:
    /// with the longer raw values it could overflow after a selection change,
    /// widening the whole column and shifting the panel's content sideways.
    /// (The raw values stay as-is because they're persisted via @AppStorage.)
    var tabTitle: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .lifetime: return "Lifetime"
        }
    }

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

/// Whose activity the panel shows when sync has other Macs to add in.
enum StatsSource: String, CaseIterable, Identifiable {
    case thisMac
    case combined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .combined: return "Combined"
        }
    }
}

/// One day's worth of aggregate statistics. `Codable` so we can persist the
/// whole history as JSON.
struct DailyStats: Codable, Identifiable, Equatable {
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
    @ObservationIgnored private(set) var keystrokeCount: Int
    /// All-time click total. Survives relaunch; zeroed by `reset()`.
    @ObservationIgnored private(set) var clickCount: Int

    /// Timestamp of the last reset (or first launch). Shown as "since <date>".
    @ObservationIgnored private(set) var since: Date

    /// Per-day history, keyed by start-of-day date. Persisted.
    @ObservationIgnored private(set) var days: [Date: DailyStats]

    /// Combined-event milestones already reached, so we never re-fire a
    /// notification for the same milestone.
    @ObservationIgnored private(set) var reachedMilestones: Set<Int>

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
    @ObservationIgnored private(set) var goalNotifiedDay: Date?

    /// Lightweight invalidation token for the UI. The hot counters above are
    /// intentionally ignored by Observation so every key press does not redraw
    /// the menu bar and panel. Derived read APIs touch this token, and event
    /// recording bumps it on a short throttle.
    private(set) var displayRevision = 0
    @ObservationIgnored private var pendingDisplayRefresh: Task<Void, Never>?
    private let displayRefreshInterval: Duration = .seconds(1)

    // MARK: Sync (other Macs' activity, summed by the server)

    /// Other Macs' per-day stats, keyed by start-of-day. Added to `days` in reads.
    @ObservationIgnored private var remoteDays: [Date: DailyStats] = [:]
    /// Other Macs' all-time counters.
    @ObservationIgnored private var remoteKeystrokes = 0
    @ObservationIgnored private var remoteClicks = 0
    /// Earliest "since" among the other Macs.
    @ObservationIgnored private var remoteSince: Date?
    /// Names of the other Macs contributing to the totals.
    private(set) var syncedDeviceNames: [String] = []

    /// Whether sync is turned on. Set by SyncClient. While off, cached data
    /// from other Macs is ignored everywhere, since it's no longer kept fresh.
    var isSyncActive = false {
        didSet {
            guard isSyncActive, !oldValue else { return }
            // Other Macs' totals just joined the combined total.
            markMilestonesReachedSilently()
            persist()
        }
    }

    /// Whose activity the read APIs report. Milestones and the daily-goal
    /// notification ignore this and always use the combined total, so
    /// switching the view can't change what gets notified.
    var source: StatsSource = StatsSource(
        rawValue: UserDefaults.standard.string(forKey: "statsSource") ?? ""
    ) ?? .combined {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "statsSource") }
    }

    /// Whether there's other-Mac data to choose between (drives the switch).
    var hasOtherMacs: Bool { isSyncActive && !syncedDeviceNames.isEmpty }

    /// Days whose local bucket changed since it was last uploaded. Persisted, so
    /// changes made while offline (or just before quitting) still get uploaded.
    @ObservationIgnored private var unsyncedDays: Set<Date>

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
    /// Cache of the last server response, so combined numbers show offline.
    private let remoteFileURL: URL

    /// Pending coalesced save. The first change schedules one write after a
    /// short delay; further events reuse the same task instead of cancelling and
    /// recreating work on every keystroke. Not UI-observed.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Whether state has changed since the last completed write.
    @ObservationIgnored private var needsSave = false

    /// How long to coalesce writes before touching disk.
    private let saveDelay: Duration = .seconds(5)

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
        /// Days not yet uploaded. nil (files from before sync existed) means
        /// every day still needs uploading.
        var unsyncedDays: [Date]?
    }

    /// What the server reports about the other Macs. Also the on-disk cache.
    struct RemoteSnapshot: Codable {
        var deviceNames: [String]
        var keystrokes: Int
        var clicks: Int
        var since: Date?
        var days: [DailyStats]
    }

    /// One upload's worth of this Mac's data, handed to SyncClient.
    struct SyncUpload {
        var keystrokes: Int
        var clicks: Int
        var since: Date
        var days: [DailyStats]
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
        self.remoteFileURL = dir.appendingPathComponent("remote.json")

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
        var loadedUnsyncedDays: Set<Date>?

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder.iso.decode(Persisted.self, from: data) {
            loadedKeystrokes = snapshot.keystrokeCount
            loadedClicks = snapshot.clickCount
            loadedSince = snapshot.since
            loadedDays = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0) })
            loadedMilestones = Set(snapshot.reachedMilestones)
            loadedGoalNotifiedDay = snapshot.goalNotifiedDay
            loadedUnsyncedDays = snapshot.unsyncedDays.map(Set.init)
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
        self.unsyncedDays = loadedUnsyncedDays ?? Set(loadedDays.keys)
        self.dailyGoal = loadedGoal

        if let data = try? Data(contentsOf: remoteFileURL),
           let remote = try? JSONDecoder.iso.decode(RemoteSnapshot.self, from: data) {
            setRemote(remote)
        }
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
        scheduleDisplayRefresh()
        persist()
    }

    /// Record a single mouse click.
    func recordClick(appName: String?) {
        clickCount += 1
        mutateToday { today in
            today.clicks += 1
            if let appName { today.appFrequency[appName, default: 0] += 1 }
        }
        scheduleDisplayRefresh()
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
        // Other Macs' lifetime counts aren't reset, so milestones they already
        // carry the combined total past shouldn't all fire again at once.
        markMilestonesReachedSilently()
        recentKeystrokes = []
        displayRevision &+= 1
        persist()
    }

    // MARK: Sync

    /// This Mac's lifetime counters plus every day changed since its last
    /// successful upload.
    func pendingSyncUpload() -> SyncUpload {
        SyncUpload(keystrokes: keystrokeCount,
                   clicks: clickCount,
                   since: since,
                   days: unsyncedDays.compactMap { days[$0] })
    }

    /// Mark an upload as delivered and adopt the server's view of the other
    /// Macs. Days that changed again while the request was in flight stay
    /// pending for the next sync.
    func completeSync(uploaded: SyncUpload, remote: RemoteSnapshot) {
        for day in uploaded.days where days[day.day] == day {
            unsyncedDays.remove(day.day)
        }
        setRemote(remote)
        markMilestonesReachedSilently()
        displayRevision &+= 1
        persist()

        if let data = try? JSONEncoder.iso.encode(remote) {
            try? data.write(to: remoteFileURL, options: .atomic)
        }
    }

    private func setRemote(_ remote: RemoteSnapshot) {
        remoteDays = Dictionary(remote.days.map { ($0.day, $0) },
                                uniquingKeysWith: { Self.merged($0, $1, day: $0.day) })
        remoteKeystrokes = remote.keystrokes
        remoteClicks = remote.clicks
        remoteSince = remote.since
        syncedDeviceNames = remote.deviceNames
    }

    /// Milestones only notify when typing on this Mac crosses them; ones the
    /// combined total passed because of another Mac's activity (or a reset)
    /// are recorded without a notification.
    private func markMilestonesReachedSilently() {
        let step = 100_000
        var m = step
        while m <= combinedTotal {
            reachedMilestones.insert(m)
            m += step
        }
    }

    /// Add two buckets for the same day (either may be missing).
    private static func merged(_ a: DailyStats?, _ b: DailyStats?, day: Date) -> DailyStats {
        guard let a else { return b ?? DailyStats(day: day) }
        guard let b else { return a }
        var result = a
        result.keystrokes += b.keystrokes
        result.clicks += b.clicks
        result.keyFrequency.merge(b.keyFrequency, uniquingKeysWith: +)
        result.appFrequency.merge(b.appFrequency, uniquingKeysWith: +)
        return result
    }

    /// Whether the read APIs should add the other Macs' data in.
    private var showsRemote: Bool { isSyncActive && source == .combined }

    /// The other Macs' days, or none when the view is "This Mac".
    private var shownRemoteDays: [Date: DailyStats] { showsRemote ? remoteDays : [:] }

    /// Every bucket in the current view. A day can appear twice (once from
    /// this Mac, once from the others); everything that consumes this list
    /// only sums, so that's equivalent to merging first.
    private var allBuckets: [DailyStats] {
        Array(days.values) + Array(shownRemoteDays.values)
    }

    // MARK: Derived / read APIs for the UI

    /// Today's bucket (empty if nothing recorded yet today).
    var today: DailyStats {
        _ = displayRevision
        let day = Self.startOfDay(Date())
        return Self.merged(days[day], shownRemoteDays[day], day: day)
    }

    /// Start of the lifetime totals: the earliest "since" across all Macs.
    var displaySince: Date {
        _ = displayRevision
        return showsRemote ? min(since, remoteSince ?? since) : since
    }

    /// Headline keystroke/click totals for the given scope, across all synced
    /// Macs. `lifetime` uses the all-time counters; `month`/`week` sum the per-day buckets that fall in the
    /// current calendar month / week.
    func totals(for scope: StatsScope) -> (keystrokes: Int, clicks: Int) {
        _ = displayRevision
        switch scope {
        case .lifetime:
            return showsRemote
                ? (keystrokeCount + remoteKeystrokes, clickCount + remoteClicks)
                : (keystrokeCount, clickCount)
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
        for stats in allBuckets where include(stats.day) {
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
        _ = displayRevision
        guard let component = scope.periodComponent else { return nil }

        let cal = Calendar.current
        guard let currentStart = cal.dateInterval(of: component, for: Date())?.start else {
            return nil
        }

        // Sum combined events per period, keyed by the period's start date, and
        // skip the in-progress current period.
        var combinedByPeriod: [Date: Int] = [:]
        for stats in allBuckets {
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
        _ = displayRevision
        let cal = Calendar.current
        let todayStart = Self.startOfDay(Date())
        return (0..<count).reversed().compactMap { offset -> DailyStats? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            return Self.merged(days[day], shownRemoteDays[day], day: day)
        }
    }

    /// Top keys (frequency only) over the given scope, highest first.
    func topKeys(for scope: StatsScope, limit: Int = 10) -> [(name: String, count: Int)] {
        _ = displayRevision
        return topEntries(\.keyFrequency, in: scope, limit: limit)
    }

    /// Top apps by event count over the given scope, highest first.
    func topApps(for scope: StatsScope, limit: Int = 10) -> [(name: String, count: Int)] {
        _ = displayRevision
        return topEntries(\.appFrequency, in: scope, limit: limit)
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
            return allBuckets
        case .today:
            return [today]
        case .week, .month:
            let component: Calendar.Component = scope == .week ? .weekOfYear : .month
            return allBuckets.filter {
                Calendar.current.isDate($0.day, equalTo: Date(), toGranularity: component)
            }
        }
    }

    /// Live keystrokes-per-minute over the trailing `speedWindow`. Pure read: it
    /// counts (without mutating) the timestamps still inside the window, so it is
    /// safe to call from a SwiftUI view body. The buffer is pruned on write in
    /// `recordKeystroke`.
    func keysPerMinute() -> Int {
        _ = displayRevision
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

    /// Combined all-time events (keystrokes + clicks) across all synced Macs.
    var combinedTotal: Int {
        keystrokeCount + clickCount + (isSyncActive ? remoteKeystrokes + remoteClicks : 0)
    }

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
    /// including across relaunches. Always counts every synced Mac, regardless
    /// of `source`, so the notification doesn't depend on the panel's view.
    var isDailyGoalReachedUnnotified: Bool {
        let day = Self.startOfDay(Date())
        let allMacs = Self.merged(days[day], isSyncActive ? remoteDays[day] : nil, day: day)
        return dailyGoal > 0
            && allMacs.keystrokes + allMacs.clicks >= dailyGoal
            && goalNotifiedDay != day
    }

    /// Record that today's goal notification has fired (persisted).
    func markDailyGoalNotified() {
        goalNotifiedDay = Self.startOfDay(Date())
        displayRevision &+= 1
        persist()
    }

    // MARK: Private helpers

    /// Mutate today's bucket in place, creating it if needed.
    private func mutateToday(_ body: (inout DailyStats) -> Void) {
        let key = Self.startOfDay(Date())
        var bucket = days[key] ?? DailyStats(day: key)
        body(&bucket)
        days[key] = bucket
        unsyncedDays.insert(key)
    }

    /// Debounced save: coalesce a burst of events into a single disk write a
    /// short while after the last change, instead of re-encoding and rewriting
    /// the whole history on every keystroke. In-memory state is already current,
    /// so the UI stays live; only the file lags by up to `saveDelay`.
    private func persist() {
        needsSave = true
        guard pendingSave == nil else { return }
        pendingSave = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.saveDelay)
            guard !Task.isCancelled else { return }
            self.needsSave = false
            self.writeNow()
            self.pendingSave = nil
        }
    }

    private func scheduleDisplayRefresh() {
        guard pendingDisplayRefresh == nil else { return }
        pendingDisplayRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.displayRefreshInterval)
            guard !Task.isCancelled else { return }
            self.displayRevision &+= 1
            self.pendingDisplayRefresh = nil
        }
    }

    /// Write current state to disk immediately, cancelling any pending debounced
    /// save. Call on quit so an in-flight save is never lost.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        pendingDisplayRefresh?.cancel()
        pendingDisplayRefresh = nil
        displayRevision &+= 1
        if needsSave {
            needsSave = false
            writeNow()
        }
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
            goalNotifiedDay: goalNotifiedDay,
            unsyncedDays: Array(unsyncedDays)
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
