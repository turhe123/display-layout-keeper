import AppKit
import ApplicationServices
import CoreGraphics

/// Reads and moves windows of other apps through CGWindowList and the Accessibility API.
enum WindowService {
    /// Whether this app is trusted for Accessibility; optionally shows the system prompt.
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures every visible, standard, non-minimized window of apps that own a normal-layer window.
    static func captureWindows(excluding excluded: Set<String>) -> [WindowRecord] {
        var records: [WindowRecord] = []
        for (bundleID, pids) in appsWithNormalWindows(excluding: excluded) {
            let windows = pids.flatMap(standardWindows(pid:))
            for (index, window) in windows.enumerated() {
                guard let frame = frame(of: window) else { continue }
                records.append(WindowRecord(bundleID: bundleID, title: title(of: window), index: index,
                                            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
            }
        }
        return records
    }

    /// Moves windows back to their saved frames. Returns the number of windows restored.
    @discardableResult
    static func restore(_ records: [WindowRecord], in config: DisplayConfiguration, excluding excluded: Set<String>) -> Int {
        var restored = 0
        let byApp = Dictionary(grouping: records.filter { !excluded.contains($0.bundleID) }, by: \.bundleID)
        for (bundleID, saved) in byApp {
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
            let windows = pids.flatMap(standardWindows(pid:))
            guard !windows.isEmpty else { continue }
            let titles = windows.map(title(of:))
            var used = Set<Int>()
            var assignments: [(WindowRecord, Int)] = []
            var unmatched: [WindowRecord] = []

            // Pass 1: bundle ID + exact title.
            for record in saved {
                if !record.title.isEmpty,
                   let i = titles.indices.first(where: { !used.contains($0) && titles[$0] == record.title }) {
                    used.insert(i)
                    assignments.append((record, i))
                } else {
                    unmatched.append(record)
                }
            }
            // Pass 2: bundle ID + window index (titles that changed, e.g. browser tabs).
            for record in unmatched.sorted(by: { $0.index < $1.index }) {
                let i = (record.index < windows.count && !used.contains(record.index))
                    ? record.index
                    : windows.indices.first { !used.contains($0) }
                guard let i else { break }
                used.insert(i)
                assignments.append((record, i))
            }
            for (record, i) in assignments where setFrame(config.clamp(record.frame), of: windows[i]) {
                restored += 1
            }
        }
        return restored
    }

    // MARK: - Helpers

    private static func appsWithNormalWindows(excluding excluded: Set<String>) -> [String: [pid_t]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let ownBundle = Bundle.main.bundleIdentifier
        var pids = Set<pid_t>()
        for entry in info where (entry[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t { pids.insert(pid) }
        }
        var result: [String: [pid_t]] = [:]
        for pid in pids.sorted() {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  bundleID != ownBundle, !excluded.contains(bundleID) else { continue }
            result[bundleID, default: []].append(pid)
        }
        return result
    }

    /// Standard windows reachable through Accessibility; minimized and other-Space windows are skipped.
    private static func standardWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.filter { window in
            let minimized = (attribute(window, kAXMinimizedAttribute) as? Bool) ?? false
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            return !minimized && subrole == kAXStandardWindowSubrole
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func title(of window: AXUIElement) -> String {
        (attribute(window, kAXTitleAttribute) as? String) ?? ""
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let posRef = attribute(window, kAXPositionAttribute), CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = attribute(window, kAXSizeAttribute), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // Type IDs were checked above, so these casts cannot fail.
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func setFrame(_ frame: CGRect, of window: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return false }
        // Position, size, then position again: some apps constrain size to the display the window is currently on.
        let first = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        let second = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        return first == .success || second == .success
    }
}
