//
//  SyncClient.swift
//  keystroke_counter
//
//  Optional, opt-in sync of the per-day counts across the user's Macs via their
//  own server (server/ in this repo). Off by default: with sync disabled this
//  class never touches the network.
//
//  Each sync uploads THIS Mac's changed days plus its lifetime counters
//  (replaces on the server, never increments, so retries can't double-count)
//  and gets back the other Macs' totals, which StatsStore adds on for display.
//  The local stats file stays the source of truth; if the server is
//  unreachable the app keeps counting and catches up on the next sync.
//

import Foundation
import Observation
import Security

@MainActor
@Observable
final class SyncClient {

    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var status: Status = .idle

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { Task { await syncNow() } } else { status = .idle }
        }
    }

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    /// Whether a token is saved in the Keychain (the token itself is never
    /// held in an observed property).
    private(set) var hasToken: Bool

    @ObservationIgnored private let store: StatsStore
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSyncAttempt: Date?
    @ObservationIgnored private let interval: Duration = .seconds(300)

    /// Stable random identifier for this Mac. Not derived from hardware.
    @ObservationIgnored private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: Keys.deviceID) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Keys.deviceID)
        return id
    }()

    @ObservationIgnored private lazy var deviceName: String =
        Host.current().localizedName ?? "Mac"

    private enum Keys {
        static let enabled = "syncEnabled"
        static let serverURL = "syncServerURL"
        static let deviceID = "syncDeviceID"
    }

    init(store: StatsStore) {
        self.store = store
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        self.serverURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? ""
        self.hasToken = Keychain.token() != nil
    }

    // MARK: Scheduling

    /// Sync now and then every `interval` while the app runs.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Sync when the panel opens, unless we synced in the last 30 seconds.
    func syncIfStale() {
        if let lastSyncAttempt, Date().timeIntervalSince(lastSyncAttempt) < 30 { return }
        Task { await syncNow() }
    }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.deleteToken() } else { Keychain.setToken(trimmed) }
        hasToken = Keychain.token() != nil
        Task { await syncNow() }
    }

    // MARK: Sync

    func syncNow() async {
        guard isEnabled, status != .syncing else { return }
        guard let endpoint = endpointURL() else {
            status = .failed("Enter a valid https:// server URL")
            return
        }
        guard let token = Keychain.token() else {
            status = .failed("Enter the sync token")
            return
        }

        status = .syncing
        lastSyncAttempt = Date()
        let upload = store.pendingSyncUpload()

        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder.sync.encode(SyncRequest(
                deviceID: deviceID,
                deviceName: deviceName,
                lifetime: .init(keystrokes: upload.keystrokes, clicks: upload.clicks, since: upload.since),
                days: upload.days.map(SyncDay.init)))

            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = .failed(code == 401 ? "Server rejected the token" : "Server error (HTTP \(code))")
                return
            }

            let others = try JSONDecoder.sync.decode(SyncResponse.self, from: data).others
            store.completeSync(uploaded: upload, remote: StatsStore.RemoteSnapshot(
                deviceNames: others.deviceNames,
                keystrokes: others.lifetime.keystrokes,
                clicks: others.lifetime.clicks,
                since: others.lifetime.since,
                days: others.days.compactMap(\.dailyStats)))
            status = .synced(Date())
        } catch let error as URLError {
            status = .failed(error.code == .notConnectedToInternet ? "Offline" : "Can't reach server")
        } catch {
            status = .failed("Unexpected server response")
        }
    }

    /// `<serverURL>/v1/sync`, accepting only https (or http to localhost, for testing).
    private func endpointURL() -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), let host = base.host() else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard base.scheme == "https" || (base.scheme == "http" && isLocal) else { return nil }
        return base.appending(path: "v1/sync")
    }
}

// MARK: - Wire format (mirrors server/app.py)

private struct SyncLifetime: Codable {
    var keystrokes: Int
    var clicks: Int
    var since: Date?
}

private struct SyncDay: Codable {
    var date: String
    var keystrokes: Int
    var clicks: Int
    var keyFrequency: [String: Int]
    var appFrequency: [String: Int]

    init(_ stats: DailyStats) {
        date = SyncDay.dayString(stats.day)
        keystrokes = stats.keystrokes
        clicks = stats.clicks
        keyFrequency = stats.keyFrequency
        appFrequency = stats.appFrequency
    }

    /// This day as a local-calendar bucket, or nil for a malformed date.
    var dailyStats: DailyStats? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return DailyStats(day: StatsStore.startOfDay(date),
                          keystrokes: keystrokes,
                          clicks: clicks,
                          keyFrequency: keyFrequency,
                          appFrequency: appFrequency)
    }

    /// Days travel as local calendar dates ("2026-10-01"), not instants, so
    /// "today" means the same thing on every Mac regardless of time zone.
    static func dayString(_ day: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

private struct SyncRequest: Encodable {
    var deviceID: String
    var deviceName: String
    var lifetime: SyncLifetime
    var days: [SyncDay]
}

private struct SyncResponse: Decodable {
    struct Others: Decodable {
        var deviceNames: [String]
        var lifetime: SyncLifetime
        var days: [SyncDay]
    }
    var others: Others
}

private extension JSONEncoder {
    static let sync: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let sync: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Keychain

/// The sync token lives in the login Keychain, not in UserDefaults.
private enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "keystroke_counter") + ".sync"
    private static let account = "token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func token() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String) {
        deleteToken()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func deleteToken() {
        SecItemDelete(query as CFDictionary)
    }
}
