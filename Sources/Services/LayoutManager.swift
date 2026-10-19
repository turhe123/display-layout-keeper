import AppKit
import CoreGraphics
import ServiceManagement
import UserNotifications

/// Settings keys shared between `@AppStorage` views and the manager.
enum SettingsKey {
    static let autoSaveInterval = "autoSaveInterval"
    static let restoreDelay = "restoreDelay"
    static let autoRestore = "autoRestore"
    static let excludedApps = "excludedApps"
}

/// Coordinates display-change detection, periodic snapshots, sleep/wake handling and restores.
@MainActor
final class LayoutManager: ObservableObject {
    @Published private(set) var configuration = DisplayConfiguration.current()
    @Published private(set) var snapshots: [LayoutSnapshot] = []
    @Published private(set) var isTrusted = WindowService.isTrusted()
    @Published private(set) var lastMessage: String?

    private let store = SnapshotStore()
    private let defaults = UserDefaults.standard
    private var tickTimer: Timer?
    private var pendingRestore: DispatchWorkItem?
    private var signatureStableSince = Date()
    private var lastAutoSave = Date.distantPast
    private var settleUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    /// Minimum time the display signature must stay unchanged before auto-saving.
    private let stabilityWindow: TimeInterval = 5
    /// Grace period after wake during which nothing is saved or restored.
    private let wakeSettle: TimeInterval = 5

    init() {
        defaults.register(defaults: [SettingsKey.autoSaveInterval: 60, SettingsKey.restoreDelay: 3, SettingsKey.autoRestore: true])
        snapshots = store.loadAll()
        startObserving()
        if !isTrusted { _ = WindowService.isTrusted(prompt: true) }
    }

    // MARK: - Derived state

    var currentSnapshot: LayoutSnapshot? { snapshots.first { $0.signature == configuration.signature } }
    var canRestore: Bool { isTrusted && currentSnapshot != nil }

    var excludedApps: [String] {
        get { (defaults.string(forKey: SettingsKey.excludedApps) ?? "").split(separator: "\n").map(String.init) }
        set { defaults.set(newValue.joined(separator: "\n"), forKey: SettingsKey.excludedApps); objectWillChange.send() }
    }

    // MARK: - Actions

    func saveNow() { save(manual: true) }

    func restoreNow() { restore(automatic: false) }

    func delete(_ snapshot: LayoutSnapshot) {
        store.delete(signature: snapshot.signature)
        snapshots = store.loadAll()
    }

    func requestAccessibility() {
        _ = WindowService.isTrusted(prompt: true)
        WindowService.openAccessibilitySettings()
    }

    // MARK: - Observation

    private func startObserving() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })

        CGDisplayRegisterReconfigurationCallback(displayCallback, Unmanaged.passUnretained(self).toOpaque())

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Called from both the AppKit notification and the CoreGraphics callback; debounced via `pendingRestore`.
    fileprivate func displaysChanged() {
        let fresh = DisplayConfiguration.current()
        if fresh.signature != configuration.signature {
            configuration = fresh
            signatureStableSince = Date()
        }
        scheduleAutoRestore()
    }

    private func scheduleAutoRestore() {
        pendingRestore?.cancel()
        guard defaults.bool(forKey: SettingsKey.autoRestore) else { pendingRestore = nil; return }
        let delay = max(defaults.double(forKey: SettingsKey.restoreDelay), settleUntil.timeIntervalSinceNow, 0)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingRestore = nil
                self.configuration = DisplayConfiguration.current()
                self.restore(automatic: true)
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func willSleep() {
        pendingRestore?.cancel()
        pendingRestore = nil
        if Date() >= settleUntil { save(manual: false) }
    }

    private func didWake() {
        settleUntil = Date().addingTimeInterval(wakeSettle)
        signatureStableSince = Date()
        displaysChanged()
    }

    private func tick() {
        let trusted = WindowService.isTrusted()
        if trusted != isTrusted { isTrusted = trusted }

        let fresh = DisplayConfiguration.current()
        if fresh.signature != configuration.signature {
            configuration = fresh
            signatureStableSince = Date()
            return
        }
        let interval = max(defaults.double(forKey: SettingsKey.autoSaveInterval), 10)
        let now = Date()
        guard pendingRestore == nil,
              now >= settleUntil,
              now.timeIntervalSince(signatureStableSince) >= stabilityWindow,
              now.timeIntervalSince(lastAutoSave) >= interval else { return }
        save(manual: false)
    }

    // MARK: - Save / restore

    private func save(manual: Bool) {
        guard WindowService.isTrusted() else {
            isTrusted = false
            if manual { lastMessage = "Accessibility permission is required." }
            return
        }
        lastAutoSave = Date()
        let config = DisplayConfiguration.current()
        guard !config.displays.isEmpty else { return }
        let windows = WindowService.captureWindows(excluding: Set(excludedApps))
        // Don't overwrite a good layout with an empty one (e.g. during login or when all apps are hidden).
        guard !windows.isEmpty || manual else { return }
        let snapshot = LayoutSnapshot(signature: config.signature, name: config.name, detail: config.detail,
                                      savedAt: Date(), windows: windows)
        do {
            try store.save(snapshot)
            snapshots = store.loadAll()
            if manual { lastMessage = "Saved \(windows.count) windows." }
        } catch {
            lastMessage = "Could not save layout: \(error.localizedDescription)"
        }
    }

    private func restore(automatic: Bool) {
        guard WindowService.isTrusted() else { isTrusted = false; return }
        guard let snapshot = currentSnapshot else { return }
        let count = WindowService.restore(snapshot.windows, in: configuration, excluding: Set(excludedApps))
        lastMessage = "Restored \(count) windows."
        // Avoid capturing a half-restored layout right away.
        signatureStableSince = Date()
        if automatic && count > 0 { notify(restored: count, name: snapshot.name) }
    }

    /// Posts a short confirmation; permission is requested lazily on first use.
    private func notify(restored count: Int, name: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Layout restored"
            content.body = "\(count) windows moved back for \(name)."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// CoreGraphics display reconfiguration callback; forwards completed changes to the manager on the main actor.
private func displayCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info, !flags.contains(.beginConfigurationFlag) else { return }
    let manager = Unmanaged<LayoutManager>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor in manager.displaysChanged() }
}

/// Thin wrapper over `SMAppService.mainApp` for the launch-at-login toggle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
