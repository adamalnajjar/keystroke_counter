//
//  EventMonitor.swift
//  keystroke_counter
//
//  The RAW event source. It knows nothing about SwiftUI — it just watches
//  NSEvents and feeds aggregate facts into the StatsStore. It also owns the
//  Accessibility-permission flow required for global monitoring.
//
//  PRIVACY: We forward only a per-key NAME (for frequency) and the frontmost
//  app's NAME to the store. We never capture typed text, sequences, or content.
//

import AppKit
import Observation

@MainActor
@Observable
final class EventMonitor {

    /// The stats backbone this monitor feeds.
    private let store: StatsStore

    /// Called after each recorded event so the app can check milestones. Kept as
    /// a closure so EventMonitor stays UI-agnostic.
    var onEventRecorded: (() -> Void)?

    // Global monitors fire for events delivered to OTHER apps; local monitors
    // fire for events delivered to THIS app (so our own clicks count too).
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(store: StatsStore) {
        self.store = store
    }

    // MARK: Accessibility permission

    /// Whether the process is trusted for Accessibility (required to observe
    /// global keyboard events).
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user for Accessibility permission (shows the system dialog the
    /// first time, then deep-links to System Settings).
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Lifecycle

    /// Start watching for keystrokes and clicks.
    func start() {
        // Avoid double-installing monitors.
        stop()

        let keyMask: NSEvent.EventTypeMask = [.keyDown]
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.handleKey(event)
        }
        // Local monitor must return the event so normal handling continues.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: keyMask) { [weak self] event in
            self?.handleKey(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.handleMouse(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    /// Stop watching and remove all monitors.
    func stop() {
        for monitor in [globalKeyMonitor, localKeyMonitor, globalMouseMonitor, localMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    // MARK: Event handling

    private func handleKey(_ event: NSEvent) {
        // Ignore auto-repeat so holding a key doesn't inflate counts.
        guard !event.isARepeat else { return }
        store.recordKeystroke(keyName: KeyName.from(event), appName: frontmostAppName())
        onEventRecorded?()
    }

    private func handleMouse(_ event: NSEvent) {
        store.recordClick(appName: frontmostAppName())
        onEventRecorded?()
    }

    /// Frontmost app's localized name (falling back to bundle id). NAME ONLY —
    /// never window titles or contents.
    private func frontmostAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return app.localizedName ?? app.bundleIdentifier
    }
}
